package com.feiniu.usb_audio_exclusive

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// USB 音频独占输出插件（Android）。
///
/// MethodChannel `usb_audio_exclusive/methods`：
///   listDevices / open / close / play / pause / resume / seek / stop /
///   setVolume / outputInfo
/// EventChannel `usb_audio_exclusive/events`：
///   {kind: playback, state, positionMs, durationMs, message?}
///   {kind: devices, devices: [...]}
class UsbAudioExclusivePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val ACTION_PERMISSION = "com.feiniu.usb_audio_exclusive.USB_PERMISSION"
    }

    private lateinit var context: Context
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private lateinit var usbManager: UsbManager
    private lateinit var finder: UsbDeviceFinder
    private var deviceHandle: UsbDeviceHandle? = null
    private var decoder: ExclusiveDecoder? = null
    private val volumeRef = floatArrayOf(1.0f)

    // 独占链路绕过 AudioFlinger，手机音量键天然无效 → 400ms 轮询系统媒体
    // 音量，作为 UacSink 软件增益的一半（有效增益 = app 音量 × 系统音量比）。
    @Volatile private var sysVolRatio = 1.0f
    private var volPollActive = false
    private val volHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val volPoller = object : Runnable {
        override fun run() {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
            val cur = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
            val r = if (max > 0) cur.toFloat() / max else 1f
            if (r != sysVolRatio) {
                sysVolRatio = r
                decoder?.setSystemVolume(r)
            }
            if (volPollActive) volHandler.postDelayed(this, 400)
        }
    }

    @Volatile private var playbackState = "idle"
    @Volatile private var positionMs = 0L
    @Volatile private var durationMs: Long? = null
    @Volatile private var sampleRate = 0
    @Volatile private var channels = 0
    @Volatile private var bitDepth = 0

    private var pendingOpen: MethodChannel.Result? = null
    private var pendingDevice: UsbDevice? = null

    // P2-7 热插拔：播放中断点信息（拔 DAC → 记录；插回 → 自动续播）。
    private data class PlayReq(
        val url: String,
        val headers: Map<String, String>,
        val isFile: Boolean,
        val endMs: Long?,
        val title: String?,
    )

    @Volatile private var lastPlay: PlayReq? = null
    @Volatile private var resumePending = false
    // 上一轮输出是否走系统通路（AudioTrackSink）。系统通路收尾的 ALSA teardown
    // 是异步的（约 100-200ms）：若紧接着 setInterface 抢独占，内核等时端点会被
    // 拆流方作废（SUBMITURB ENOENT）→ URB 全灭 → ring 堵死 → "usb write failed"
    // → 降级互殴爆音（ECHO-A 2026-09-25 实锤）。startPlayback 时据此等待收尾。
    @Volatile private var lastSinkWasSystem = false
    // USB 使用史：上次 startPlayback 是否拿到了 UacSink。拔掉 DAC 后补开需要
    // 等重枚举（attach 后 ~1-3s 才可用），据此决定是否重试等待；纯扬声器场景
    // 不受影响（零延迟直接 fallback）。
    @Volatile private var usbWasActive = false
    // 会话驻留：切歌复用的 sink（UacSink 且句柄同源时跳过重建）。
    private var currentSink: PcmSink? = null

    // P1-3：重采样/降位提示节流（每 DAC 30 分钟一次）。
    private val noticeShownAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ACTION_PERMISSION -> {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val dev: UsbDevice? =
                        if (Build.VERSION.SDK_INT >= 33)
                            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                        else @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    val result = pendingOpen
                    pendingOpen = null
                    if (granted && dev != null) {
                        try {
                            deviceHandle = finder.openDevice(dev)
                        } catch (e: Exception) {
                            deviceHandle = null
                        }
                        if (deviceHandle != null) {
                            saveDeviceCaps(deviceHandle!!)
                            result?.success(outputInfoMap())
                            pushDevices()
                        } else {
                            result?.error("OPEN_FAILED", "打开 USB 音频设备失败", null)
                        }
                    } else {
                        result?.error("PERMISSION_DENIED", "未授权 USB 设备访问", null)
                    }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    pushDevices()
                    // P2-7：播放中被拔掉的 DAC 插回 → 自动恢复播放（从断点续播）。
                    if (resumePending) {
                        val lp = lastPlay
                        if (lp != null) {
                            android.os.Handler(context.mainLooper).postDelayed({
                                if (resumePending) {
                                    resumePending = false
                                    android.util.Log.i("UsbAudioExclusivePlugin", "hotplug: auto-resume at ${positionMs}ms")
                                    startPlayback(lp.url, lp.headers, lp.isFile, positionMs, lp.endMs, lp.title)
                                }
                            }, 600) // 等设备枚举完成
                        }
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    // P2-7：播放中拔 DAC → 不崩、优雅暂停（记断点），插回自动恢复。
                    if (decoder != null) {
                        resumePending = true
                        shutdownPlayback()
                        try {
                            deviceHandle?.close()
                        } catch (_: Exception) {
                        }
                        deviceHandle = null
                        emitState("paused", "USB device unplugged")
                    }
                    pushDevices()
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        finder = UsbDeviceFinder(usbManager)

        methodChannel = MethodChannel(binding.binaryMessenger, "usb_audio_exclusive/methods")
        methodChannel?.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "usb_audio_exclusive/events")
        eventChannel?.setStreamHandler(this)

        val filter = IntentFilter().apply {
            addAction(ACTION_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(usbReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(usbReceiver, filter)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            context.unregisterReceiver(usbReceiver)
        } catch (_: Exception) {
        }
        shutdownPlayback()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        pushDevices()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ------------------------------------------------------------------
    // 方法调用
    // ------------------------------------------------------------------
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listDevices" -> result.success(devicesListMaps())
                "knownDevices" -> result.success(knownDevicesMaps())
                "requestPermission" -> {
                    // 新设备首次使用：显式弹出系统 USB 授权弹窗（幂等，
                    // 已授权直接返回 true）。解决「独占开关已开但新 DAC
                    // 没授权 → 静默回退 audiotrack」问题。
                    val dev = finder.listAudioDevices().firstOrNull()
                    if (dev == null) {
                        result.success(false)
                    } else if (usbManager.hasPermission(dev.device)) {
                        result.success(true)
                    } else {
                        pendingOpen?.let {
                            it.error("BUSY", "已有授权请求进行中", null)
                        }
                        pendingOpen = null
                        // requestPermission 结果经 usbReceiver 广播（不挂 result，
                        // 纯引导性质；后续 play 再走正常 open 流程）。
                        // U+(API34) 禁止 FLAG_MUTABLE+隐式 Intent：setPackage 显式化；
                        // 保持 MUTABLE 才能接收系统回填的 EXTRA_PERMISSION_GRANTED。
                        val flags =
                            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                        val pi = PendingIntent.getBroadcast(
                            context, 0,
                            Intent(ACTION_PERMISSION).setPackage(context.packageName),
                            flags,
                        )
                        usbManager.requestPermission(dev.device, pi)
                        result.success(true)
                    }
                }
                "open" -> openExclusive(result)
                "close" -> {
                    shutdownPlayback()
                    deviceHandle?.close()
                    deviceHandle = null
                    pushDevices()
                    result.success(null)
                }
                "play" -> {
                    val url = call.argument<String>("url") ?: ""
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    val isFile = call.argument<Boolean>("isFile") ?: false
                    val startMs = (call.argument<Number>("startMs") ?: 0).toLong()
                    val endMs = call.argument<Number>("endMs")?.toLong()
                    val title = call.argument<String>("title")
                    startPlayback(url, headers, isFile, startMs, endMs, title)
                    result.success(null)
                }
                "pause" -> {
                    decoder?.pause()
                    emitState("paused")
                    result.success(null)
                }
                "resume" -> {
                    decoder?.resume()
                    emitState("playing")
                    result.success(null)
                }
                "seek" -> {
                    val ms = (call.argument<Number>("ms") ?: 0).toLong()
                    android.util.Log.i("UsbAudioExclusivePlugin", "seek ms=$ms decoder=${decoder != null} prevPos=$positionMs")
                    decoder?.seek(ms)
                    positionMs = ms
                    result.success(null)
                }
                "stop" -> {
                    resumePending = false // 手动停止：取消热插拔自动恢复
                    shutdownPlayback()
                    result.success(null)
                }
                "setVolume" -> {
                    val v = (call.argument<Number>("value") ?: 1.0).toFloat().coerceIn(0f, 1f)
                    volumeRef[0] = v
                    decoder?.setVolume(v)
                    result.success(null)
                }
                "outputInfo" -> result.success(outputInfoMap())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("ERROR", e.message ?: "unknown", null)
        }
    }

    private fun devicesListMaps(): List<Map<String, Any?>> =
        finder.listAudioDevices().map {
            val key = "caps_${it.device.vendorId}_${it.device.productId}"
            val caps = prefs.getString(key, null)
            mapOf(
                "name" to it.name,
                "manufacturer" to it.manufacturer,
                "vendorId" to it.device.vendorId,
                "productId" to it.device.productId,
                "deviceId" to it.device.deviceId,
                "hasPermission" to usbManager.hasPermission(it.device),
                "caps" to caps,
            )
        }

    private val prefs by lazy {
        context.getSharedPreferences("usb_audio_exclusive", Context.MODE_PRIVATE)
    }

    /// 设备能力缓存（parse 成功后落盘，key=vid_pid）+ 连接历史（key=hist_vid_pid）。
    private fun saveDeviceCaps(handle: UsbDeviceHandle) {
        val d = handle.device
        val rates = LinkedHashSet<Int>()
        val bits = LinkedHashSet<Int>()
        val chs = LinkedHashSet<Int>()
        for (a in handle.alts) {
            if (a.rates.isNotEmpty()) rates.addAll(a.rates)
            else if (a.rateMin > 0) {
                // 连续范围：记边界（Dart 侧 supportsRate 按范围判断）
            }
            bits.add(a.bitDepth)
            chs.add(a.channels)
        }
        val rmin = handle.alts.map { it.rateMin }.filter { it > 0 }.minOrNull() ?: 0
        val rmax = handle.alts.map { it.rateMax }.filter { it > 0 }.maxOrNull() ?: 0
        val json = org.json.JSONObject().apply {
            put("uac2", handle.uac2)
            put("highSpeed", handle.highSpeed)
            put("rates", org.json.JSONArray(rates.toList()))
            put("rateMin", rmin)
            put("rateMax", rmax)
            put("bitDepths", org.json.JSONArray(bits.toList()))
            put("channels", org.json.JSONArray(chs.toList()))
        }.toString()
        prefs.edit().putString("caps_${d.vendorId}_${d.productId}", json).apply()
        // 连接历史（幂等更新 lastSeen）
        val hkey = "hist_${d.vendorId}_${d.productId}"
        val hist = org.json.JSONObject().apply {
            put("name", d.productName ?: "USB Audio Device")
            put("manufacturer", d.manufacturerName)
            put("vendorId", d.vendorId)
            put("productId", d.productId)
            put("firstSeen", prefs.getLong("${hkey}_first", System.currentTimeMillis()))
            put("lastSeen", System.currentTimeMillis())
        }.toString()
        prefs.edit()
            .putString(hkey, hist)
            .putLong("${hkey}_first", hist.let {
                org.json.JSONObject(it).getLong("firstSeen")
            })
            .apply()
    }

    /// 历史连接过的 DAC 设备列表（设置页展示）。
    private fun knownDevicesMaps(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for ((k, v) in prefs.all) {
            if (!k.startsWith("hist_") || k.endsWith("_first")) continue
            val s = v as? String ?: continue
            try {
                val o = org.json.JSONObject(s)
                out.add(
                    mapOf(
                        "name" to o.optString("name"),
                        "manufacturer" to o.optString("manufacturer"),
                        "vendorId" to o.optInt("vendorId"),
                        "productId" to o.optInt("productId"),
                        "firstSeen" to o.optLong("firstSeen"),
                        "lastSeen" to o.optLong("lastSeen"),
                    )
                )
            } catch (_: Exception) {
            }
        }
        return out.sortedByDescending { (it["lastSeen"] as? Long) ?: 0L }
    }

    /// 推一条一次性提示（重采样/降位等），Dart 侧弹 SnackBar/对话框。
    private fun pushNotice(message: String) {
        val sink = eventSink ?: return
        val main = android.os.Handler(context.mainLooper)
        main.post {
            sink.success(
                mapOf(
                    "kind" to "notice",
                    "message" to message,
                )
            )
        }
    }

    private fun pushDevices() {
        val sink = eventSink ?: return
        val main = android.os.Handler(context.mainLooper)
        main.post {
            sink.success(
                mapOf(
                    "kind" to "devices",
                    "devices" to devicesListMaps(),
                )
            )
        }
    }

    private fun outputInfoMap(): Map<String, Any?> {
        val backend = when {
            decoder == null -> "none"
            deviceHandle != null -> "usb_uac"
            else -> "audiotrack"
        }
        return mapOf(
            "backend" to backend,
            "deviceName" to deviceHandle?.device?.productName,
            "sampleRate" to sampleRate,
            "bitDepth" to bitDepth,
            "channels" to channels,
        )
    }

    /// 打开独占输出：找设备 → USB 授权（异步）→ openDevice。
    /// 无设备时直接报错（Dart 侧决定是否回退）。
    private fun openExclusive(result: MethodChannel.Result) {
        val dev = finder.listAudioDevices().firstOrNull()
        if (dev == null) {
            result.error("NO_DEVICE", "未检测到 USB 音频设备", null)
            return
        }
        if (usbManager.hasPermission(dev.device)) {
            deviceHandle = try {
                finder.openDevice(dev.device)
            } catch (e: Exception) {
                null
            }
            if (deviceHandle != null) {
                saveDeviceCaps(deviceHandle!!)
                pushDevices()
                result.success(outputInfoMap())
            } else {
                result.error("OPEN_FAILED", "打开 USB 音频设备失败", null)
            }
            return
        }
        if (pendingOpen != null) {
            result.error("BUSY", "已有授权请求进行中", null)
            return
        }
        pendingOpen = result
        pendingDevice = dev.device
        // U+(API34) 同上：隐式 Intent 需 setPackage 显式化，否则 FLAG_MUTABLE 抛异常。
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(
            context, 0, Intent(ACTION_PERMISSION).setPackage(context.packageName), flags,
        )
        usbManager.requestPermission(dev.device, pi)
    }

    private fun shutdownPlayback(closeSink: Boolean = true) {
        volPollActive = false
        volHandler.removeCallbacks(volPoller)
        decoder?.stop()
        if (closeSink) {
            decoder?.closeSink()
            currentSink = null
        }
        decoder = null
        playbackState = "idle"
    }

    private fun startPlayback(
        url: String,
        headers: Map<String, String>,
        isFile: Boolean,
        startMs: Long,
        endMs: Long?,
        title: String?,
    ) {
        // 切歌=只换解码器，USB 会话/端点保持驻留（UAPP 式，2026-09-26 根治）。
        shutdownPlayback(closeSink = false)
        // 系统通路 → 独占切换：等 ALSA teardown 完全收尾再抢端点（见字段注释）。
        if (lastSinkWasSystem) {
            android.util.Log.i(
                "UsbAudioExclusivePlugin",
                "settle: wait 300ms for ALSA teardown before exclusive open",
            )
            Thread.sleep(300)
        }
        lastPlay = PlayReq(url, headers, isFile, endMs, title) // P2-7 断点续播信息
        // sink 选择：有 USB 独占句柄 → UacSink（bit-perfect）；否则 AudioTrack 直通。
        // 句柄缺失时现场补开一次（例如首次 open 时 USB 授权还没授予、之后才授权的场景）。
        if (deviceHandle == null) {
            // 拔插恢复窗口：attach 后 ~1-3s 内枚举/授权未就绪，单次补开必失败
            // （2026-09-26 01:43:32 实锤：attach+0.58s 补开失败→跌落扬声器）。
            // 有 USB 使用史或设备在列时最多重试 5 次 x 600ms。
            var attempt = 0
            while (deviceHandle == null && attempt < 5) {
                if (attempt > 0) Thread.sleep(600)
                attempt++
                val devs = finder.listAudioDevices()
                val dev = devs.firstOrNull()
                android.util.Log.i("UsbAudioExclusivePlugin", "rescue-open: audioDevices=${devs.size} attempt=$attempt")
                if (dev != null) {
                    val perm = usbManager.hasPermission(dev.device)
                    android.util.Log.i("UsbAudioExclusivePlugin", "rescue-open: permission=$perm")
                    if (perm) {
                        deviceHandle = try {
                            finder.openDevice(dev.device)
                        } catch (e: Exception) {
                            android.util.Log.i("UsbAudioExclusivePlugin", "rescue-open: exception=${e}")
                            null
                        }
                        if (deviceHandle == null) {
                            android.util.Log.i("UsbAudioExclusivePlugin", "rescue-open: openDevice null (parse fail?)")
                        } else {
                            saveDeviceCaps(deviceHandle!!)
                        }
                    }
                }
                // 无任何 USB 设备物理在插才不等（手机纯扬声器场景零延迟）。
                // 不能看 listAudioDevices 瞬时空 + usbWasActive 内存标志：
                // app 重启后两者皆空，首曲会误判扬声器场景跌落 fallback
                // （2026-09-26 02:37:36 实锤 audioDevices=0 但 DAC 物理在插）。
                if (deviceHandle == null && usbManager.deviceList.isEmpty()) break
            }
        }
        android.util.Log.i(
            "UsbAudioExclusivePlugin",
            "startPlayback sink=${if (deviceHandle != null) "usb_uac" else "audiotrack-fallback"}",
        )
        val sink: PcmSink = currentSink?.takeIf {
            it is UacSink && deviceHandle != null && it.handleRef === deviceHandle
        } ?: (deviceHandle?.let { UacSink(it) } ?: AudioTrackSink(volumeRef))
        currentSink = sink
        lastSinkWasSystem = sink !is UacSink
        usbWasActive = sink is UacSink
        val d = ExclusiveDecoder(
            url = url,
            headers = headers,
            isFile = isFile,
            startMs = startMs,
            endMs = endMs,
            sink = sink,
            listener = object : ExclusiveDecoder.Listener {
                override fun onState(state: String, message: String?) {
                    emitState(state, message)
                }

                override fun onProgress(positionMs: Long, durationMs: Long?) {
                    this@UsbAudioExclusivePlugin.positionMs = positionMs
                    this@UsbAudioExclusivePlugin.durationMs = durationMs
                    emitState(if (playbackState == "ready") "playing" else playbackState)
                }

                override fun onFormat(sampleRate: Int, channels: Int, encoding: Int) {
                    this@UsbAudioExclusivePlugin.sampleRate = sampleRate
                    this@UsbAudioExclusivePlugin.channels = channels
                    bitDepth = when (encoding) {
                        android.media.AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
                        android.media.AudioFormat.ENCODING_PCM_32BIT,
                        android.media.AudioFormat.ENCODING_PCM_FLOAT -> 32
                        else -> 16
                    }
                    // P1-3：协商结果提示（重采样/降位 dither）。同一个 DAC
                    // 30 分钟内只提示一次（用户要求"短时间只提示一次"）。
                    val h = deviceHandle
                    if (h != null && (h.lastResampled || h.lastDithered)) {
                        val key = "${h.device.vendorId}_${h.device.productId}"
                        val now = System.currentTimeMillis()
                        val last = noticeShownAt[key] ?: 0L
                        if (now - last > 30 * 60 * 1000L) {
                            noticeShownAt[key] = now
                            val msg = buildString {
                                if (h.lastResampled) {
                                    append("此 DAC 不支持 ${sampleRate}Hz，已自动重采样为 ${h.lastWireRate}Hz 输出")
                                }
                                if (h.lastDithered) {
                                    if (isNotEmpty()) append("；")
                                    append("DAC 位深不足，已加 dither 降位")
                                }
                                append("（牺牲 bit-perfect，保证能播）。")
                            }
                            pushNotice(msg)
                        }
                    }
                }
            },
        )
        decoder = d
        // 新会话继承当前音量：app 音量 × 系统音量比（手机音量键）。
        d.setVolume(volumeRef[0])
        d.setSystemVolume(sysVolRatio)
        if (!volPollActive) {
            volPollActive = true
            volHandler.post(volPoller)
        }
        d.start()
    }

    private fun emitState(state: String, message: String? = null) {
        playbackState = state
        android.util.Log.i(
            "UsbAudioExclusivePlugin",
            "state=$state msg=${message ?: "-"} pos=$positionMs dur=$durationMs",
        )
        val sink = eventSink ?: return
        val map = mutableMapOf<String, Any?>(
            "kind" to "playback",
            "state" to state,
            "positionMs" to positionMs,
            "durationMs" to durationMs,
        )
        if (message != null) map["message"] = message
        val main = android.os.Handler(context.mainLooper)
        main.post { sink.success(map) }
    }
}
