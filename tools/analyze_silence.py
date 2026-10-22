"""分析采集：out(in=解码PCM, out=DAC线位流) 的静音段分布 + 会话开头零段长度。"""
import array
import sys


def zero_runs(data, bps=2, ch=2, frame=None):
    """返回 [(start_byte, length_bytes)] 的静音段（采样全零），frame=帧长。"""
    if frame is None:
        frame = bps * ch
    runs = []
    i = 0
    n = len(data) // frame * frame
    cur_start = None
    while i < n:
        # 4KB 快速扫描块内是否全零
        blk = data[i:i + frame * 64]
        nonzero = any(blk)
        if not nonzero:
            if cur_start is None:
                cur_start = i
        else:
            if cur_start is not None:
                runs.append((cur_start, i - cur_start))
                cur_start = None
        i += frame * 64
    if cur_start is not None:
        runs.append((cur_start, n - cur_start))
    return runs


def main(indir, rate=48000, ch=2):
    fin = open(indir + '/r1_in.pcm', 'rb').read()
    fout = open(indir + '/r1_out.pcm', 'rb').read()
    frame = 2 * ch  # 16bit
    print('in=%dB out=%dB' % (len(fin), len(fout)))
    for name, d in (('in(解码PCM)', fin), ('out(DAC位流)', fout)):
        runs = zero_runs(d, frame=frame)
        big = [(s, l) for s, l in runs if l >= frame * 64]  # 只看>=64帧(1.45ms@44.1k)的
        print('\n%s: 静音段数(>=64帧)=%d' % (name, len(big)))
        for s, l in big[:15]:
            ms = l / (frame * rate) * 1000
            print('   offset=%9dB len=%8dB = %7.1f ms' % (s, l, ms))
        if len(big) > 15:
            print('   ... 共 %d 段' % len(big))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
