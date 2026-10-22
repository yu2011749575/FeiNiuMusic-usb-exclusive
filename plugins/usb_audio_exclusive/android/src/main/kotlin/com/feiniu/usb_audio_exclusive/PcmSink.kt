package com.feiniu.usb_audio_exclusive

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack

/// PCM 输出后端抽象。解码线程产出的 PCM 直接写入这里。
interface PcmSink {
    val backend: String // 'usb_uac' | 'audiotrack'
    val description: String?

    /// 以解码器实际输出格式建立输出。
    fun configure(sampleRate: Int, channels: Int, encoding: Int): Boolean
    fun write(data: ByteArray, offset: Int, len: Int): Boolean

    /// app 音量（播放器音量设置）。
    fun setVolume(value: Float)

    /// 系统媒体音量比（手机物理音量键，0..1）。AudioTrack 回退后端忽略
    /// （AudioFlinger 混音器已生效）；USB 独占后端做软件衰减。
    fun setSystemVolume(ratio: Float) {}

    fun close()
}

/// USB DAC 独占输出（bit-perfect）：PCM → usbdevfs 等时传输 → DAC。
class UacSink(private val handle: UsbDeviceHandle) : PcmSink {
    val handleRef: UsbDeviceHandle get() = handle // 切歌驻留判定（与 plugin 的 deviceHandle 比对身份）
    override val backend = "usb_uac"
    override val description: String
        get() = handle.device.productName ?: "USB DAC"

    // 音量 = app 音量 × 系统媒体音量比（手机音量键）。独占链路绕过
    // AudioFlinger，系统音量天然无效——不接软件增益就"调不了声音"。
    // 双满格(1.0)时逐字节旁路 = bit-perfect 不受损；调低才线性衰减
    // （渐变斜坡防爆音），牺牲 bit-perfect 是用户主动选择。
    @Volatile private var appVolume = 1.0f
    @Volatile private var sysVolume = 1.0f
    private var currentGain = 1.0f // 渐变起点，防音量突变爆音
    @Volatile private var encoding = AudioFormat.ENCODING_PCM_16BIT
    // 会话驻留：同格式切歌跳过 handle.start（端点零操作，UAPP 式）。
    @Volatile private var startedSr = -1
    @Volatile private var startedCh = -1
    @Volatile private var startedEnc = -1

    override fun configure(sampleRate: Int, channels: Int, encoding: Int): Boolean {
        this.encoding = encoding
        if (handle.isStarted && sampleRate == startedSr && channels == startedCh && encoding == startedEnc) {
            android.util.Log.i("UacSink", "configure: session keep-alive, skip handle.start sr=$sampleRate ch=$channels enc=$encoding")
            return true
        }
        val srcBits = when (encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> 16
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
            AudioFormat.ENCODING_PCM_32BIT -> 32
            AudioFormat.ENCODING_PCM_FLOAT -> 32
            else -> 16
        }
        val ok = handle.start(sampleRate, channels, srcBits, encoding)
        if (ok) {
            startedSr = sampleRate; startedCh = channels; startedEnc = encoding
        }
        return ok
    }

    override fun write(data: ByteArray, offset: Int, len: Int): Boolean {
        val target = appVolume * sysVolume
        if (target < 0.999f || currentGain < 0.999f) {
            applyGainRamp(data, offset, len, target)
        }
        return handle.write(data, offset, len) >= 0
    }

    /// 按 encoding 逐采样施加增益，本缓冲内从 currentGain 线性斜坡到 target。
    private fun applyGainRamp(data: ByteArray, offset: Int, len: Int, target: Float) {
        val g0 = currentGain
        when (encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> {
                val n = len / 2
                var k = 0
                var i = offset
                while (k < n) {
                    val g = g0 + (target - g0) * (k + 1) / n
                    val s = ((data[i].toInt() and 0xff) or (data[i + 1].toInt() shl 8)).toShort()
                    val v = (s * g).toInt().coerceIn(-32768, 32767)
                    data[i] = (v and 0xff).toByte()
                    data[i + 1] = ((v shr 8) and 0xff).toByte()
                    i += 2
                    k++
                }
            }
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> {
                val n = len / 3
                var k = 0
                var i = offset
                while (k < n) {
                    val g = g0 + (target - g0) * (k + 1) / n
                    var s = (data[i].toInt() and 0xff) or
                        ((data[i + 1].toInt() and 0xff) shl 8) or
                        ((data[i + 2].toInt() and 0xff) shl 16)
                    if (s and 0x800000 != 0) s = s or -0x1000000
                    val v = (s * g).toInt().coerceIn(-0x800000, 0x7fffff)
                    data[i] = (v and 0xff).toByte()
                    data[i + 1] = ((v shr 8) and 0xff).toByte()
                    data[i + 2] = ((v shr 16) and 0xff).toByte()
                    i += 3
                    k++
                }
            }
            AudioFormat.ENCODING_PCM_32BIT -> {
                val n = len / 4
                var k = 0
                var i = offset
                while (k < n) {
                    val g = g0 + (target - g0) * (k + 1) / n
                    val s = (data[i].toInt() and 0xff) or
                        ((data[i + 1].toInt() and 0xff) shl 8) or
                        ((data[i + 2].toInt() and 0xff) shl 16) or
                        (data[i + 3].toInt() shl 24)
                    val v = (s.toDouble() * g).toLong().coerceIn(
                        Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong(),
                    ).toInt()
                    data[i] = (v and 0xff).toByte()
                    data[i + 1] = ((v shr 8) and 0xff).toByte()
                    data[i + 2] = ((v shr 16) and 0xff).toByte()
                    data[i + 3] = ((v shr 24) and 0xff).toByte()
                    i += 4
                    k++
                }
            }
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val n = len / 4
                var k = 0
                var i = offset
                while (k < n) {
                    val g = g0 + (target - g0) * (k + 1) / n
                    val bits = (data[i].toInt() and 0xff) or
                        ((data[i + 1].toInt() and 0xff) shl 8) or
                        ((data[i + 2].toInt() and 0xff) shl 16) or
                        (data[i + 3].toInt() shl 24)
                    val v = Float.fromBits(bits) * g
                    val vb = v.toRawBits()
                    data[i] = (vb and 0xff).toByte()
                    data[i + 1] = ((vb shr 8) and 0xff).toByte()
                    data[i + 2] = ((vb shr 16) and 0xff).toByte()
                    data[i + 3] = ((vb shr 24) and 0xff).toByte()
                    i += 4
                    k++
                }
            }
        }
        currentGain = target
    }

    override fun setVolume(value: Float) {
        appVolume = value
    }

    override fun setSystemVolume(ratio: Float) {
        sysVolume = ratio
    }

    override fun close() {
        startedSr = -1; startedCh = -1; startedEnc = -1
        handle.stopInternal()
    }
}

/// 回退输出：AudioTrack 直通（原采样率 PCM 直出）。未插 USB DAC 时使用。
class AudioTrackSink(private val volumeRef: FloatArray) : PcmSink {
    override val backend = "audiotrack"
    override val description: String? = null

    private var track: AudioTrack? = null

    override fun configure(sampleRate: Int, channels: Int, encoding: Int): Boolean {
        // 声道 mask 按实际声道数：标准组合用位置 mask（1/2/4/6/8），
        // 3/5/7 等非标准组合用声道索引 mask（API 28+ 支持任意声道数，
        // 帧长严格=channels，绝不错帧）。
        val channelMask = when (channels) {
            1 -> AudioFormat.CHANNEL_OUT_MONO
            2 -> AudioFormat.CHANNEL_OUT_STEREO
            4 -> AudioFormat.CHANNEL_OUT_QUAD
            6 -> AudioFormat.CHANNEL_OUT_5POINT1
            8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
            else -> 0
        }
        val indexMask = if (channelMask == 0) ((1 shl channels) - 1) else 0
        val maskForBuf = if (channelMask == 0) AudioFormat.CHANNEL_OUT_STEREO else channelMask
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate, maskForBuf,
            if (encoding == AudioFormat.ENCODING_PCM_FLOAT) AudioFormat.ENCODING_PCM_FLOAT
            else AudioFormat.ENCODING_PCM_16BIT,
        )
        return try {
            val fb = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(encoding)
            if (channelMask != 0) fb.setChannelMask(channelMask)
            // setChannelIndexMask 是 API 28+；Android 8.x（API 26/27）无此方法，
            // 非标准声道组合退化为立体声 mask（会有错帧风险，但不崩——约束4）。
            if (indexMask != 0 && android.os.Build.VERSION.SDK_INT >= 28) {
                fb.setChannelIndexMask(indexMask)
            }
            val fmt = fb.build()
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            val t = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(fmt)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(minBuf * 4)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build()
            t.setVolume(volumeRef[0])
            t.play()
            track = t
            true
        } catch (e: Exception) {
            // 个别设备不支持 24/32 位直通 → 回退 16 位（此路径不是 bit-perfect，
            // 仅保证出声；USB 独占路径不受影响）。
            try {
                val t = AudioTrack(
                    AudioManager.STREAM_MUSIC, sampleRate, maskForBuf,
                    AudioFormat.ENCODING_PCM_16BIT, minBuf * 4, AudioTrack.MODE_STREAM,
                )
                t.setVolume(volumeRef[0])
                t.play()
                track = t
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    override fun write(data: ByteArray, offset: Int, len: Int): Boolean {
        val t = track ?: return false
        // float/24 位编码 AudioTrack.write 直接吃对应字节序的缓冲。
        return try {
            t.write(data, offset, len) >= 0
        } catch (_: Exception) {
            false
        }
    }

    override fun setVolume(value: Float) {
        volumeRef[0] = value
        try {
            track?.setVolume(value)
        } catch (_: Exception) {
        }
    }

    override fun close() {
        try {
            track?.stop()
        } catch (_: Exception) {
        }
        track?.release()
        track = null
    }
}
