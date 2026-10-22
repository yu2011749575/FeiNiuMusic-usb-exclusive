import struct

def load(path, n=4000000):
    with open(path, 'rb') as f:
        return f.read(n)

data = load('cap_g3_in_head.pcm')

def get(bps, ch):
    def g(b, i, n):
        v = 0
        for k in range(n):
            v |= b[i + k] << (8 * k)
        bits = n * 8
        return v - (1 << bits) if v & (1 << (bits - 1)) else v
    return g

def stats(bps, ch, start=200000, count=300000):
    """帧长= bps*ch。返回: 逐采样diff/energy(各声道) + L/R 相关性"""
    g = get(bps, ch)
    fr = bps * ch
    n_frames = min(count // fr, (len(data) - start) // fr)
    diffs = [0.0] * ch; energies = [0.0] * ch
    sl = sr_ = cov = el = er = 0.0
    prev = None
    for f in range(n_frames):
        base = start + f * fr
        vals = [g(data, base + c * bps, bps) for c in range(ch)]
        if prev is not None:
            for c in range(ch):
                d = vals[c] - prev[c]
                diffs[c] += d * d
                energies[c] += vals[c] * vals[c]
        if ch == 2:
            sl += vals[0]; sr_ += vals[1]
            cov += vals[0] * vals[1]
            el += vals[0] * vals[0]; er += vals[1] * vals[1]
        prev = vals
    de = [diffs[c] / energies[c] if energies[c] else 999 for c in range(ch)]
    lr = 0.0
    if ch == 2 and el > 0 and er > 0:
        lr = cov / ((el ** 0.5) * (er ** 0.5))
    return de, lr, n_frames

print(f"{'frame':>12} {'diff/energy ch0':>16} {'ch1':>8} {'LRcorr':>8}")
for bps, ch in [(2, 2), (3, 2), (4, 2), (8, 2), (2, 1), (3, 1), (4, 1)]:
    de, lr, n = stats(bps, ch)
    de_s = "/".join(f"{x:.3f}" for x in de)
    print(f"{bps*8}bit/{ch}ch ({bps*ch}B): {de_s:>16} {lr:>8.3f}  n={n}")
print()
print("判据: diff/energy小=该声道为真实音频; LRcorr高=真实立体声; 两者同时成立=正确帧格式")
