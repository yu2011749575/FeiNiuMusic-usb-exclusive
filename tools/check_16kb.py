"""检查 APK/arm64 .so 的 ELF LOAD 段对齐（16KB 页要求 p_align>=16384）。"""
import struct
import sys
import zipfile

def check_so(data, name):
    if data[:4] != b'\x7fELF':
        return (name, 'not-ELF')
    is64 = data[4] == 2
    if not is64:
        return (name, '32bit')
    e_phoff = struct.unpack_from('<Q', data, 32)[0]
    e_phentsize = struct.unpack_from('<H', data, 54)[0]
    e_phnum = struct.unpack_from('<H', data, 56)[0]
    worst = 0
    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags = struct.unpack_from('<II', data, off)
        p_align = struct.unpack_from('<Q', data, off + 48)[0]
        if p_type == 1:  # PT_LOAD
            loads.append(p_align)
            worst = max(worst, p_align)
    ok = worst >= 16384
    return (name, 'OK(%d)' % worst if ok else 'FAIL align=%d [%s]' % (worst, ','.join(str(x) for x in loads)))


def main():
    apk = sys.argv[1]
    with zipfile.ZipFile(apk) as z:
        sos = [n for n in z.namelist() if n.endswith('.so') and 'arm64' in n]
        fails = 0
        for n in sorted(sos):
            name, res = check_so(z.read(n), n.split('/')[-1])
            mark = '✔' if res.startswith('OK') else '✘'
            if not res.startswith('OK'):
                fails += 1
            print('%s %s: %s' % (mark, name, res))
        print('---\n%d/%d 未对齐' % (fails, len(sos)))


if __name__ == '__main__':
    main()
