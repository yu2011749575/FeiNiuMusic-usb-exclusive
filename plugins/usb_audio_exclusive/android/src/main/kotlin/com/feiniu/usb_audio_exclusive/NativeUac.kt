package com.feiniu.usb_audio_exclusive

/// JNI 绑定：用户态 UAC2 输出驱动（usb_uac_output.cpp）。
object NativeUac {
    init {
        System.loadLibrary("usb_uac_output")
    }

    /// 解析 USB 设备的 UAC1/UAC2 配置描述符，返回 JSON（alt settings/时钟源等）。
    external fun nativeParse(fd: Int): String

    /// 启动输出管线（URB 环 + 时钟控制）。返回句柄（0=失败）。
    /// alt setting 必须已由 Java 层 UsbDeviceConnection.setInterface 选好
    /// （xHCI 只有 Java setInterface 才会为等时端点预留带宽）。
    /// [sampleRate]=源采样率；[wireRate]=协商后的线上采样率（DAC 最接近支持率，
    /// 不等时 native 侧做线性插值重采样）；[srcBits]=源位深（降位时 TPDF dither）。
    external fun nativeStart(
        fd: Int,
        iface: Int,
        alt: Int,
        epAddr: Int,
        maxPacket: Int,
        fbEp: Int,
        syncType: Int,
        sampleRate: Int,
        wireRate: Int,
        channels: Int,
        altChannels: Int,
        subframe: Int,
        srcBits: Int,
        inEnc: Int,
        highSpeed: Boolean,
        uac2: Boolean,
        clockId: Int,
        acIface: Int,
    ): Long

    /// 写入 PCM（输入编码=16/24/32 位整数），内部转 DAC 线格式（整数位移，
    /// 匹配位深时 bit-perfect）。缓冲满时阻塞（DAC 时钟回压）。返回 -1=已停止。
    external fun nativeWrite(handle: Long, data: ByteArray, offset: Int, len: Int): Int

    external fun nativeStop(handle: Long)
    external fun nativeClose(handle: Long)
    external fun nativeUnderruns(handle: Long): Int
}
