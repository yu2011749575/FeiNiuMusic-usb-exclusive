package com.feiniu.usb_audio_exclusive

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteBuffer

/// 独占解码管线：MediaExtractor + MediaCodec → 原始 PCM → PcmSink。
///
/// 与常规播放链路的差别：
/// - 不经过 AudioTrack/AAudio 的系统混音/重采样（sink 自己决定去向）；
/// - 优先申请整数 PCM 输出（16/24/32 位），24 位 FLAC/ALAC 不被压成 16 位；
/// - CUE 曲目按 [startMs, endMs) 裁剪。
class ExclusiveDecoder(
    private val url: String,
    private val headers: Map<String, String>,
    private val isFile: Boolean,
    private val startMs: Long,
    private val endMs: Long?,
    private val sink: PcmSink,
    private val listener: Listener,
) {
    interface Listener {
        fun onState(state: String, message: String? = null)
        fun onProgress(positionMs: Long, durationMs: Long?)
        fun onFormat(sampleRate: Int, channels: Int, encoding: Int)
    }

    private val lock = Object()
    @Volatile private var paused = false
    @Volatile private var stopFlag = false
    @Volatile private var closed = false // P0-1：sink 已释放后禁止再写（UAF 守卫）
    @Volatile private var seekTarget = -1L
    @Volatile private var volume = 1.0f

    private var thread: Thread? = null

    fun start() {
        thread = Thread({ run() }, "ExclusiveDecoder").also { it.start() }
    }

    fun pause() {
        synchronized(lock) {
            paused = true
        }
    }

    fun resume() {
        synchronized(lock) {
            paused = false
            lock.notifyAll()
        }
    }

    fun seek(ms: Long) {
        seekTarget = ms
        resume()
    }

    fun setVolume(v: Float) {
        volume = v
        sink.setVolume(v)
    }

    /// 系统媒体音量比（手机音量键）→ UacSink 软件增益（AudioTrack 后端忽略）。
    fun setSystemVolume(r: Float) {
        sink.setSystemVolume(r)
    }

    fun stop() {
        stopFlag = true
        resume()
        thread?.join(1500)
        // P0-1：join 超时后 decoder 线程可能还活着 → 先封死 sink 写入口
        // （closed 置位后 run() 不再调 sink.write），杜绝悬垂写入。
        closed = true
        if (thread?.isAlive == true) {
            thread?.interrupt()
            thread?.join(500)
        }
    }

    /// 释放输出后端（UacSink → handle.stopInternal → native 会话销毁）。
    /// 切歌必须调用：否则旧 native 会话的 URB 线程继续存活，与新会话竞态。
    fun closeSink() {
        closed = true // 先封写入口，再释放（顺序不能反）
        try {
            sink.close()
        } catch (_: Exception) {
        }
    }

    private fun waitIfPaused() {
        synchronized(lock) {
            while (paused && !stopFlag) {
                try {
                    lock.wait()
                } catch (_: InterruptedException) {
                }
            }
        }
    }

    private fun run() {
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        try {
            listener.onState("loading")
            android.util.Log.i("UsbAudioExclusiveDecoder", "open begin isFile=$isFile")
            extractor = MediaExtractor()
            if (isFile) {
                extractor.setDataSource(url)
            } else {
                // 网络开流预热：MediaExtractor 网络栈固定 ~30.46s 超时重试
                // (2026-09-26 实锤4次: 30.46/30.48/30.46/30.49s)。先用自带可控
                // 超时的连接把 DNS/TCP/重定向热身一次，4s 即放行绝不拖慢。
                val t0 = android.os.SystemClock.elapsedRealtime()
                var code = -1
                var host = "?"
                var err = ""
                try {
                    host = java.net.URI(url).host ?: "file"
                    val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                    conn.connectTimeout = 4000
                    conn.readTimeout = 8000
                    conn.instanceFollowRedirects = true
                    conn.setRequestMethod("GET")
                    for ((k, v) in headers) conn.setRequestProperty(k, v)
                    code = conn.responseCode
                    try { conn.inputStream.use { it.read(ByteArray(4096)) } } catch (_: Exception) {}
                    conn.disconnect()
                } catch (e: Exception) {
                    err = e.javaClass.simpleName
                }
                val dt = android.os.SystemClock.elapsedRealtime() - t0
                android.util.Log.i("UsbAudioExclusiveDecoder", "preflight host=$host code=$code dt=${dt}ms err=$err")
                extractor.setDataSource(url, headers)
            }
            android.util.Log.i("UsbAudioExclusiveDecoder", "extractor open ok tracks=${extractor.trackCount}")

            // 找音频轨。
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) {
                listener.onState("error", "no audio track")
                return
            }
            extractor.selectTrack(trackIndex)

            // MediaFormat 无 KEY_BITS_PER_SAMPLE 常量；部分 extractor 以裸键名给出，
            // 否则从 KEY_PCM_ENCODING 推定位深，默认 16。
            val srcBitDepth = when {
                format.containsKey("bits-per-sample") ->
                    format.getInteger("bits-per-sample")
                format.containsKey(MediaFormat.KEY_PCM_ENCODING) ->
                    when (format.getInteger(MediaFormat.KEY_PCM_ENCODING)) {
                        AudioFormat.ENCODING_PCM_FLOAT -> 32
                        AudioFormat.ENCODING_PCM_32BIT -> 32
                        AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
                        else -> 16
                    }
                else -> 16
            }

            // 申请整数 PCM 输出：按源位深选 24/32/16（bit-perfect 前提）。
            val wantEncoding = when {
                srcBitDepth > 24 -> AudioFormat.ENCODING_PCM_32BIT
                srcBitDepth > 16 -> AudioFormat.ENCODING_PCM_24BIT_PACKED
                else -> AudioFormat.ENCODING_PCM_16BIT
            }
            try {
                format.setInteger(MediaFormat.KEY_PCM_ENCODING, wantEncoding)
            } catch (_: Exception) {
            }

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            android.util.Log.i("UsbAudioExclusiveDecoder", "codec started mime=$mime bitDepth=$srcBitDepth")

            if (startMs > 0) {
                // 同上：seekTo 收微秒（CUE startMs 是毫秒）。
                extractor.seekTo(startMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            // 写失败标志：sink.write 失败是"错误终止"，循环结束后绝不能再报
            // completed——引擎收到 completed 会自动连播下一首，在降级期把第二个
            // usb 会话拉起来和系统流互殴（ECHO-A 爆音根因之一，2026-09-25）。
            var writeFailed = false
            var lastReport = 0L
            var seekDebug = 0
            var configured = false
            // A：INFO_OUTPUT_FORMAT_CHANGED 时捕获的真实输出格式（未触发则退回 codec.outputFormat）。
            var outFormat: MediaFormat? = null
            // B：首帧暂存——帧几何校验需要相邻两帧 pts 差，等第二帧一起判定后放行。
            var holdBuf: ByteArray? = null
            var holdPtsUs = 0L
            var durationMs: Long? =
                if (format.containsKey(MediaFormat.KEY_DURATION))
                    format.getLong(MediaFormat.KEY_DURATION) / 1000 else null

            // 单帧送入 sink：CUE 裁剪 + P0-1 写守卫 + P2-8 写失败降级 + 进度回报。
            fun emitFrame(bytes: ByteArray, ptsUs: Long) {
                // CUE 裁剪：超过 endMs 提前完成。
                if (endMs != null && ptsUs / 1000 >= endMs) {
                    outputDone = true
                    return
                }
                // P0-1：sink 已释放（closed）时禁止再写——旧线程
                // 残活窗口的悬垂写入是 UAF 根源。
                if (closed || stopFlag) {
                    outputDone = true
                    return
                }
                if (!sink.write(bytes, 0, bytes.size)) {
                    // P2-8：写失败（URB 管线死亡/设备拔出）→
                    // 报 error 触发上层优雅降级到系统输出，
                    // 不是默默当"播完"。
                    writeFailed = true
                    if (!stopFlag && !closed) {
                        listener.onState("error", "usb write failed")
                    }
                    outputDone = true
                    return
                }
                val pos = ptsUs / 1000
                if (pos - lastReport >= 250 || lastReport == 0L) {
                    lastReport = pos
                    listener.onProgress(pos, durationMs)
                }
            }

            while (!outputDone && !stopFlag) {
                // seek
                val seek = seekTarget
                if (seek >= 0) {
                    seekTarget = -1
                    // MediaExtractor.seekTo 参数是微秒！传 ms 会落到 target/1000
                    // 秒（=永远回开头），2026-09-26 实锤：seek 248544ms 落 0.248s。
                    extractor.seekTo(seek * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    codec.flush()
                    inputDone = false
                    // flush 后暂存帧已过期；若尚未定格式，重新累计几何样本。
                    holdBuf = null
                    // 后退 seek 后 pos-lastReport 为负，>=250 判定永久不成立 →
                    // 进度停报。归零让下一帧无条件上报。
                    lastReport = 0L
                    android.util.Log.i("UsbAudioExclusiveDecoder", "seekTo target=${seek}ms sampleTime=${extractor.sampleTime}us dur=${durationMs}ms")
                    seekDebug = 20
                }
                waitIfPaused()
                if (stopFlag) break

                if (seekDebug > 0) {
                    android.util.Log.i("UsbAudioExclusiveDecoder", "seekdbg pre inDone=$inputDone paused=$paused stop=$stopFlag")
                }
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf: ByteBuffer = codec.getInputBuffer(inIndex)!!
                        val n = extractor.readSampleData(buf, 0)
                        if (seekDebug > 0) {
                            android.util.Log.i("UsbAudioExclusiveDecoder", "seekdbg read n=$n sampleTime=${extractor.sampleTime}")
                        }
                        if (n < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (seekDebug > 0) {
                    seekDebug--
                    android.util.Log.i("UsbAudioExclusiveDecoder", "seekdbg out=$outIndex")
                }
                when {
                    outIndex >= 0 -> {
                        val outBuf: ByteBuffer = codec.getOutputBuffer(outIndex)!!
                        if (info.size > 0) {
                            val bytes = ByteArray(info.size)
                            outBuf.position(info.offset)
                            outBuf.get(bytes)
                            if (!configured) {
                                if (holdBuf == null) {
                                    // B：首帧暂存，等第二帧 pts 差做几何校验后放行。
                                    holdBuf = bytes
                                    holdPtsUs = info.presentationTimeUs
                                } else {
                                    // A：真实输出格式以 INFO_OUTPUT_FORMAT_CHANGED
                                    // 捕获的为准（outputFormat 可能回显请求值）。
                                    val of = outFormat ?: codec.outputFormat
                                    val sr = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                                    val ch = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                                    val declaredEnc = if (of.containsKey(MediaFormat.KEY_PCM_ENCODING))
                                        of.getInteger(MediaFormat.KEY_PCM_ENCODING)
                                    else AudioFormat.ENCODING_PCM_16BIT
                                    // B/C：帧几何自愈，优先级 实测 > outputFormat > 请求值；
                                    // 无法判定按 16bit 保守处理，禁止按错位帧长写 URB。
                                    val enc = fixEncoding(
                                        declaredEnc, ch,
                                        holdBuf!!.size, bytes.size,
                                        holdPtsUs, info.presentationTimeUs, sr,
                                    )
                                    if (!sink.configure(sr, ch, enc)) {
                                        android.util.Log.i("UsbAudioExclusiveDecoder", "configure FAILED sr=$sr ch=$ch enc=$enc")
                                        listener.onState("error", "output configure failed")
                                        return
                                    }
                                    android.util.Log.i("UsbAudioExclusiveDecoder", "configured ok sr=$sr ch=$ch enc=$enc firstFramePtsUs=$holdPtsUs")
                                    sink.setVolume(volume)
                                    listener.onFormat(sr, ch, enc)
                                    listener.onState("ready")
                                    configured = true
                                    // 放行暂存的首帧，再处理当前帧。
                                    val held = holdBuf!!
                                    holdBuf = null
                                    emitFrame(held, holdPtsUs)
                                }
                            }
                            if (configured && holdBuf == null) {
                                emitFrame(bytes, info.presentationTimeUs)
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // A：捕获真实输出格式（sink 配置延后到第二帧，见上）。
                        outFormat = codec.outputFormat
                    }
                }
            }
            if (!stopFlag && !writeFailed) {
                listener.onState("completed")
            }
        } catch (e: Exception) {
            listener.onState("error", e.message ?: e.javaClass.simpleName)
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            try {
                extractor?.release()
            } catch (_: Exception) {
            }
        }
    }

    /// 每采样字节数（打包 PCM）。
    private fun bytesPerSample(enc: Int): Int = when (enc) {
        AudioFormat.ENCODING_PCM_16BIT -> 2
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
        AudioFormat.ENCODING_PCM_32BIT -> 4
        AudioFormat.ENCODING_PCM_FLOAT -> 4
        else -> 2
    }

    /// 由实测每采样字节数反推编码；4 字节有 32bit/float 歧义时保留声明倾向。
    private fun encodingForBytesPerSample(bps: Int, declared: Int): Int = when (bps) {
        2 -> AudioFormat.ENCODING_PCM_16BIT
        3 -> AudioFormat.ENCODING_PCM_24BIT_PACKED
        4 -> if (declared == AudioFormat.ENCODING_PCM_FLOAT) AudioFormat.ENCODING_PCM_FLOAT
            else AudioFormat.ENCODING_PCM_32BIT
        else -> AudioFormat.ENCODING_PCM_16BIT
    }

    /// B/C：帧几何自愈——用相邻两输出帧 pts 差求真实帧数，得实测 bytesPerFrame；
    /// 与声明帧长（ch × bytesPerSample）不符时以实测为准（实测 > outputFormat > 请求值）。
    /// 无法判定时保守按 16bit（方案 C）：声明与数据不一致 = 帧错位 = 噪声+啸叫，致命。
    private fun fixEncoding(
        declared: Int,
        channels: Int,
        bytes1: Int,
        bytes2: Int,
        pts1Us: Long,
        pts2Us: Long,
        sampleRate: Int,
    ): Int {
        if (channels <= 0 || sampleRate <= 0) return declared
        val declaredFrame = channels * bytesPerSample(declared)
        // 实测帧数 = 首帧 pts 跨度 × 采样率（us → 帧），pts 有 ±1 抖动故容差 1。
        val dUs = pts2Us - pts1Us
        val frames = if (dUs > 0) (dUs * sampleRate + 500_000L) / 1_000_000L else 0L
        if (frames > 0) {
            for (cand in longArrayOf(frames, frames - 1, frames + 1)) {
                if (cand <= 0 || bytes1 % cand != 0L) continue
                val frameSize = (bytes1 / cand).toInt()
                if (frameSize <= 0 || frameSize % channels != 0) continue
                if (bytes2 % frameSize != 0) continue
                return if (frameSize == declaredFrame) {
                    declared // 与声明一致，无需修正
                } else {
                    val fixed = encodingForBytesPerSample(frameSize / channels, declared)
                    android.util.Log.i(
                        "UsbUacOutput",
                        "enc fix: declared=$declared actual=$fixed (frame $declaredFrame->$frameSize)",
                    )
                    fixed
                }
            }
        }
        // C：几何不可判定（单缓冲文件等）→ 退化为整除性校验，仍不符则保守 16bit。
        return if (bytes1 % declaredFrame == 0 && bytes2 % declaredFrame == 0) {
            declared
        } else {
            android.util.Log.i(
                "UsbUacOutput",
                "enc fix: declared=$declared actual=${AudioFormat.ENCODING_PCM_16BIT} (fallback)",
            )
            AudioFormat.ENCODING_PCM_16BIT
        }
    }
}
