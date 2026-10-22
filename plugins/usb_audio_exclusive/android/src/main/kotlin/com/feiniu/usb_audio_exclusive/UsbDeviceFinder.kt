package com.feiniu.usb_audio_exclusive

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import org.json.JSONObject

/// 设备怪癖表（参考 Linux snd-usb-audio quirks 的思路）：部分国产小尾巴
/// 描述符不标准，通用解析会得出错误结论，按 VID:PID 打补丁。
/// 新增设备只需在此加一行，不动解析主逻辑。
object DeviceQuirks {
    data class Quirk(
        /// 强制判定为 UAC1/UAC2（null=按描述符）。
        val forceUac2: Boolean? = null,
        /// 修正/补充支持采样率表（null=按描述符）。个别设备率表字段全 0 但
        /// 实际只支持 48k，通用逻辑会误判"任意率"。
        val ratesOverride: List<Int>? = null,
        /// 忽略显式反馈端点（个别设备 fbEp 指向不存在的端点，读反馈会卡死）。
        val ignoreFeedback: Boolean = false,
        /// 说明（为什么需要这个 quirk）。
        val note: String = "",
    )

    private val table: Map<Long, Quirk> = mapOf(
        // key = (vendorId.toLong() shl 16) or productId
        // 例：VID 0x1234 PID 0x5678 的设备率表描述符全 0 但实际只支持 48k：
        // key(0x1234, 0x5678) to Quirk(ratesOverride = listOf(48000), note = "rate table broken"),
    )

    private fun key(vid: Int, pid: Int): Long = (vid.toLong() shl 16) or (pid.toLong() and 0xffff)

    fun forDevice(vid: Int, pid: Int): Quirk? = table[key(vid, pid)]
}

/// USB 音频设备（UAC1/UAC2 DAC）发现与独占打开。
///
/// 关键点（decent-player 踩坑记录）：
/// 1. alt setting 必须用 Java `UsbDeviceConnection.setInterface()` 选——
///    native USBDEVFS_SETINTERFACE 不会在 xHCI 调度器预留等时带宽 → 静默丢包；
/// 2. 16-bit alt 不出声的 DAC 存在，选 alt 时优先匹配源位深；
/// 3. 频率控制（UAC2 Clock Source / UAC1 端点 SET_CUR）在 native 里做。
class UsbDeviceFinder(private val usbManager: UsbManager) {

    data class DeviceEntry(
        val device: UsbDevice,
        val name: String,
        val manufacturer: String?,
    )

    /// 枚举当前连接的 USB 音频设备（含流接口 + 等时 OUT 端点的才算）。
    fun listAudioDevices(): List<DeviceEntry> {
        val out = ArrayList<DeviceEntry>()
        for (d in usbManager.deviceList.values) {
            if (findStreamingOut(d) != null) {
                out.add(DeviceEntry(d, d.productName ?: "USB Audio Device", d.manufacturerName))
            }
        }
        return out
    }

    /// 找 AudioStreaming 接口（含等时 OUT 端点）的（接口，端点）对。返回 null=非 UAC 设备。
    private fun findStreamingOut(d: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        for (i in 0 until d.interfaceCount) {
            val intf = d.getInterface(i)
            if (intf.interfaceClass != UsbConstants.USB_CLASS_AUDIO) continue
            for (e in 0 until intf.endpointCount) {
                val ep = intf.getEndpoint(e)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_ISOC &&
                    ep.direction == UsbConstants.USB_DIR_OUT
                ) {
                    return intf to ep
                }
            }
        }
        return null
    }

    fun isAudioDevice(d: UsbDevice): Boolean = findStreamingOut(d) != null

    /// 打开设备并 claim（不选 alt——播放时按源格式选）。
    fun openDevice(device: UsbDevice): UsbDeviceHandle? {
        val conn = usbManager.openDevice(device) ?: return null
        val handle = UsbDeviceHandle(device, conn)
        if (!handle.parse()) {
            conn.close()
            return null
        }
        return handle
    }
}

/// 已打开的 USB 音频设备句柄：持有 usbfs fd、解析出的 alt 列表、
/// 当前 native 输出句柄。
class UsbDeviceHandle(
    val device: UsbDevice,
    private val conn: UsbDeviceConnection,
) {
    private var claimed: UsbInterface? = null
    private var activeIface = -1 // stopInternal 时用它把端点规范下电（alt=0）
    var alts: List<AltInfo> = emptyList()
        private set
    var uac2 = false
        private set
    var highSpeed = false
        private set
    var clockId = 0
        private set
    var acIface = 0
        private set

    private var nativeHandle = 0L

    data class AltInfo(
        val iface: Int,
        val alt: Int,
        val ep: Int,
        val maxPacket: Int,
        val syncType: Int,
        val fbEp: Int,
        val channels: Int,
        val subframe: Int,
        val bitDepth: Int,
        val rates: List<Int>,
        val rateMin: Int,
        val rateMax: Int,
    ) {
        fun supportsRate(r: Int): Boolean =
            if (rates.isNotEmpty()) r in rates
            else if (rateMin == 0 && rateMax == 0) true // 无静态率表（UAC2 时钟编程型）
            else r in rateMin..rateMax
    }

    /// 解析 UAC 描述符（native 侧 usbfs GET_DESCRIPTOR + CS 解析）。
    fun parse(): Boolean {
        val json = NativeUac.nativeParse(conn.fileDescriptor)
        android.util.Log.i("UsbUacParse", "parse json=${json.take(2000)}")
        val obj = JSONObject(json)
        if (obj.has("error")) return false
        // P1-6：quirks 预处理（描述符不标准的设备按 VID:PID 打补丁）。
        val quirk = DeviceQuirks.forDevice(device.vendorId, device.productId)
        if (quirk != null) {
            android.util.Log.i("UsbUacParse", "quirk applied: ${quirk.note}")
        }
        uac2 = quirk?.forceUac2 ?: obj.optBoolean("uac2")
        highSpeed = obj.optBoolean("highSpeed")
        clockId = obj.optInt("clockId")
        acIface = obj.optInt("acIface")
        val arr = obj.optJSONArray("alts") ?: return false
        val list = ArrayList<AltInfo>()
        for (i in 0 until arr.length()) {
            val a = arr.getJSONObject(i)
            val ratesArr = a.optJSONArray("rates")
            val rates = ArrayList<Int>()
            if (ratesArr != null) for (k in 0 until ratesArr.length()) rates.add(ratesArr.getInt(k))
            // quirk：率表修正（描述符率表损坏的设备）。
            val effRates = quirk?.ratesOverride ?: rates
            list.add(
                AltInfo(
                    iface = a.getInt("iface"),
                    alt = a.getInt("alt"),
                    ep = a.getInt("ep"),
                    maxPacket = a.getInt("maxPacket"),
                    syncType = a.getInt("syncType"),
                    // quirk：忽略显式反馈端点（fbEp 指向幽灵端点的设备）。
                    fbEp = if (quirk?.ignoreFeedback == true) 0 else a.getInt("fbEp"),
                    channels = a.getInt("channels"),
                    subframe = a.getInt("subframe"),
                    bitDepth = a.getInt("bitDepth"),
                    rates = effRates,
                    rateMin = a.optInt("rateMin"),
                    rateMax = a.optInt("rateMax"),
                )
            )
        }
        alts = list
        return list.isNotEmpty()
    }

    /// 采样率协商结果：alt + 线上实际输出率。
    data class Negotiation(val alt: AltInfo, val wireRate: Int, val exactRate: Boolean)

    /// 按源格式协商最佳 alt（P1-3/P1-4 通用兼容策略）。
    /// 原则：**能 bit-perfect 绝不重采样/降位**——
    ///  1. 源采样率在 DAC 支持列表 → wireRate=源率（bit-perfect 前提）；
    ///     不在 → 取最接近支持率（APP 内重采样，牺牲 bit-perfect 但能播）；
    ///  2. 位深：优先 ≥srcBits（升位/直通精确）；实在没有才允许降位
    ///     （native 侧 TPDF dither，量化失真不集中成谐波）；
    ///  3. 声道：任意组合可播（convertFrames 上混/下混），优先同数。
    private fun pickAlt(sampleRate: Int, channels: Int, srcBits: Int): Negotiation? {
        val usable = alts.filter {
            it.channels > 0 && it.subframe in 2..4
        }
        if (usable.isEmpty()) return null

        // 每个 alt 算出可用的最接近采样率。
        fun nearestRate(a: AltInfo): Int {
            if (a.supportsRate(sampleRate)) return sampleRate
            if (a.rates.isNotEmpty()) {
                return a.rates.minByOrNull { kotlin.math.abs(it - sampleRate) } ?: sampleRate
            }
            // 连续范围：夹到 [rateMin, rateMax]。
            if (a.rateMin > 0 && a.rateMax > 0) {
                return sampleRate.coerceIn(a.rateMin, a.rateMax)
            }
            return sampleRate // 无静态率表（时钟编程型）——按源率试
        }

        // 候选排序（越小越优）：
        //   率精确匹配 > 位深充足 > 声道同数 > 位深等值 > 位深差小 > 率差小
        return usable
            .map { Negotiation(it, nearestRate(it), nearestRate(it) == sampleRate) }
            .sortedWith(
                compareBy(
                    { if (it.exactRate) 0 else 1 },
                    { if (it.alt.subframe * 8 >= srcBits) 0 else 1 },
                    { if (it.alt.channels == channels) 0 else 1 },
                    { if (it.alt.bitDepth == srcBits) 0 else 1 },
                    { kotlin.math.abs(it.alt.bitDepth - srcBits) },
                    { kotlin.math.abs(it.wireRate - sampleRate) },
                )
            ).first()
    }

    private fun usbInterfaceFor(iface: Int, alt: Int): UsbInterface? {
        for (i in 0 until device.interfaceCount) {
            val intf = device.getInterface(i)
            if (intf.id == iface && intf.alternateSetting == alt) return intf
        }
        return null
    }

    /// 最近一次协商结果（供上层：是否重采样/降位 → 一次性提示）。
    var lastWireRate = 0
        private set
    var lastResampled = false
        private set
    var lastDithered = false
        private set

    /// 启动 native 输出：协商 alt（Java setInterface 预留带宽）→ 频率控制 → URB 管线。
    /// [inEnc] 为 MediaCodec 输出编码（AudioFormat.ENCODING_*）。
    @Synchronized
    fun start(sampleRate: Int, channels: Int, srcBits: Int, inEnc: Int): Boolean {
        android.util.Log.i("UsbDeviceFinder", "handle.start begin sr=$sampleRate ch=$channels srcBits=$srcBits inEnc=$inEnc claimed=${claimed != null}")
        stopInternal()
        val neg = pickAlt(sampleRate, channels, srcBits)
        if (neg == null) {
            android.util.Log.i("UsbDeviceFinder", "handle.start ABORT pickAlt null sr=$sampleRate ch=$channels srcBits=$srcBits alts=${alts.size}")
            return false
        }
        val alt = neg.alt
        val intf = usbInterfaceFor(alt.iface, alt.alt)
        if (intf == null) {
            android.util.Log.i("UsbDeviceFinder", "handle.start ABORT usbInterfaceFor null iface=${alt.iface} alt=${alt.alt}")
            return false
        }
        if (claimed == null) {
            val ok = conn.claimInterface(intf, true)
            if (!ok) {
                android.util.Log.i("UsbDeviceFinder", "handle.start ABORT claimInterface false iface=${alt.iface}")
                return false
            }
            claimed = intf
        }
        // 必须 Java setInterface（xHCI 等时带宽预留），native 切 alt 无效。
        val setIfOk = conn.setInterface(intf)
        android.util.Log.i("UsbDeviceFinder", "setInterface iface=${alt.iface} alt=${alt.alt} ok=$setIfOk")
        activeIface = alt.iface
        lastWireRate = neg.wireRate
        lastResampled = neg.wireRate != sampleRate
        lastDithered = alt.subframe * 8 < srcBits
        android.util.Log.i(
            "UsbDeviceFinder",
            "negotiate: src=$sampleRate wire=${neg.wireRate} resample=${lastResampled} " +
                "srcBits=$srcBits altBits=${alt.subframe * 8} dither=$lastDithered " +
                "altCh=${alt.channels} srcCh=$channels",
        )
        nativeHandle = NativeUac.nativeStart(
            conn.fileDescriptor,
            alt.iface,
            alt.alt,
            alt.ep,
            alt.maxPacket,
            alt.fbEp,
            alt.syncType,
            sampleRate,
            neg.wireRate,
            channels,
            alt.channels,
            alt.subframe,
            srcBits,
            inEnc,
            highSpeed,
            uac2,
            clockId,
            acIface,
        )
        return nativeHandle != 0L
    }

    /// 会话驻留判定：native 会话存活中（切歌同格式时跳过 handle.start）。
    val isStarted: Boolean get() = nativeHandle != 0L

    @Synchronized
    fun write(data: ByteArray, offset: Int, len: Int): Int {
        val h = nativeHandle
        if (h == 0L) return -1
        return NativeUac.nativeWrite(h, data, offset, len)
    }

    @Synchronized
    fun stopInternal() {
        if (nativeHandle != 0L) {
            NativeUac.nativeStop(nativeHandle)
            NativeUac.nativeClose(nativeHandle)
            nativeHandle = 0L
        }
        // 端点规范下电：先停 URB，再 SET_INTERFACE alt=0（零带宽）。
        // 不下电就 re-assert 同 alt，ECHO-A 端点会进"URB 即刻完成、数据全吞"
        // 的僵尸态（2026-09-26 02:18:32 实锤：ring 永远 0，全绿无声）。
        if (activeIface >= 0) {
            val ok = usbInterfaceFor(activeIface, 0)?.let { conn.setInterface(it) }
            android.util.Log.i("UsbDeviceFinder", "stopInternal: setInterface iface=$activeIface alt=0 ok=$ok")
            activeIface = -1
        }
    }

    @Synchronized
    fun close() {
        stopInternal()
        claimed?.let { conn.releaseInterface(it) }
        claimed = null
        conn.close()
    }
}
