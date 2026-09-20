#!/usr/bin/env python3
"""
GH3x2x 终端仪表盘：把板子上所有能拿到的数据实时显示在一个屏幕上，方便和 WHOOP 等设备逐项核对。

    tools/.venv/bin/python tools/dashboard.py                      # 连 GH-XIAO（XIAO 固件，自带配置，只监听）
    tools/.venv/bin/python tools/dashboard.py --name GHealth --ini …/HRV_HR_SPO2_NADT_ADT_V4100_EVK.ini --func HR,SPO2,HRV
    tools/.venv/bin/python tools/dashboard.py --plain              # 不用全屏，每秒打印一行（可重定向）

显示：连接/包率/丢帧、心率（汇顶算法 + 置信度 + 1 分钟趋势）、血氧（含 R 值/等级/无效标记）、
HRV（RMSSD，按置信度筛过的 RR 间期，与 iPhone App 同一套规则）、呼吸率（文献流程 RIFV/RIAV/RIIV + Smart Fusion，
与 App 的 RespiratoryRate.swift 同一实现）、佩戴（硬件 ADT + 活体 NADT）、运动（帧里的 ACC）、PPG 原始值/AGC/波形、
会话统计（RHR、心率 min/max）。每秒一行摘要写到 csv（带墙钟时间，方便对 WHOOP 的时间轴）。
按 q 退出，r 重置会话统计。
"""
import argparse
import asyncio
import collections
import csv
import curses
import datetime as dt
import importlib.util
import math
import os
import signal
import statistics
import sys
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("evk_ble", os.path.join(HERE, "evk_ble.py"))
E = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(E)

DEFAULT_INI = os.path.join(HERE, "..", "GH3x2x", "3. 软件设计", "GH3X2X_V41xx版本算法驱动以及移植文档",
                           "功能配置工具以及配置指南", "V4100参考配置", "HRV_HR_SPO2_NADT_ADT_V4100_EVK.ini")
FS = 25.0
BARS = "▁▂▃▄▅▆▇█"


def cut(s, width):
    """按显示宽度截断（中文占 2 格）。"""
    out, w = [], 0
    for ch in s:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > width:
            break
        out.append(ch)
        w += cw
    return "".join(out)


# ----------------------------------------------------------------------------- 呼吸率（与 ios RespiratoryRate.swift 逐行对应）
class Biquad:
    __slots__ = ("b0", "b1", "b2", "a1", "a2")

    def __init__(self, b0, b1, b2, a1, a2):
        self.b0, self.b1, self.b2, self.a1, self.a2 = b0, b1, b2, a1, a2


def butter2(fc, fs, low):
    w = math.tan(math.pi * fc / fs)
    k = w * w
    s2 = math.sqrt(2) * w
    a0 = 1 + s2 + k
    a1, a2 = (2 * k - 2) / a0, (1 - s2 + k) / a0
    if low:
        return Biquad(k / a0, 2 * k / a0, k / a0, a1, a2)
    return Biquad(1 / a0, -2 / a0, 1 / a0, a1, a2)


def biquad_run(f, x):
    y = [0.0] * len(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        o = f.b0 * v + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        y[i] = o
    return y


def filtfilt(f, x, pad):
    if len(x) <= 3:
        return list(x)
    p = min(pad, len(x) - 1)
    xe = [2 * x[0] - x[i] for i in range(p, 0, -1)] + list(x) + [2 * x[-1] - x[-1 - i] for i in range(1, p + 1)]
    y = biquad_run(f, xe)
    y = biquad_run(f, y[::-1])[::-1]
    return y[p:p + len(x)]


def bandpass(x, low, high, fs):
    pad = int(fs * 5)
    hp = filtfilt(butter2(low, fs, False), x, pad)
    return filtfilt(butter2(high, fs, True), hp, pad)


def find_peaks(p, refractory):
    out = []
    for i in range(1, len(p) - 1):
        if p[i] > p[i - 1] and p[i] >= p[i + 1] and p[i] > 0:
            if out and i - out[-1] < refractory:
                if p[i] > p[out[-1]]:
                    out[-1] = i
            else:
                out.append(i)
    return out


def refine_peak(p, i):
    if i <= 0 or i >= len(p) - 1:
        return float(i)
    y0, y1, y2 = p[i - 1], p[i], p[i + 1]
    den = y0 - 2 * y1 + y2
    if den == 0:
        return float(i)
    return i + max(-0.5, min(0.5, (y0 - y2) / (2 * den)))


def resample(t, v, t0, t1, fs):
    out = []
    j = 0
    x = t0
    while x < t1:
        while j + 1 < len(t) - 1 and t[j + 1] < x:
            j += 1
        a, b = t[j], t[min(j + 1, len(t) - 1)]
        va, vb = v[j], v[min(j + 1, len(v) - 1)]
        out.append(va + (vb - va) * max(0.0, min(1.0, (x - a) / (b - a))) if b > a else va)
        x += 1 / fs
    return out


def count_orig(y, fs):
    """Schäfer & Kratky count-orig：只数上升幅度超过 0.2×Q3 的局部极大值，取它们的平均间隔。"""
    if len(y) <= 8:
        return None
    m = sum(y) / len(y)
    z = [v - m for v in y]
    maxima = [i for i in range(1, len(z) - 1) if z[i] > z[i - 1] and z[i] >= z[i + 1]]
    minima = [i for i in range(1, len(z) - 1) if z[i] < z[i - 1] and z[i] <= z[i + 1]]
    if len(maxima) < 2 or not minima:
        return None
    rises = []
    k = 0
    for i in maxima:
        while k + 1 < len(minima) and minima[k + 1] < i:
            k += 1
        rises.append(z[i] - z[minima[k]] if minima[k] < i else 0.0)
    s = sorted(rises)
    q3 = s[min(len(s) - 1, int(len(s) * 0.75))]
    good = [i for i, r in zip(maxima, rises) if r > 0.2 * q3]
    if len(good) < 2:
        return None
    spacing = (good[-1] - good[0]) / (len(good) - 1) / fs
    return 60 / spacing if spacing > 0 else None


def respiratory_estimate(ppg, fs=FS, window=32.0):
    """返回 dict(rpm, rifv, riav, riiv, spread, beats) 或 None（三路不一致 / 心跳不规则 / 数据不够）。"""
    n = int(window * fs)
    margin = int(fs * 4)
    if len(ppg) < n + margin:
        return None
    x = list(ppg)[-(n + margin):]
    pulse = bandpass(x, 0.5, 5.0, fs)
    pk = find_peaks(pulse, int(0.5 * fs))
    if len(pk) < 6:
        return None
    d = sorted(pk[i + 1] - pk[i] for i in range(len(pk) - 1))
    pk = find_peaks(pulse, int(0.6 * d[len(d) // 2]))
    if len(pk) < 8:
        return None
    tb, riav, riiv = [], [], []
    for i in range(1, len(pk)):
        a, b = pk[i - 1], pk[i]
        tr = min(range(a, b), key=lambda j: pulse[j])
        tb.append(refine_peak(pulse, b) / fs)
        riav.append(pulse[b] - pulse[tr])
        lo, hi = max(0, tr - 2), min(len(x) - 1, tr + 2)
        riiv.append(sum(x[lo:hi + 1]) / 5)
    rifv = [tb[i] - tb[i - 1] for i in range(1, len(tb))]
    tfv = tb[1:]
    t0, t1 = (len(x) - n) / fs, len(x) / fs
    in_win = [i for i in range(len(tfv)) if t0 <= tfv[i] < t1]
    if len(in_win) < int(window / 2.2):
        return None
    ib = [rifv[i] for i in in_win]
    mean = sum(ib) / len(ib)
    cv = math.sqrt(sum((v - mean) ** 2 for v in ib) / len(ib)) / mean
    if cv > 0.2 or not (0.35 < mean < 2.0):
        return None
    fs4 = 4.0

    def rate(t, v):
        sel = [i for i in range(len(t)) if t0 - 2 <= t[i] < t1]
        if len(sel) < 6:
            return None
        y = resample([t[i] for i in sel], [v[i] for i in sel], t0, t1, fs4)
        return count_orig(bandpass(y, 0.1, 0.6, fs4), fs4)

    ef, ea, ei = rate(tfv, rifv), rate(tb, riav), rate(tb, riiv)
    if ef is None or ea is None or abs(ef - ea) > 4:
        return None
    members = [ef, ea]
    if ei is not None and abs(ei - (ef + ea) / 2) <= 4:
        members.append(ei)
    m = sum(members) / len(members)
    sd = math.sqrt(sum((v - m) ** 2 for v in members) / len(members))
    if not (6 <= m <= 36):
        return None
    return dict(rpm=m, rifv=ef, riav=ea, riiv=ei, spread=sd, beats=len(in_win))


# ----------------------------------------------------------------------------- 会话状态
SPO2_FLAGS = {0: "运动", 1: "朝向", 2: "调光中", 3: "R无效"}


class Session:
    HRV_MIN_CONF = 60
    HRV_MIN_BEATS = 30

    def __init__(self):
        self.vnow = None            # 回放时的虚拟时钟；None = 用墙钟
        self.reset()
        self.versions = {}
        self.name = ""
        self.battery = None
        self.pkts = 0
        self.crc_err = 0
        self.pkt_times = collections.deque(maxlen=400)
        self.frame_times = collections.deque(maxlen=2000)

    def now(self):
        return self.vnow if self.vnow is not None else time.time()

    def reset(self):
        self.t0 = self.now()
        self.frames = collections.Counter()
        self.last_fid = {}
        self.lost = 0
        self.events = collections.deque(maxlen=8)
        # HR
        self.hr = None
        self.hr_conf = 0
        self.hr_at = 0.0
        self.hr_hist = collections.deque(maxlen=120)      # (t, bpm) 1 Hz
        self.hr_min = None
        self.hr_max = None
        self.rhr = None
        self.rhr_win = collections.deque()
        self.last_hr_hist_at = 0.0
        # SpO2
        self.spo2 = None
        self.spo2_r = None
        self.spo2_conf = 0
        self.spo2_level = 0
        self.spo2_flags = 0
        self.spo2_at = 0.0
        # HRV
        self.hrv = None
        self.hrv_conf = 0
        self.rri = collections.deque()                     # (t, seq, ms)
        self.rri_seq = 0
        self.last_rri_out = None
        self.hrv_seen = self.hrv_acc = self.hrv_rej = 0
        # RESP
        self.resp = None
        self.resp_hist = collections.deque()               # (t, rpm)
        self.resp_detail = ""
        self.last_resp_at = 0.0
        self.ppg_mean = collections.deque(maxlen=int(FS * 60))
        # wear / living
        self.hw_wear = None
        self.soft_wear = None
        self.living_conf = None
        # motion
        self.acc = collections.deque(maxlen=int(FS * 10))  # (t, |a| in g)
        self.acc_last = None
        self.acc_src_func = None
        self.acc_last_at = 0.0
        self.motion = "unknown"
        self.motion_mg = 0.0
        self.last_motion_at = 0.0
        # PPG
        self.raw = {}
        self.agc = {}
        self.wave = collections.deque(maxlen=int(FS * 6))
        self.wave_ch0 = collections.deque(maxlen=int(FS * 6))

    # ---- helpers
    def elapsed(self):
        return self.now() - self.t0

    def note(self, s):
        self.events.append((self.now(), s))

    def rate(self, dq, span):
        now = self.now()
        return sum(1 for x in dq if now - x <= span) / span

    # ---- ingest
    def on_event(self, irq):
        names = [E.IRQ_BITS.get(b, str(b)) for b in range(16) if irq >> b & 1]
        self.note("事件 " + ",".join(names))
        if irq & (1 << 10):
            self.hw_wear = "on"
        if irq & (1 << 11):
            self.hw_wear = "off"

    def on_frame(self, fname, f):
        now = self.now()
        self.frames[fname] += 1
        self.frame_times.append(now)
        fid = f["frame_id"]
        if fname in self.last_fid:
            gap = (fid - self.last_fid[fname]) & 0xFF
            if gap > 1:
                self.lost += gap - 1
        self.last_fid[fname] = fid
        self._ingest_acc(fname, f, now)
        res = {k & 0x7F: v for k, v in f["results"].items() if k & 0x80}
        if f["raw"] is not None:
            self.raw[fname] = f["raw"]
            self.agc[fname] = [a if isinstance(a, str) else E.decode_agc(a) for a in (f.get("agc") or [])]
        if fname == "HR":
            if f["raw"]:
                self.wave_ch0.append(f["raw"][0])
                self.ppg_mean.append(sum(f["raw"]) / len(f["raw"]))
            if res and res.get(0, 0) > 0:
                self.hr, self.hr_conf, self.hr_at = int(res[0]), int(res.get(1, 0)), now
                self._record_hr(now)
        elif fname == "SPO2":
            if res:
                self.spo2_r = res.get(1, 0) / 10000
                self.spo2_conf, self.spo2_level, self.spo2_flags = int(res.get(2, 0)), int(res.get(3, 0)), int(res.get(5, 0))
                if res.get(0, 0) > 0:
                    self.spo2, self.spo2_at = int(res[0]), now
        elif fname == "HRV":
            if res and res.get(5, 0) > 0:
                self._ingest_hrv(res, now)
        elif fname in ("SOFT_ADT_GREEN", "SOFT_ADT_IR"):
            if res and 0 in res:
                s = int(res[0]) & 3
                self.soft_wear = {1: "on", 2: "off", 3: "non-living"}.get(s, self.soft_wear)
                if 1 in res:
                    self.living_conf = int(res[1])
        self._periodic(now)

    def _ingest_acc(self, fname, f, now):
        g = f.get("gs")
        if not g or not any(g):
            return
        if self.acc_src_func is None or (fname != self.acc_src_func and now - self.acc_last_at > 3):
            self.acc_src_func = fname
        if fname != self.acc_src_func:
            return
        self.acc_last_at = now
        self.acc_last = tuple(v / 512 for v in g)
        self.acc.append((now, math.sqrt(sum(v * v for v in self.acc_last))))
        if now - self.last_motion_at >= 0.5:
            self.last_motion_at = now
            recent = [m for t, m in self.acc if now - t <= 2]
            if len(recent) >= 10:
                mu = sum(recent) / len(recent)
                self.motion_mg = math.sqrt(sum((v - mu) ** 2 for v in recent) / len(recent)) * 1000
                self.motion = "still" if self.motion_mg < 20 else ("light" if self.motion_mg < 70 else "active")

    def _record_hr(self, now):
        if now - self.last_hr_hist_at >= 1:
            self.last_hr_hist_at = now
            self.hr_hist.append((now, self.hr))
        self.hr_min = self.hr if self.hr_min is None else min(self.hr_min, self.hr)
        self.hr_max = self.hr if self.hr_max is None else max(self.hr_max, self.hr)
        if self.hr_conf >= 50 and self.motion != "active":
            self.rhr_win.append((now, self.hr))
            while self.rhr_win and now - self.rhr_win[0][0] > 60:
                self.rhr_win.popleft()
            if len(self.rhr_win) >= 30 and now - self.rhr_win[0][0] >= 45:
                avg = round(sum(v for _, v in self.rhr_win) / len(self.rhr_win))
                self.rhr = avg if self.rhr is None else min(self.rhr, avg)

    def _ingest_hrv(self, res, now):
        # 与 App 一致：置信度 ≥60、去掉重复的上一条、300~2000 ms、±20 % 中位数、5 分钟窗口 ≥30 个、只对相邻心跳配对
        count = int(res.get(5, 0))
        conf = int(res.get(4, 0))
        self.hrv_conf = conf
        vals = [int(res[i]) for i in range(min(count, 4)) if res.get(i, 0) > 0]
        if not vals or vals == self.last_rri_out:
            return
        self.last_rri_out = vals
        self.hrv_seen += len(vals)
        if conf < self.HRV_MIN_CONF or self.motion == "active":
            self.hrv_rej += len(vals)
            self.rri_seq += len(vals)
        else:
            for v in vals:
                self.rri_seq += 1
                if not 300 <= v <= 2000:
                    self.hrv_rej += 1
                    continue
                recent = sorted(ms for _, _, ms in list(self.rri)[-20:])
                if len(recent) >= 5:
                    med = recent[len(recent) // 2]
                    if abs(v - med) / med > 0.2:
                        self.hrv_rej += 1
                        continue
                self.rri.append((now, self.rri_seq, float(v)))
        while self.rri and now - self.rri[0][0] > 300:
            self.rri.popleft()
        self.hrv_acc = len(self.rri)
        if len(self.rri) >= self.HRV_MIN_BEATS:
            acc, n = 0.0, 0
            r = list(self.rri)
            for i in range(1, len(r)):
                if r[i][1] == r[i - 1][1] + 1:
                    d = r[i][2] - r[i - 1][2]
                    acc += d * d
                    n += 1
            if n >= 10:
                self.hrv = math.sqrt(acc / n)

    def _periodic(self, now):
        if now - self.last_resp_at < 5:
            return
        self.last_resp_at = now
        while self.resp_hist and now - self.resp_hist[0][0] > 60:
            self.resp_hist.popleft()
        contact = (max(self.raw.get("HR", [0])) if self.raw.get("HR") else 0) > (1 << 23) + 300_000
        e = respiratory_estimate(self.ppg_mean) if (self.motion != "active" and contact) else None
        if e:
            self.resp_hist.append((now, e["rpm"]))
            f = lambda v: "--" if v is None else f"{v:.1f}"
            self.resp_detail = f"RIFV {f(e['rifv'])} RIAV {f(e['riav'])} RIIV {f(e['riiv'])} 离散 {e['spread']:.1f} ({e['beats']} 拍)"
        elif not self.resp_hist or now - self.resp_hist[-1][0] > 20:
            self.resp_detail = "在动" if self.motion == "active" else ("无接触" if not contact else "三路不一致/心跳不规则")
        if len(self.resp_hist) >= 2:
            self.resp = statistics.median(v for _, v in self.resp_hist)
        else:
            self.resp = None
        # 波形：绿光 ch0 去趋势
        w = list(self.wave_ch0)
        if len(w) > 30:
            k = 12
            self.wave = collections.deque((w[i] - sum(w[max(0, i - k):i + k + 1]) / len(w[max(0, i - k):i + k + 1]) for i in range(len(w))), maxlen=int(FS * 6))

    # ---- derived text
    def wear_text(self):
        if self.soft_wear == "non-living":
            return "非活体"
        if self.soft_wear == "off" or self.hw_wear == "off":
            return "未佩戴"
        if self.hw_wear == "on" or self.soft_wear == "on":
            return "已佩戴"
        return "未知"

    def stale(self, at, limit):
        return at and self.now() - at > limit


def spark(values, width):
    vals = list(values)[-width:]
    if len(vals) < 2:
        return ""
    lo, hi = min(vals), max(vals)
    if hi - lo < 1e-9:
        return BARS[3] * len(vals)
    return "".join(BARS[min(7, int((v - lo) / (hi - lo) * 7.999))] for v in vals)


# ----------------------------------------------------------------------------- 画面
def render_lines(s: Session, width):
    now = s.now()
    el = int(s.elapsed())
    lines = []

    def add(txt=""):
        lines.append(cut(txt, width - 1))

    conn = f"{s.name or '?'}  {dt.datetime.fromtimestamp(now).strftime('%H:%M:%S')}  会话 {el // 3600:02d}:{el % 3600 // 60:02d}:{el % 60:02d}"
    stats = f"包 {s.rate(s.pkt_times, 5):4.1f}/s  帧 {s.rate(s.frame_times, 5):5.1f}/s  帧号缺口 {s.lost}  CRC错 {s.crc_err}"
    if s.battery:
        stats += f"  电池 {s.battery.hex()}"
    add(f" {conn}   {stats}")
    add(" " + "─" * (width - 2))

    hr = "--" if s.hr is None else str(s.hr)
    stale = "  (已 %.0fs 无更新)" % (now - s.hr_at) if s.stale(s.hr_at, 5) else ""
    add(f"  心率      {hr:>4} bpm   置信 {s.hr_conf:3d}   min {s.hr_min or '--'}  max {s.hr_max or '--'}  静息(60s最低均值) {s.rhr or '--'}{stale}")
    add(f"  1 分钟趋势 {spark((v for _, v in s.hr_hist), width - 14)}")
    add()
    sp = "--" if s.spo2 is None else f"{s.spo2}"
    flags = " ".join(n for b, n in SPO2_FLAGS.items() if s.spo2_flags >> b & 1) or "无"
    r = "--" if s.spo2_r is None else f"{s.spo2_r:.3f}"
    add(f"  血氧      {sp:>4} %     置信 {s.spo2_conf:3d}   等级 {s.spo2_level:2d}   R {r}   无效标记: {flags}")
    add()
    hrv = "--" if s.hrv is None else f"{s.hrv:.0f}"
    add(f"  HRV       {hrv:>4} ms    RMSSD/5min  传感器置信 {s.hrv_conf:3d}  已收 {s.hrv_acc}/{s.HRV_MIN_BEATS}  累计 {s.hrv_seen}  拒绝 {s.hrv_rej}")
    resp = "--" if s.resp is None else f"{s.resp:.1f}"
    add(f"  呼吸率    {resp:>4} /min  窗口 {len(s.resp_hist)}/2  {s.resp_detail}")
    add()
    src = []
    if s.hw_wear:
        src.append(f"硬件ADT {s.hw_wear}")
    if s.soft_wear:
        src.append(f"活体 {s.soft_wear}" + (f" 置信 {s.living_conf}" if s.living_conf is not None else ""))
    add(f"  佩戴      {s.wear_text():<6}  {'  '.join(src)}")
    acc = "--" if not s.acc_last else "%.2f %.2f %.2f g" % s.acc_last
    add(f"  运动      {s.motion:<7} {s.motion_mg:5.1f} mg   ACC {acc}   {'(帧内 ACC, 25 Hz)' if s.acc_last else '(无 ACC)'}")
    add(" " + "─" * (width - 2))
    raw = s.raw.get("HR")
    if raw:
        add(f"  绿光 raw  {'  '.join(f'{v:>9d}' for v in raw)}   AGC {'  '.join(s.agc.get('HR', []))}")
    for fn in ("SPO2",):
        if s.raw.get(fn):
            add(f"  {fn:<9} {'  '.join(f'{v:>9d}' for v in s.raw[fn])}   AGC {'  '.join(s.agc.get(fn, []))}")
    add(f"  波形 6s   {spark(s.wave, width - 14)}")
    add(f"  帧数      " + "  ".join(f"{k} {v}" for k, v in sorted(s.frames.items())))
    if s.versions:
        add("  版本      " + "  ".join(f"{k} {v}" for k, v in s.versions.items()))
    add(" " + "─" * (width - 2))
    for t, msg in list(s.events)[-6:]:
        add(f"  {dt.datetime.fromtimestamp(t).strftime('%H:%M:%S')}  {msg}")
    return lines


class Curses:
    def __init__(self):
        self.scr = curses.initscr()
        curses.noecho()
        curses.cbreak()
        curses.curs_set(0)
        self.scr.nodelay(True)
        self.scr.keypad(True)

    def draw(self, lines, footer):
        h, w = self.scr.getmaxyx()
        self.scr.erase()
        for i, l in enumerate(lines[:h - 2]):
            try:
                self.scr.addstr(i, 0, cut(l, w - 1))
            except curses.error:
                pass
        try:
            self.scr.addstr(h - 1, 0, cut(footer, w - 1), curses.A_REVERSE)
        except curses.error:
            pass
        self.scr.refresh()

    def key(self):
        try:
            return self.scr.getch()
        except curses.error:
            return -1

    def close(self):
        curses.nocbreak()
        self.scr.keypad(False)
        curses.echo()
        curses.endwin()


# ----------------------------------------------------------------------------- 主流程
def summary_row(s: Session):
    now = dt.datetime.fromtimestamp(s.now())
    return [now.strftime("%Y-%m-%d %H:%M:%S"), f"{s.elapsed():.1f}", s.hr or "", s.hr_conf, s.spo2 or "", s.spo2_conf,
            s.spo2_level, "" if s.spo2_r is None else f"{s.spo2_r:.4f}", s.spo2_flags,
            "" if s.hrv is None else f"{s.hrv:.1f}", s.hrv_conf, s.hrv_acc,
            "" if s.resp is None else f"{s.resp:.1f}", len(s.resp_hist),
            s.wear_text(), s.motion, f"{s.motion_mg:.1f}",
            "" if not s.acc_last else " ".join(f"{v:.3f}" for v in s.acc_last),
            " ".join(str(v) for v in s.raw.get("HR", [])), " ".join(s.agc.get("HR", [])),
            s.rhr or "", s.lost]


RAW_HEADER = ["t", "func", "frame_id", "raw0", "raw1", "raw2", "raw3", "gsx", "gsy", "gsz", "agc",
              "res0", "res1", "res2", "res3", "res4", "res5"]


def raw_row(t, fname, f):
    raw = list(f["raw"] or []) + [""] * 4
    gs = f.get("gs") or ("", "", "")
    res = {k & 0x7F: v for k, v in f["results"].items() if k & 0x80}
    return [f"{t:.3f}", fname, f["frame_id"], *raw[:4], *gs,
            " ".join(a if isinstance(a, str) else E.decode_agc(a) for a in (f.get("agc") or []))] + [res.get(i, "") for i in range(6)]


def replay_frames(path):
    """读取 --raw-csv / resp_capture 格式的 csv，逐帧产出 (t, fname, frame)。"""
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            raw = [int(float(r[f"raw{i}"])) for i in range(4) if r.get(f"raw{i}")]
            gs = tuple(int(float(r[k])) for k in ("gsx", "gsy", "gsz")) if r.get("gsx") not in (None, "") else None
            results = {0x80 | i: int(float(r[f"res{i}"])) for i in range(6) if r.get(f"res{i}") not in (None, "")}
            f = dict(frame_id=int(r["frame_id"]), raw=raw or None, gs=gs, agc=r["agc"].split() if r.get("agc") else [],
                     results=results)
            yield float(r["t"]), r["func"], f


SUMMARY_HEADER = ["time", "elapsed_s", "hr_bpm", "hr_conf", "spo2_pct", "spo2_conf", "spo2_level", "spo2_r", "spo2_flags",
                  "hrv_rmssd_ms", "hrv_conf", "hrv_rri_in_window", "resp_rpm", "resp_windows", "wear", "motion", "motion_mg",
                  "acc_g", "ppg_green_raw", "agc", "rhr", "lost_frames"]


async def replay(args):
    s = Session()
    s.name = f"回放 {os.path.basename(args.replay)}"
    csv_path = args.csv if args.csv is not None else ""
    csv_f = open(csv_path, "w", newline="") if csv_path else None
    writer = csv.writer(csv_f) if csv_f else None
    if writer:
        writer.writerow(SUMMARY_HEADER)
    ui = None if args.plain else Curses()
    s.reset()
    s.note(f"回放 {args.replay}  速度 x{args.speed or '∞'}")
    t_start = time.time()
    s.vnow = t_start
    s.t0 = t_start
    next_draw = 0
    next_csv = 0
    last_pkt_t = None
    try:
        for t, fname, f in replay_frames(args.replay):
            if args.speed:
                delay = t / args.speed - (time.time() - t_start)
                if delay > 0:
                    await asyncio.sleep(delay)
            s.vnow = t_start + t                # 虚拟时钟：所有窗口/节拍都按录音时间走
            if last_pkt_t != t:
                s.pkt_times.append(s.vnow)
                last_pkt_t = t
            s.on_frame(fname, f)
            if writer and t >= next_csv:
                next_csv = t + 1
                writer.writerow(summary_row(s))
            if ui:
                k = ui.key()
                if k in (ord("q"), ord("Q")):
                    break
                if time.time() >= next_draw:
                    next_draw = time.time() + 0.25
                    h, w = ui.scr.getmaxyx()
                    ui.draw(render_lines(s, w), f" 回放  q 退出   csv: {csv_path or '关闭'}")
            elif t >= next_draw:
                next_draw = t + 1
                r = summary_row(s)
                print(f"[{r[1]:>7}s] HR {r[2] or '--'} ({r[3]})  SpO2 {r[4] or '--'}% ({r[5]})  HRV {r[9] or '--'} ms  "
                      f"呼吸 {r[12] or '--'}  {r[14]}  {r[15]} {r[16]}mg", flush=True)
    finally:
        if ui:
            ui.close()
        if csv_f:
            csv_f.close()
    print(f"回放结束：{sum(s.frames.values())} 帧，丢帧 {s.lost}" + (f"，摘要已存 {csv_path}" if csv_path else ""))


async def run(args):
    if args.replay:
        await replay(args)
        return
    funcs = [x.strip().upper() for x in args.func.split(",") if x.strip()]
    if not args.listen:
        drv, algo, funcs_in_cfg = E.parse_ini(args.ini)
        if not drv:
            sys.exit("ini 里没找到 [drvregister-table]")
        all_mask = E.func_mask(funcs_in_cfg) if funcs_in_cfg else E.func_mask(funcs)
        start_mask = E.func_mask(funcs)
    dev = await E.find_device(args.name, args.address, args.scan_time)
    s = Session()
    s.name = dev.name or args.name
    stop = asyncio.Event()
    loop = asyncio.get_event_loop()
    loop.add_signal_handler(signal.SIGINT, stop.set)
    loop.add_signal_handler(signal.SIGTERM, stop.set)

    csv_path = args.csv
    if csv_path is None:
        os.makedirs(os.path.join(HERE, "..", "data"), exist_ok=True)
        csv_path = os.path.join(HERE, "..", "data", f"dashboard_{dt.datetime.now().strftime('%Y%m%d_%H%M%S')}.csv")
    csv_f = open(csv_path, "w", newline="") if csv_path else None
    writer = csv.writer(csv_f) if csv_f else None
    if writer:
        writer.writerow(SUMMARY_HEADER)
    raw_f = open(args.raw_csv, "w", newline="") if args.raw_csv else None
    raw_w = csv.writer(raw_f) if raw_f else None
    if raw_w:
        raw_w.writerow(RAW_HEADER)

    async with E.BleakClient(dev, timeout=15.0) as client:
        evk = E.Evk(client)
        await evk.start(verbose=False)
        await asyncio.sleep(0.3)
        for t, label in ((0x01, "固件"), (0x10, "驱动"), (0x11, "芯片"), (0x13, "算法")):
            p = await evk.send(E.CMD_GET_VER, bytes([t]))
            if p and len(p) > 2:
                s.versions[label] = p[2:2 + p[1]].decode("ascii", "replace").split("\n")[0][:40]
        if not args.listen:
            p = await evk.send(E.CMD_WORK_MODE, bytes([0x00]) + all_mask.to_bytes(4, "little"))
            if not p or p[0] != 0:
                sys.exit("设置工作模式失败")
            await evk.send(E.CMD_CHIP_CTRL, bytes([0x5A]))
            await asyncio.sleep(0.3)
            for name, regs in (("驱动", drv), ("算法", algo)):
                for k in range(0, len(regs), 56):
                    part = regs[k:k + 56]
                    payload = b"".join(a.to_bytes(2, "big") + v.to_bytes(2, "big") for a, v in part)
                    p = await evk.send(E.CMD_LOAD_REG_LIST, payload, timeout=3.0)
                    if not p or p[0] != 0:
                        sys.exit(f"{name}配置下发失败")
            p = await evk.send(E.CMD_START_CTRL, bytes([0x00, 0x00, 0x00]) + start_mask.to_bytes(4, "little"))
            if not p or p[0] != 0:
                sys.exit("启动失败")
        s.reset()
        s.note("已连接" + ("，监听模式" if args.listen else "，已下发配置并启动 " + "+".join(funcs)))
        decoder = E.RawdataDecoder()
        ui = None if args.plain else Curses()
        next_draw = 0
        next_csv = time.time() + 1
        try:
            while not stop.is_set():
                if args.seconds and s.elapsed() >= args.seconds:
                    break
                try:
                    rcmd, rp, ok = await asyncio.wait_for(evk.q.get(), 0.05)
                except asyncio.TimeoutError:
                    rcmd = None
                if rcmd is not None:
                    if not ok:
                        s.crc_err += 1
                    elif rcmd == E.CMD_EVENT_REPORT and len(rp) >= 3:
                        await client.write_gatt_char(evk.rx, E.build(E.CMD_EVENT_REPORT, bytes([rp[2]])), response=False)
                        s.on_event((rp[0] << 8) | rp[1])
                    elif rcmd == E.CMD_NEW_RAWDATA:
                        s.pkts += 1
                        s.pkt_times.append(time.time())
                        try:
                            func_id, chn, mask, frames = decoder.parse(rp)
                        except Exception as ex:
                            s.note(f"解析失败 {ex}")
                            continue
                        fname = E.FUNC_NAMES.get(func_id, str(func_id))
                        for f in frames:
                            s.on_frame(fname, f)
                            if raw_w:
                                raw_w.writerow(raw_row(s.elapsed(), fname, f))
                    elif rcmd == E.CMD_CURRENT_BAT:
                        s.battery = rp
                now = time.time()
                if writer and now >= next_csv:
                    next_csv = now + 1
                    writer.writerow(summary_row(s))
                    csv_f.flush()
                if ui:
                    k = ui.key()
                    if k in (ord("q"), ord("Q")):
                        break
                    if k in (ord("r"), ord("R")):
                        s.reset()
                        s.note("会话统计已重置")
                    if now >= next_draw:
                        next_draw = now + 0.25
                        h, w = ui.scr.getmaxyx()
                        ui.draw(render_lines(s, w), f" q 退出  r 重置会话   csv: {csv_path or '关闭'}")
                elif now >= next_draw:
                    next_draw = now + 1
                    r = summary_row(s)
                    print(f"[{r[0]}] HR {r[2] or '--'} ({r[3]})  SpO2 {r[4] or '--'}% ({r[5]})  HRV {r[9] or '--'} ms  "
                          f"呼吸 {r[12] or '--'}  {r[14]}  {r[15]} {r[16]}mg", flush=True)
        finally:
            if ui:
                ui.close()
            loop.remove_signal_handler(signal.SIGINT)
            if not args.listen:
                try:
                    await asyncio.wait_for(
                        evk.send(E.CMD_START_CTRL, bytes([0x01, 0x00, 0x00]) + start_mask.to_bytes(4, "little"), timeout=2.0),
                        timeout=4.0)
                except Exception:
                    pass
            if csv_f:
                csv_f.close()
            if raw_f:
                raw_f.close()
    print(f"已停止。{s.pkts} 包 / {sum(s.frames.values())} 帧，丢帧 {s.lost}" + (f"，每秒摘要已存 {csv_path}" if csv_path else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", default="GH-XIAO", help="按名字子串找设备（默认 GH-XIAO；EVK 用 --name GHealth）")
    ap.add_argument("--address", default="", help="按地址直连（macOS 是 CoreBluetooth UUID）")
    ap.add_argument("--listen", action=argparse.BooleanOptionalAction, default=None,
                    help="只监听不下发配置（GH-XIAO 默认开；EVK 默认关）")
    ap.add_argument("--ini", default=DEFAULT_INI, help="EVK 路线：GHTestTool 配置 ini")
    ap.add_argument("--func", default="HR,SPO2,HRV", help="EVK 路线：要开启的功能")
    ap.add_argument("--csv", default=None, help="每秒摘要 csv 路径（默认 data/dashboard_<时间>.csv；空字符串关闭）")
    ap.add_argument("--seconds", type=float, default=0, help="运行秒数，0 = 直到 q / Ctrl-C")
    ap.add_argument("--plain", action="store_true", help="不用全屏，每秒打印一行")
    ap.add_argument("--raw-csv", default="", help="同时把每一帧原始数据存到这个 csv（可用 --replay 回放）")
    ap.add_argument("--replay", default="", help="不连蓝牙，回放 --raw-csv / resp_capture 格式的 csv")
    ap.add_argument("--speed", type=float, default=1.0, help="回放速度倍数，0 = 最快")
    ap.add_argument("--scan-time", type=float, default=10.0)
    args = ap.parse_args()
    if args.listen is None:
        args.listen = "XIAO" in args.name.upper()
    if args.csv == "":
        args.csv = ""
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
