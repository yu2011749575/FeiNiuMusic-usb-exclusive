# -*- coding: utf-8 -*-
"""
dac_stress.py — FeiNiuMusic USB 独占无损压测（多 DAC 轮换）
=========================================================

目的：确保【该无损的时候一定是 USB 独占的无损】。对每个插入的 USB DAC：
  1) 自动点歌播放（UI 自动化）+ 布防 uac_cap 采集；
  2) 三方交叉验证：
     - DAC 能力（App 描述符解析 alt 列表）：源率/位深有没有 native 支持；
     - 协商声明（logcat negotiate）：resample / dither / srcBits / altBits；
     - 采集实测（in/out PCM）：meta 声明帧长 vs 数据几何、out 位流 vs in 逐字节比对。
  3) 判定逻辑：
     - DAC 支持源采样率且位深充足 → 【必须】resample=false & dither=false &
       sink=usb_uac & 采集比对真失真=0B（只允许插入不允许替换 = bit-perfect）；
     - DAC 不支持 → 允许降级（重采样/dither），但出流必须健康（体量比/能量）。
  4) 换 DAC：插好新设备按回车继续，脚本自动等枚举、自动点 USB 授权弹窗。

用法（cmd 里）：
  python dac_stress.py                       # 默认：每 DAC 3 轮，每轮 25s
  python dac_stress.py --rounds 5 --secs 30
  python dac_stress.py --songs "あのバンド,After the Battle"
  python dac_stress.py --analyze-only        # 只分析已拉取的 uac_cap_*.pcm（调参用）

依赖：adb（默认 D:/android-sdk/platform-tools/adb.exe）、手机已连、App 已装、
      DAC 已插。判定算法自包含（移植 workspace/analyze_fmt2.py + verify_seg.py）。
"""

import argparse
import os
import re
import subprocess
import sys
import time

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

APP = 'com.feiniu.music'
DEFAULT_SONGS = 'あのバンド,After the Battle'
CAP_DIR = 'files'          # run-as 工作目录下
WORKDIR = os.path.dirname(os.path.abspath(__file__))

# ----------------------------------------------------------------------------
# adb 基础
# ----------------------------------------------------------------------------

class Adb:
    def __init__(self, serial, adb_path):
        self.serial = serial
        self.adb = adb_path

    def _base(self):
        return [self.adb, '-s', self.serial]

    def shell(self, cmd, timeout=60):
        """远程 shell 命令（整条命令作为一个参数传入，避免引号被吞）。"""
        p = subprocess.run(self._base() + ['shell', cmd],
                           capture_output=True, timeout=timeout)
        return p.stdout.decode('utf-8', 'replace')

    def shell_bytes(self, cmd, timeout=120):
        p = subprocess.run(self._base() + ['shell', cmd],
                           capture_output=True, timeout=timeout)
        return p.stdout

    def exec_out_to_file(self, cmd, dest, timeout=180):
        """exec-out 拉二进制流到本地文件（run-as cat 大文件安全）。"""
        with open(dest, 'wb') as f:
            p = subprocess.run(self._base() + ['exec-out', cmd],
                               stdout=f, stderr=subprocess.PIPE, timeout=timeout)
        return p.returncode == 0 and os.path.getsize(dest) if os.path.exists(dest) else 0

    def logcat(self, clear=False):
        if clear:
            subprocess.run(self._base() + ['logcat', '-c'], capture_output=True, timeout=30)
            return ''
        p = subprocess.run(self._base() + ['logcat', '-d', '-t', '3000'],
                           capture_output=True, timeout=60)
        return p.stdout.decode('utf-8', 'replace')


def pick_serial(adb_path):
    p = subprocess.run([adb_path, 'devices'], capture_output=True, timeout=30)
    for line in p.stdout.decode('utf-8', 'replace').splitlines():
        if '\tdevice' in line:
            return line.split('\t')[0]
    return None


# ----------------------------------------------------------------------------
# UI 自动化（uiautomator dump 解析；dump 偶发 idle 超时 → 重试 3 次）
# ----------------------------------------------------------------------------

NODE_RE = re.compile(
    r'text="(?P<text>[^"]*)"[^>]*?content-desc="(?P<desc>[^"]*)"[^>]*?'
    r'clickable="(?P<click>[a-z]+)"[^>]*?bounds="\[(?P<x0>\d+),(?P<y0>\d+)\]\[(?P<x1>\d+),(?P<y1>\d+)\]"'
)


def uidump(adb):
    for _ in range(3):
        adb.shell('uiautomator dump /sdcard/ui.xml')
        xml = adb.shell('cat /sdcard/ui.xml')
        if '<node' in xml:
            return xml
        time.sleep(1)
    return ''


def find_nodes(xml, needle, clickable_only=False):
    """text 或 content-desc 含 needle 的节点列表 [(cx, cy, y0, y1, text, desc)]。
    默认不过滤 clickable：Flutter 的文字常在不可点击子节点上，点中心照样命中
    可点击父级。"""
    out = []
    for m in NODE_RE.finditer(xml):
        if clickable_only and m.group('click') != 'true':
            continue
        text = m.group('text').replace('&#10;', '\n')
        desc = m.group('desc').replace('&#10;', '\n')
        if needle in text or needle in desc:
            x0, y0, x1, y1 = (int(m.group(k)) for k in ('x0', 'y0', 'x1', 'y1'))
            out.append(((x0 + x1) // 2, (y0 + y1) // 2, y0, y1, text, desc))
    return out


def tap(adb, x, y):
    adb.shell('input tap %d %d' % (x, y))


def snap(adb, dest):
    """截图存本地（视觉核对用）。"""
    try:
        adb.exec_out_to_file('screencap -p', dest, timeout=60)
        return dest if os.path.exists(dest) and os.path.getsize(dest) > 10000 else None
    except Exception:
        return None


def keep_awake(adb):
    """防熄屏：常亮 30 分钟（熄屏会打断 UI 点击和采集）。"""
    adb.shell('svc power stayon true')
    adb.shell('settings put system screen_off_timeout 1800000')


def ensure_awake(adb):
    """每轮前检查亮屏；睡着就唤醒+上滑解锁。返回是否本来就醒着。"""
    st = adb.shell('dumpsys power | grep mWakefulness=')
    if 'Awake' in st:
        return True
    adb.shell('input keyevent KEYCODE_WAKEUP')
    time.sleep(1)
    adb.shell('input swipe 540 1600 540 600 300')  # 上滑解锁
    time.sleep(1)
    return False


def pick_window(data, size=300000, step=65536):
    """选 RMS 最大的窗口偏移（避开静音前奏/尾巴）。"""
    best_off, best_rms = 0, -1.0
    off = 0
    while off + size <= len(data):
        seg = data[off:off + size]
        ss = 0
        for i in range(0, len(seg) - 1, 2):
            v = seg[i] | (seg[i + 1] << 8)
            v = v - 65536 if v & 0x8000 else v
            ss += v * v
        rms = (ss / max(1, len(seg) // 2)) ** 0.5
        if rms > best_rms:
            best_rms, best_off = rms, off
        off += step
    return best_off, best_rms


def accept_usb_dialog(adb):
    """USB 授权弹窗：勾'始终允许'（若有）→ 点'允许/确定'。返回是否点过。"""
    xml = uidump(adb)
    if not xml:
        return False
    always = find_nodes(xml, '始终允许')
    if always:
        tap(adb, always[0][0], always[0][1])
        time.sleep(0.5)
        xml = uidump(adb)
    for label in ('允许', '确定', 'OK'):
        btns = find_nodes(xml, label)
        if btns:
            tap(adb, btns[0][0], btns[0][1])
            return True
    return False


def goto_songs_page(adb):
    xml = uidump(adb)
    if not xml:
        return False
    # 已经在歌曲列表（能看到"共"字样+歌曲标题行）
    rows = find_nodes(xml, '共')
    if rows and len(find_nodes(xml, '歌曲')) >= 1:
        return True
    # 底部导航"歌曲"tab（取 y 最大的）
    tabs = find_nodes(xml, '歌曲')
    if tabs:
        tap(adb, *max(tabs, key=lambda n: n[3])[:2])
        time.sleep(1.5)
        return True
    return False


def visible_titles(xml):
    nodes = [n for n in find_nodes(xml, '') if 300 < n[2] < 1900 and n[5].strip()]
    return [n[5] for n in nodes]


def play_song(adb, title, max_per_dir=30):
    """在歌曲列表按标题找歌并点击。列表滚动位置不可预知 → 双向扫描：
    先向顶部逐屏找（到头判定：可见标题不再变化），再向底部逐屏找。
    y>1900 的匹配是迷你播放栏，排除。返回 True=点击成功。"""
    phases = [
        ('input swipe 540 700 540 1600 350', '向顶'),   # 手指向下滑 → 顶部
        ('input swipe 540 1600 540 700 350', '向底'),   # 手指向上滑 → 底部
    ]
    for swipe, name in phases:
        prev = None
        for _ in range(max_per_dir):
            xml = uidump(adb)
            rows = [n for n in find_nodes(xml, title) if n[3] < 1900]
            if rows:
                tap(adb, rows[0][0], rows[0][1])
                return True
            vis = visible_titles(xml)
            if vis and vis == prev:
                break  # 这个方向到头了，换向
            prev = vis
            adb.shell(swipe)
            time.sleep(1.0)
    return False


# ----------------------------------------------------------------------------
# 采集：布防 / 拉取 / meta
# ----------------------------------------------------------------------------

def cap_prepare(adb):
    adb.shell('run-as %s sh -c "cd files && rm -f uac_cap_in.pcm uac_cap_out.pcm '
              'uac_cap_meta.txt uac_cap.on && touch uac_cap.on"' % APP)


def cap_pull(adb, tag, dest_dir):
    """拉采集三件套到 dest_dir/<tag>_*. 返回 meta dict 或 None。"""
    got = {}
    for name in ('uac_cap_in.pcm', 'uac_cap_out.pcm', 'uac_cap_meta.txt'):
        local = os.path.join(dest_dir, '%s_%s' % (tag, name.replace('uac_cap_', '')))
        n = adb.exec_out_to_file('run-as %s cat %s/%s' % (APP, CAP_DIR, name), local)
        got[name] = (local, n)
    meta_path = got['uac_cap_meta.txt'][0]
    meta = {}
    if os.path.exists(meta_path):
        txt = open(meta_path, 'r', encoding='utf-8', errors='replace').read()
        for kv in txt.replace('\n', ' ').split():
            if '=' in kv:
                k, v = kv.split('=', 1)
                meta[k] = v
    meta['_files'] = {k: v[0] for k, v in got.items()}
    meta['_sizes'] = {k: v[1] for k, v in got.items()}
    return meta


# ----------------------------------------------------------------------------
# logcat 解析
# ----------------------------------------------------------------------------

RE_NEG = re.compile(
    r'negotiate: src=(?P<src>\d+) wire=(?P<wire>\d+) resample=(?P<res>\w+) '
    r'srcBits=(?P<srcbits>\d+) altBits=(?P<altbits>\d+) dither=(?P<dither>\w+) '
    r'altCh=(?P<altch>\d+) srcCh=(?P<srcch>\d+)')
RE_UAC = re.compile(r'UAC start: rate=(?P<rate>\d+) ch=(?P<ch>\d+) subframe=(?P<sub>\d+)')
RE_SINK = re.compile(r'startPlayback sink=(?P<sink>\w[\w-]*)')
RE_ENCFIX = re.compile(r'enc fix: declared=(?P<dec>\d+) actual=(?P<act>\d+)')
RE_CAPS = re.compile(r'UsbUacParse: parse json=(?P<json>\{.*)')


def parse_logs(logcat):
    info = {'sink': None, 'neg': None, 'uac': None, 'enc_fix': [], 'caps': None}
    for line in logcat.splitlines():
        if 'startPlayback sink=' in line:
            info['sink'] = RE_SINK.search(line).group('sink')
        m = RE_NEG.search(line)
        if m:
            info['neg'] = {k: m.group(k) for k in m.groupdict()}
        m = RE_UAC.search(line)
        if m:
            info['uac'] = {k: m.group(k) for k in m.groupdict()}
        m = RE_ENCFIX.search(line)
        if m:
            info['enc_fix'].append((m.group('dec'), m.group('act')))
        m = RE_CAPS.search(line)
        if m:
            info['caps'] = m.group('json')
    return info


def caps_supports_lossless(caps_json, src_rate, src_ch, src_bits):
    """DAC 的 alt 列表里有没有 native 支持源率+声道+足够位深的 alt。"""
    if not caps_json:
        return None  # 未知
    try:
        import json
        alts = json.loads(caps_json).get('alts', [])
    except Exception:
        return None
    for a in alts:
        rates = a.get('rates') or []
        rate_ok = (int(src_rate) in [int(r) for r in rates]) or (
            a.get('rateMin', 0) <= int(src_rate) <= a.get('rateMax', 0) and a.get('rateMax', 0) > 0)
        if rate_ok and int(a.get('channels', 0)) == int(src_ch) \
                and int(a.get('bitDepth', 0)) >= int(src_bits):
            return True
    return False


# ----------------------------------------------------------------------------
# 采集分析（移植 analyze_fmt2.py）：meta 声明 vs 数据几何
# ----------------------------------------------------------------------------

def _read_int(b, i, n):
    v = 0
    for k in range(n):
        v |= b[i + k] << (8 * k)
    bits = n * 8
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def fmt_stats(data, bps, ch, start=200000, count=300000):
    """逐采样 diff/energy + L/R 相关性。真实音频 diff/energy≈0.1~0.5、LR 高；
    帧长错位时 diff/energy≈2（白噪声特征）、LR≈0。"""
    fr = bps * ch
    if len(data) < start + fr * 4:
        return None
    n_frames = min(count // fr, (len(data) - start) // fr)
    diffs = [0.0] * ch
    energies = [0.0] * ch
    sl = sr_ = cov = el = er = 0.0
    prev = None
    for f in range(n_frames):
        base = start + f * fr
        vals = [_read_int(data, base + c * bps, bps) for c in range(ch)]
        if prev is not None:
            for c in range(ch):
                d = vals[c] - prev[c]
                diffs[c] += d * d
                energies[c] += vals[c] * vals[c]
        if ch == 2:
            sl += vals[0]
            sr_ += vals[1]
            cov += vals[0] * vals[1]
            el += vals[0] * vals[0]
            er += vals[1] * vals[1]
        prev = vals
    de = [diffs[c] / energies[c] if energies[c] else 999 for c in range(ch)]
    lr = 0.0
    if ch == 2 and el > 0 and er > 0:
        n = float(n_frames)
        lr = (cov - sl * sr_ / n) / ((el - sl * sl / n) * (er - sr_ * sr_ / n)) ** 0.5 \
            if (el - sl * sl / n) > 0 and (er - sr_ * sr_ / n) > 0 else 0.0
    return de, lr


def detect_bps(data, ch, start=200000):
    """枚举帧长找真实几何：返回 (bps, de均值, lr) 或 None。"""
    best = None
    for bps in (2, 3, 4):
        st = fmt_stats(data, bps, ch, start=start)
        if not st:
            continue
        de, lr = st
        de_avg = sum(de) / len(de)
        score = de_avg - (0.3 if ch == 2 and lr > 0.3 else 0.0)
        if best is None or score < best[0]:
            best = (score, bps, de_avg, lr)
    if best is None:
        return None
    return best[1], best[2], best[3]


ENC_BYTES = {'2': 2, '21': 3, '22': 4, '4': 4}  # ENC_PCM_16/24_PACKED/32/FLOAT


# ----------------------------------------------------------------------------
# bit-perfect 比对（移植 verify_seg.py：只允许插入不允许替换）
# ----------------------------------------------------------------------------

def verify_stream(cap, out):
    """cap=in（解码 PCM），out=wire 位流。返回 dict(bad, ins, first, truncated)。"""
    res = {'bad': -1, 'ins': 0, 'first': -1, 'truncated': 0, 'msg': ''}
    if len(cap) < 16384 or len(out) < 16384:
        res['msg'] = '数据太少(in=%d out=%d)' % (len(cap), len(out))
        return res
    # 用首个非静音 8K 窗口锚定（out 侧可能有会话预填充插入）
    p = 0
    while p < len(cap) - 8192:
        w = cap[p:p + 8192]
        if w != b'\x00' * 8192:
            break
        p += 8192
    else:
        res['msg'] = 'cap 全静音'
        return res
    oi = out.find(w)
    if oi < 0:
        res['msg'] = '锚定失败（out 里找不到 in 的内容）'
        return res
    ep, op, ins, bad, first = p, oi, 0, 0, -1
    while ep < len(cap):
        m = min(4096, len(cap) - ep, len(out) - op)
        if m <= 0:
            break
        if cap[ep:ep + m] == out[op:op + m]:
            ep += m
            op += m
            continue
        w = cap[ep:ep + 8192]
        if len(w) == 8192 and w != b'\x00' * 8192:
            j = out.find(w, op, min(op + 200000, len(out)))
            if j >= 0:
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
    res.update(bad=bad, ins=ins, first=first,
               truncated=max(0, len(cap) - ep))
    return res


# ----------------------------------------------------------------------------
# 单轮测试
# ----------------------------------------------------------------------------

def run_round(adb, title, round_no, secs, dest_dir, keep):
    print('\n━━ 第 %d 轮：%s ━━' % (round_no, title))
    result = {'song': title, 'round': round_no, 'verdict': 'FAIL', 'reasons': []}

    # 1) 防熄屏检查 + 布防采集 + 清日志 + 点歌（不在歌曲页就先导航过去）
    if not ensure_awake(adb):
        goto_songs_page(adb)  # 唤醒解锁后 UI 状态不确定，先回歌曲页
        time.sleep(1)
    cap_prepare(adb)
    adb.logcat(clear=True)
    if not play_song(adb, title):
        goto_songs_page(adb)
        time.sleep(1)
        if not play_song(adb, title):
            result['reasons'].append('UI 找不到歌曲行：%s' % title)
            return result
    time.sleep(2)
    accept_usb_dialog(adb)  # 新 DAC 首播可能弹授权

    # 2) 等 startPlayback
    sink = None
    for _ in range(10):
        time.sleep(1)
        lg = parse_logs(adb.logcat())
        if lg['sink']:
            sink = lg['sink']
            break
    if not sink:
        result['reasons'].append('点歌后 10s 内没有 startPlayback（没开播）')
        return result

    # 2b) 视觉核对：播中截图 + 迷你栏歌名 + 异常弹窗（截图留档供视觉复查）
    shots_dir = os.path.join(dest_dir, 'shots')
    os.makedirs(shots_dir, exist_ok=True)
    mid_png = snap(adb, os.path.join(shots_dir, 'r%d_mid.png' % round_no))
    result['shot_mid'] = mid_png
    xml = uidump(adb)
    if xml:
        if title[:6] not in xml:
            reasons.append('播中 UI 未见歌名 %s（迷你栏/列表都不含，可能没点中）' % title[:6])
        for kw in ('错误', '失败', 'Error', '闪退'):
            if kw in xml:
                reasons.append('播中 UI 出现异常字样：%s' % kw)
                break

    # 3) 播放 secs 秒（原生进度条）
    for s in range(secs):
        bar = '#' * ((s + 1) * 30 // secs) + '-' * (30 - (s + 1) * 30 // secs)
        sys.stdout.write('\r   播放中 [%s] %2d/%ds ' % (bar, s + 1, secs))
        sys.stdout.flush()
        time.sleep(1)
    adb.shell('input keyevent 127')  # KEYCODE_MEDIA_PAUSE
    time.sleep(2)
    snap(adb, os.path.join(shots_dir, 'r%d_end.png' % round_no))

    # 4) 取证据
    lg = parse_logs(adb.logcat())
    tag = 'r%d' % round_no
    meta = cap_pull(adb, tag, dest_dir)
    result['meta'] = {k: v for k, v in meta.items() if not k.startswith('_')}

    # ---- 判定 ----
    reasons = result['reasons']
    neg, uac = lg['neg'], lg['uac']

    # 4a) 必须 USB 独占
    if lg['sink'] != 'usb_uac':
        reasons.append('sink=%s（不是 usb_uac 独占！）' % lg['sink'])
    if not neg:
        reasons.append('logcat 缺 negotiate 行')

    # 4b) 三方交叉：DAC 能力 vs 协商声明
    lossless_possible = None
    if neg:
        src_rate, src_ch, src_bits = neg['src'], neg['srcch'], neg['srcbits']
        lossless_possible = caps_supports_lossless(lg['caps'], src_rate, src_ch, src_bits)
        resample = neg['res'] == 'true'
        dither = neg['dither'] == 'true'
        print('   协商: src=%s/%sch/%sbit → wire=%s altBits=%s resample=%s dither=%s' % (
            src_rate, src_ch, src_bits, neg['wire'], neg['altbits'], neg['res'], neg['dither']))
        if lossless_possible is True and (resample or dither):
            reasons.append('DAC 本可 native 支持 却走了 resample/dither（该无损没无损）')
        if lossless_possible is False and not resample and not dither:
            reasons.append('DAC 不支持源率却声称 resample=false（声明与能力矛盾）')
    else:
        resample = dither = None

    # 4c) meta 声明帧长 vs 数据几何
    in_path = meta['_files'].get('uac_cap_in.pcm')
    out_path = meta['_files'].get('uac_cap_out.pcm')
    in_bytes = meta['_sizes'].get('uac_cap_in.pcm', 0)
    out_bytes = meta['_sizes'].get('uac_cap_out.pcm', 0)
    print('   采集: in=%.1fMB out=%.1fMB meta=%s' % (
        in_bytes / 1e6, out_bytes / 1e6,
        ' '.join('%s=%s' % (k, v) for k, v in meta.items() if not k.startswith('_'))))
    if in_bytes < 200000 or out_bytes < 200000:
        reasons.append('采集数据太少（in=%dB out=%dB）' % (in_bytes, out_bytes))
        return finish(result)
    cap = open(in_path, 'rb').read()
    out = open(out_path, 'rb').read()
    ch = int(meta.get('ch', 2))
    enc = meta.get('inEnc', '?')
    decl_bps = ENC_BYTES.get(enc, 0)
    win, rms = pick_window(cap)
    det = detect_bps(cap, ch, start=win)
    if det is None:
        reasons.append('帧几何检测失败')
        return finish(result)
    m_bps, m_de, m_lr = det
    d_st = fmt_stats(cap, decl_bps, ch, start=win) if decl_bps else None
    if d_st:
        d_de = sum(d_st[0]) / len(d_st[0])
        d_lr = d_st[1]
    else:
        d_de, d_lr = m_de, m_lr
    print('   几何: 声明 %dB(de=%.3f LR=%.3f) | 最优假设 %dB(de=%.3f) | 窗口RMS=%.0f' % (
        decl_bps, d_de, d_lr, m_bps, m_de, rms))
    # 判定原则：帧错位 bug 的特征 = 声明几何下数据呈噪声（de>1 / LR≈0）。
    # 平滑/高 LR 相关音频在 2B/4B 两假设下皆平滑，此时以声明为准，不因"最优假设"误判。
    quiet = rms < 100  # 16bit 标尺，近乎静音的窗口不可判
    if decl_bps and not quiet:
        declared_noise = d_de > 1.0 or (ch == 2 and abs(d_lr) < 0.1)
        if declared_noise and m_bps != decl_bps:
            reasons.append('声明帧长与数据几何不符（inEnc=%s 声明 %dB 呈噪声 de=%.3f，实测 %dB，帧错位=噪声）'
                           % (enc, decl_bps, d_de, m_bps))
        elif declared_noise:
            reasons.append('in 流疑似噪声（de=%.3f LR=%.3f）' % (d_de, d_lr))
        elif m_bps != decl_bps and m_de < 0.6:
            print('   （注: 另一假设 %dB 也平滑（de=%.3f），高相关音频两假设皆可，以声明为准）'
                  % (m_bps, m_de))

    # 4d) bit-perfect 比对 或 降级健康检查
    if resample == False and dither == False and lg['sink'] == 'usb_uac':
        vr = verify_stream(cap, out)
        if vr['bad'] < 0:
            reasons.append('bit-perfect 比对失败：%s' % vr['msg'])
        else:
            print('   比对: 插入=%dB(underrun静音) 真失真=%dB first=%s 截断=%dB' % (
                vr['ins'], vr['bad'], vr['first'], vr['truncated']))
            if vr['bad'] != 0:
                reasons.append('bit-perfect 失败：真失真 %dB（允许插入不允许替换）' % vr['bad'])
            if vr['truncated'] > len(cap) // 10:
                reasons.append('out 截断 %dB（%d%%）' % (vr['truncated'], 100 * vr['truncated'] // len(cap)))
            result['bitperfect'] = (vr['bad'] == 0 and vr['truncated'] == 0)
    else:
        # 降级轮：只要求出流健康（体量比 ≈ wire/in × 帧长比）
        ratio = out_bytes / float(in_bytes) if in_bytes else 0
        print('   降级轮（预期）: out/in 体量比=%.3f（重采样+升位后应略>1）' % ratio)
        if ratio < 0.8 or ratio > 3.0:
            reasons.append('降级出流体量异常 ratio=%.3f' % ratio)
        result['bitperfect'] = None  # 预期非 bit-perfect

    if not reasons:
        result['verdict'] = 'PASS'
    return finish(result)


def finish(result):
    print('   ▶ %s%s' % (result['verdict'],
                         '（bit-perfect）' if result.get('bitperfect') else ''))
    for r in result['reasons']:
        print('     ✗ %s' % r)
    return result


# ----------------------------------------------------------------------------
# analyze-only：离线分析已拉取的采集（调试用）
# ----------------------------------------------------------------------------

def analyze_only(dest_dir, tag):
    meta = {}
    mp = os.path.join(dest_dir, '%s_meta.txt' % tag)
    if os.path.exists(mp):
        for kv in open(mp, encoding='utf-8', errors='replace').read().replace('\n', ' ').split():
            if '=' in kv:
                k, v = kv.split('=', 1)
                meta[k] = v
    ip = os.path.join(dest_dir, '%s_in.pcm' % tag)
    op = os.path.join(dest_dir, '%s_out.pcm' % tag)
    cap = open(ip, 'rb').read()
    out = open(op, 'rb').read()
    ch = int(meta.get('ch', 2))
    print('meta:', meta)
    print('detect:', detect_bps(cap, ch))
    print('verify:', verify_stream(cap, out))


# ----------------------------------------------------------------------------
# 主流程：多 DAC 轮换
# ----------------------------------------------------------------------------

def device_id(adb):
    """从共享偏好里拿 caps_<VID>_<PID> 键（App 记录过的 DAC 身份）。"""
    try:
        xml = adb.shell('run-as %s cat shared_prefs/usb_audio_exclusive.xml' % APP)
        ids = re.findall(r'name="caps_(\d+)_(\d+)"', xml)
        return ids[-1] if ids else ('?', '?')
    except Exception:
        return ('?', '?')


def main():
    ap = argparse.ArgumentParser(description='FeiNiuMusic USB 独占无损压测（多 DAC 轮换）')
    ap.add_argument('--serial', default=None, help='adb 序列号（默认取第一台）')
    ap.add_argument('--adb', default=r'D:\android-sdk\platform-tools\adb.exe')
    ap.add_argument('--rounds', type=int, default=3, help='每个 DAC 的轮数（默认 3）')
    ap.add_argument('--secs', type=int, default=25, help='每轮播放秒数（默认 25）')
    ap.add_argument('--songs', default=DEFAULT_SONGS, help='逗号分隔的歌名（默认 %s）' % DEFAULT_SONGS)
    ap.add_argument('--analyze-only', action='store_true', help='只分析本地已拉取的采集文件')
    ap.add_argument('--tag', default='r1', help='analyze-only 用的文件 tag')
    args = ap.parse_args()

    if args.analyze_only:
        analyze_only(WORKDIR, args.tag)
        return 0

    songs = [s.strip() for s in args.songs.split(',') if s.strip()]
    serial = args.serial or pick_serial(args.adb)
    if not serial:
        print('✗ 没有在线的 adb 设备（先连手机）')
        return 2
    adb = Adb(serial, args.adb)
    keep_awake(adb)  # 测试期间防熄屏
    print('设备: %s | 每 DAC %d 轮 × %ds | 曲目: %s' % (serial, args.rounds, args.secs, ' / '.join(songs)))

    report_path = os.path.join(WORKDIR, 'dac_stress_report.txt')
    report = open(report_path, 'a', encoding='utf-8')
    report.write('\n==== %s serial=%s ====\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), serial))

    dev_no = 0
    all_pass = True
    while True:
        dev_no += 1
        vid, pid = device_id(adb)
        print('\n╔══════ DAC #%d  VID:PID = %s:%s ══════╗' % (dev_no, vid, pid))
        report.write('\n-- DAC #%d VID:PID=%s:%s --\n' % (dev_no, vid, pid))
        results = []
        for r in range(1, args.rounds + 1):
            title = songs[(r - 1) % len(songs)]
            res = run_round(adb, title, r, args.secs, WORKDIR, keep=True)
            results.append(res)
            all_pass = all_pass and res['verdict'] == 'PASS'
            report.write('round %d %s: %s %s\n' % (
                r, title, res['verdict'], '; '.join(res['reasons'])))
            report.flush()
            time.sleep(2)

        npass = sum(1 for x in results if x['verdict'] == 'PASS')
        print('\n══ DAC #%d(%s:%s) 汇总: %d/%d PASS ══' % (dev_no, vid, pid, npass, len(results)))
        for x in results:
            mark = '✔' if x['verdict'] == 'PASS' else '✗'
            bp = {True: ' [bit-perfect]', False: ' [bit-perfect失败]', None: ''}[x.get('bitperfect')]
            print('  %s 第%d轮 %s%s %s' % (mark, x['round'], x['song'], bp,
                                         ('；'.join(x['reasons']) if x['reasons'] else '')))

        ans = ''
        try:
            ans = input('\n换下一个 DAC 插好后按回车继续，输入 q 退出: ').strip().lower()
        except EOFError:
            ans = 'q'  # 无人值守运行：没有 stdin 就测完当前设备收工
        if ans == 'q':
            break
        print('等待 USB 重新枚举…')
        time.sleep(4)
        accept_usb_dialog(adb)

    report.close()
    print('\n总判定: %s（报告: %s）' % ('全部 PASS ✔' if all_pass else '存在 FAIL ✗', report_path))
    return 0 if all_pass else 1


if __name__ == '__main__':
    sys.exit(main())
