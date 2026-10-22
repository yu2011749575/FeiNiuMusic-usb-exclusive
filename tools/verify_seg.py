import sys

cap = open('uac_cap_in.pcm', 'rb').read()
out = open('uac_cap_out.pcm', 'rb').read()
CH = 176400.0

def cmp_exact(a, ao, b, bo, n):
    bad, first, done = 0, -1, 0
    while done < n:
        seg = min(1 << 20, n - done)
        if a[ao + done:ao + done + seg] != b[bo + done:bo + done + seg]:
            for k in range(seg):
                if a[ao + done + k] != b[bo + done + k]:
                    if first < 0:
                        first = done + k
                    bad += 1
        done += seg
    return bad, first

def segment_verify(name, cap_s, cap_e):
    """对 cap[cap_s:cap_e] 在 out 里独立锚定比对"""
    # 用非零窗口锚定
    p = cap_s
    while p < cap_e - 8192:
        w = cap[p:p + 8192]
        if w != b'\x00' * len(w):
            break
        p += 8192
    oi = out.find(cap[p:p + 8192])
    if oi < 0:
        print('%s: 锚定失败' % name)
        return None
    base = oi - (p - cap_s)
    n = cap_e - cap_s
    # out 侧可能有会话预填充插入，逐块推进 + 重同步
    ep, op, ins, bad, first = cap_s, base, 0, 0, -1
    while ep < cap_e:
        m = min(4096, cap_e - ep, len(out) - op)
        if m <= 0:
            break
        if cap[ep:ep + m] == out[op:op + m]:
            ep += m
            op += m
            continue
        w = cap[ep:ep + 8192]
        j = out.find(w, op, op + 200000)
        if j >= 0 and w != b'\x00' * len(w):
            ins += j - op
            op = j
            continue
        for k in range(m):
            if cap[ep + k] != out[op + k]:
                if first < 0:
                    first = ep + k
                bad += 1
        ep += m
        op += m
    print('%s: cap[%d:%d] 比对 %.1fs | 插入=%d B | 真失真=%d B first=%s' %
          (name, cap_s, cap_e, (ep - cap_s) / CH, ins, bad, first))
    return bad

# 段A：第一首（恢复+主体）cap[0:13443454]
b1 = cmp_exact(out, 70674, cap, 56562, 13443454 - 56562)
print('A1: 第一首主体 out[70674:] vs cap[56562:13443454] 比对 %.1fs 真失真=%d first=%s' %
      ((13443454 - 56562) / CH, b1[0], b1[1]))
b0 = cmp_exact(out, 70674 - 56562, cap, 0, 56562)
print('A0: 恢复碎片 cap[0:56562] 真失真=%d' % b0[0])

# 段B：第二首自动切换后
b2 = segment_verify('B: 第二首(auto-next)', 13443454, len(cap))
print()
ok = b1[0] == 0 and b0[0] == 0 and b2 == 0
print('RESULT:', 'PASS（bit-perfect）' if ok else 'CHECK')
