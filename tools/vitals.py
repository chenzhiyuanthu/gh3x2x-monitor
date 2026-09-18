#!/usr/bin/env python3
"""
GH3x2x EVK 实时心率 / 血氧 命令行监测（macOS 蓝牙直连，不需要 Windows 工具）

用法:
  tools/.venv/bin/python tools/vitals.py                 # 默认 HR+SPO2，直到 Ctrl-C
  tools/.venv/bin/python tools/vitals.py --seconds 60 --csv data/vitals.csv
  tools/.venv/bin/python tools/vitals.py --func ADT,HR,SPO2   # 同时开佩戴检测
  tools/.venv/bin/python tools/vitals.py --plain          # 不刷屏，按行打印（适合重定向到文件）

戴法: 模组光窗贴在手腕内侧/外侧皮肤上，松紧适中；或者手指轻放在光窗上不要用力压。
      出值需要 8~15 秒稳定信号；血氧要更久一点。
"""
import argparse
import math
import asyncio
import os
import signal
import sys
import time
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evk_ble as E  # noqa: E402

DEFAULT_INI = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "GH3x2x", "3. 软件设计", "GH3X2X_V41xx版本算法驱动以及移植文档", "功能配置工具以及配置指南",
    "V4100参考配置", "HR_SPO2_NADT_ADT_V4100_EVK.ini")

BARS = "▁▂▃▄▅▆▇█"
FULL_SCALE = 1 << 23


def spark(values, width=48):
    vals = list(values)[-width:]
    if len(vals) < 2:
        return ""
    lo, hi = min(vals), max(vals)
    if hi - lo < 1:
        return "▁" * len(vals)
    return "".join(BARS[min(7, int((v - lo) / (hi - lo) * 7.999))] for v in vals)


def fmt_num(n):
    return f"{n:,}" if isinstance(n, int) else str(n)


def estimate_bpm(samples, fs=25.0):
    """从最近 ~10s 的原始 PPG 直接估脉率：去趋势 + DFT 找 0.6~3Hz 主峰。返回 (bpm, 质量0~1, 峰峰值) 或 None。"""
    x = list(samples)[-int(fs * 10):]
    n = len(x)
    if n < int(fs * 5):
        return None
    w = 20
    ma = [sum(x[max(0, i - w):i + w + 1]) / len(x[max(0, i - w):i + w + 1]) for i in range(n)]
    ac = [a - b for a, b in zip(x, ma)]
    ac = [(ac[i - 1] + ac[i] + ac[i + 1]) / 3 for i in range(1, n - 1)]
    m = sum(ac) / len(ac)
    s = [v - m for v in ac]
    energy = sum(v * v for v in s)
    if energy < 1:
        return None
    best_f, best_p = 0.0, 0.0
    total = 0.0
    N = len(s)
    for f100 in range(60, 301, 2):  # 0.60 .. 3.00 Hz, 步进 0.02 Hz
        f = f100 / 100
        re = im = 0.0
        for k in range(N):
            ang = 2 * math.pi * f * k / fs
            re += s[k] * math.cos(ang)
            im -= s[k] * math.sin(ang)
        p = re * re + im * im
        total += p
        if p > best_p:
            best_f, best_p = f, p
    quality = best_p / total * 8 if total else 0  # 主峰占比，粗略归一
    return round(best_f * 60), min(1.0, quality), max(s) - min(s)


class Vitals:
    def __init__(self):
        self.t0 = time.time()
        self.hr = None          # (bpm, conf, snr, t)
        self.spo2 = None        # (pct, r, conf, level, invalid, t)
        self.wear = "未知"
        self.wear_t = 0
        self.nadt = None        # (state, conf, quality, t)
        self.raw = {}           # func -> list
        self.agc = {}           # func -> list
        self.wave = {"HR": deque(maxlen=400), "SPO2": deque(maxlen=400)}
        self.est = None          # (bpm, quality, pp) 从原始波形估算
        self.est_t = 0
        self.frames = {}        # func -> count
        self.last_fid = {}      # func -> last frame id
        self.lost = 0
        self.pkts = 0
        self.crc_err = 0
        self.events = deque(maxlen=6)
        self.battery = None

    def elapsed(self):
        return time.time() - self.t0

    def note(self, s):
        self.events.append(f"{self.elapsed():6.1f}s {s}")

    def on_frame(self, fname, f):
        self.frames[fname] = self.frames.get(fname, 0) + 1
        fid = f["frame_id"]
        if fname in self.last_fid:
            gap = (fid - self.last_fid[fname]) & 0xFF
            if gap > 1:
                self.lost += gap - 1
        self.last_fid[fname] = fid
        if f["raw"] is not None:
            self.raw[fname] = f["raw"]
            if fname in self.wave and f["raw"]:
                self.wave[fname].append(f["raw"][0])
        if f.get("agc") is not None:
            self.agc[fname] = f["agc"]
        res = {k & 0x7F: v for k, v in f["results"].items() if k & 0x80}
        if not res:
            return
        t = self.elapsed()
        if fname == "HR":
            self.hr = (res.get(0), res.get(1), res.get(2), t)
        elif fname == "SPO2":
            self.spo2 = (res.get(0), res.get(1), res.get(2), res.get(3), res.get(5), t)
        elif fname in ("SOFT_ADT_GREEN", "SOFT_ADT_IR"):
            st = res.get(0, 0)
            self.nadt = ({0: "默认", 1: "佩戴", 2: "脱落", 3: "非活体"}.get(st & 3, str(st)), res.get(1), res.get(2), t)

    def on_event(self, irq):
        names = [E.IRQ_BITS.get(b, f"bit{b}") for b in range(16) if irq >> b & 1]
        if irq & (1 << 10):
            self.wear, self.wear_t = "已佩戴 (wear on)", self.elapsed()
        if irq & (1 << 11):
            self.wear, self.wear_t = "未佩戴 (wear off)", self.elapsed()
        interesting = [n for n in names if n not in ("fifo_full",)]
        if interesting:
            self.note("事件 " + ",".join(interesting))

    # ------------------------------------------------------------ 渲染
    def contact_hint(self, fname="HR"):
        r = self.raw.get(fname)
        if not r:
            return "等待数据…"
        v = max(r)
        if v < FULL_SCALE + 300000:
            return "光窗前没有皮肤/手指（rawdata≈2^23，几乎无反射光）"
        if v > 16_400_000:
            return "信号饱和，等待 AGC 调光…"
        return "有信号"

    def render(self, funcs):
        el = self.elapsed()
        lines = []
        lines.append(f" GH3x2x EVK 实时监测   运行 {int(el) // 60:02d}:{int(el) % 60:02d}   功能 {'+'.join(funcs)}   "
                     f"包 {self.pkts}  帧 {sum(self.frames.values())}  丢帧 {self.lost}  CRC错 {self.crc_err}")
        lines.append(" " + "─" * 100)
        # 原始波形独立估算（每秒算一次）
        if el - self.est_t > 1.0 and len(self.wave["HR"]) >= 125:
            self.est_t = el
            self.est = estimate_bpm(self.wave["HR"])
        est_txt = ""
        warn = ""
        if self.est:
            ebpm, q, pp = self.est
            if pp < 4000:
                est_txt = "   波形估算: 无明显脉搏波(交流分量太小，贴紧皮肤)"
                q = 0
            elif pp > 2_000_000:
                est_txt = "   波形估算: 信号还在稳定(AGC 调光中)"
                q = 0
            else:
                est_txt = f"   波形估算 {ebpm} bpm (主峰占比 {q:.2f})"
            if self.hr and self.hr[0] and q > 0.3:
                ratio = self.hr[0] / ebpm
                if ratio < 0.6 or ratio > 1.6:
                    warn = "  ⚠ 算法值与波形不符(可能锁到倍频/次谐波)，保持不动等 20s"
        # 心率
        if self.hr and self.hr[0] is not None:
            bpm, conf, snr, t = self.hr
            age = el - t
            stale = "  (已 %.0fs 未更新)" % age if age > 3 else ""
            bar = "█" * (conf // 5 if conf is not None else 0)
            lines.append(f" 心率  {bpm:>4} bpm   置信度 {conf:>3}/100 {bar:<20}{est_txt}{stale}{warn}")
        else:
            lines.append(f" 心率  ----  bpm   (算法需要 ~10s 稳定信号)   {self.contact_hint('HR')}{est_txt}")
        # 血氧
        if self.spo2 and self.spo2[0] is not None:
            pct, r, conf, level, inv, t = self.spo2
            age = el - t
            stale = "  (已 %.0fs 未更新)" % age if age > 3 else ""
            flags = []
            if inv:
                if inv & 1: flags.append("运动")
                if inv & 2: flags.append("朝向")
                if inv & 4: flags.append("调光")
                if inv & 8: flags.append("R值无效")
            bar = "█" * (conf // 5 if conf is not None else 0)
            lines.append(f" 血氧  {pct:>4} %     置信度 {conf if conf is not None else '-':>3}/100 {bar:<20} 等级 {level}  R={r/10000 if r is not None else '-':.3f}"
                         f"{'  异常:' + '/'.join(flags) if flags else ''}{stale}")
        else:
            lines.append(f" 血氧  ----  %     (算法需要 ~15s 稳定信号)   {self.contact_hint('SPO2') if 'SPO2' in funcs else '未开启'}")
        # 佩戴
        w = self.wear
        if self.nadt:
            w += f"   活体: {self.nadt[0]} 置信 {self.nadt[1]} 佩戴质量 {self.nadt[2]}"
        lines.append(f" 佩戴  {w}")
        lines.append(" " + "─" * 100)
        # 波形 & 原始数据
        for fname, label in (("HR", "绿光"), ("SPO2", "红/红外")):
            if fname not in funcs:
                continue
            r = self.raw.get(fname)
            a = self.agc.get(fname)
            if r is None:
                lines.append(f" {label:<6} 等待数据…")
                continue
            ac = ""
            if len(self.wave[fname]) > 25:
                w25 = list(self.wave[fname])[-50:]
                ac = f" 峰峰值 {max(w25) - min(w25):,}"
            lines.append(f" {label:<6} ch0 {spark(self.wave[fname])}{ac}")
            lines.append(f"        raw {' '.join(f'{v:>10,}' for v in r)}")
            if a:
                lines.append(f"        agc {' '.join(f'{E.decode_agc(v):>10}' for v in a)}")
        lines.append(" " + "─" * 100)
        for ev in self.events:
            lines.append(" " + ev)
        lines.append(" Ctrl-C 停止")
        return lines


class Screen:
    def __init__(self, plain):
        self.plain = plain
        self.n = 0
        self.last_plain = None

    def draw(self, lines, vit: Vitals):
        if self.plain:
            key = (vit.hr, vit.spo2, vit.wear, vit.est[0] if vit.est else None)
            if key != self.last_plain:
                self.last_plain = key
                hr = f"HR {vit.hr[0]} bpm(置信 {vit.hr[1]})" if vit.hr else "HR ----"
                sp = f"SpO2 {vit.spo2[0]}%(置信 {vit.spo2[2]})" if vit.spo2 else "SpO2 ----"
                es = f"波形估算 {vit.est[0]} bpm(q={vit.est[1]:.2f})" if vit.est else "波形估算 ----"
                print(f"[{vit.elapsed():6.1f}s] {hr}  {sp}  {es}  {vit.wear}", flush=True)
            return
        out = ""
        if self.n:
            out += f"\x1b[{self.n}F"  # 光标上移 n 行到块首
        for ln in lines:
            out += "\x1b[2K" + ln + "\n"
        # 如果本次行数比上次少，清掉多余行
        for _ in range(max(0, self.n - len(lines))):
            out += "\x1b[2K\n"
        if self.n > len(lines):
            out += f"\x1b[{self.n - len(lines)}F"
        self.n = len(lines)
        sys.stdout.write(out)
        sys.stdout.flush()


async def run(args):
    drv, algo, funcs_in_cfg = E.parse_ini(args.ini)
    if not drv:
        sys.exit("ini 里没找到 [drvregister-table]")
    funcs = [x.strip().upper() for x in args.func.split(",") if x.strip()]
    for f in funcs:
        if funcs_in_cfg and f not in funcs_in_cfg:
            sys.exit(f"功能 {f} 不在配置 {os.path.basename(args.ini)} 里（配置包含: {funcs_in_cfg}）")
    all_mask = E.func_mask(funcs_in_cfg) if funcs_in_cfg else E.func_mask(funcs)
    start_mask = E.func_mask(funcs)

    dev = await E.find_device(args.name, args.address, args.scan_time)
    vit = Vitals()
    scr = Screen(args.plain)
    stop = asyncio.Event()
    loop = asyncio.get_event_loop()
    loop.add_signal_handler(signal.SIGINT, stop.set)
    loop.add_signal_handler(signal.SIGTERM, stop.set)

    csv = open(args.csv, "w") if args.csv else None
    if csv:
        csv.write("t,func,frame_id,ch,rawdata,agc,hr_bpm,hr_conf,spo2_pct,spo2_conf\n")

    async with E.BleakClient(dev, timeout=15.0) as client:
        evk = E.Evk(client)
        await evk.start(verbose=False)
        await asyncio.sleep(0.3)
        if args.listen:
            print(f"已连接 {dev.name}，监听模式（设备自带配置并自行采样，不下发配置）")
            for t in (0x10, 0x11):
                await evk.send(E.CMD_GET_VER, bytes([t]))
        else:
            print(f"已连接 {dev.name}，下发配置 {os.path.basename(args.ini)} …")
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
        # 清掉下发过程的日志，开始刷屏
        if not args.plain:
            sys.stdout.write("\x1b[2J\x1b[H")
        vit.t0 = time.time()
        vit.note(f"已启动 {'+'.join(funcs)}")
        decoder = E.RawdataDecoder()
        next_draw = 0
        try:
            while not stop.is_set():
                if args.seconds and vit.elapsed() >= args.seconds:
                    break
                try:
                    rcmd, rp, ok = await asyncio.wait_for(evk.q.get(), 0.1)
                except asyncio.TimeoutError:
                    rcmd = None
                if rcmd is not None:
                    if not ok:
                        vit.crc_err += 1
                    elif rcmd == E.CMD_EVENT_REPORT and len(rp) >= 3:
                        await client.write_gatt_char(evk.rx, E.build(E.CMD_EVENT_REPORT, bytes([rp[2]])), response=False)
                        vit.on_event((rp[0] << 8) | rp[1])
                    elif rcmd == E.CMD_NEW_RAWDATA:
                        vit.pkts += 1
                        try:
                            func_id, chn, mask, frames = decoder.parse(rp)
                        except Exception as ex:
                            vit.note(f"解析失败 {ex}")
                            continue
                        fname = E.FUNC_NAMES.get(func_id, str(func_id))
                        for f in frames:
                            vit.on_frame(fname, f)
                            if csv and f["raw"] is not None:
                                hr = vit.hr or (None, None)
                                sp = vit.spo2 or (None, None, None)
                                for c, w in enumerate(f["raw"]):
                                    a = (f.get("agc") or [None] * chn)[c]
                                    csv.write(f"{vit.elapsed():.3f},{fname},{f['frame_id']},{c},{w},{E.decode_agc(a)},"
                                              f"{hr[0] if hr[0] is not None else ''},{hr[1] if hr[1] is not None else ''},"
                                              f"{sp[0] if sp[0] is not None else ''},{sp[2] if sp[2] is not None else ''}\n")
                    elif rcmd == E.CMD_CURRENT_BAT:
                        vit.battery = rp
                now = time.time()
                if now >= next_draw:
                    next_draw = now + 0.15
                    scr.draw(vit.render(funcs), vit)
        finally:
            loop.remove_signal_handler(signal.SIGINT)
            if not args.listen:
                try:
                    await asyncio.wait_for(
                        evk.send(E.CMD_START_CTRL, bytes([0x01, 0x00, 0x00]) + start_mask.to_bytes(4, "little"), timeout=2.0),
                        timeout=4.0)
                except Exception:
                    pass
            if csv:
                csv.close()
    print(f"\n已停止。共 {vit.pkts} 包 / {sum(vit.frames.values())} 帧，丢帧 {vit.lost}" + (f"，数据已存 {args.csv}" if args.csv else ""))
    if vit.hr:
        print(f"最后心率 {vit.hr[0]} bpm (置信 {vit.hr[1]})", end="")
    if vit.spo2:
        print(f"，最后血氧 {vit.spo2[0]}% (置信 {vit.spo2[2]})", end="")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ini", default=DEFAULT_INI, help="GHTestTool 配置 ini（默认 EVK 公版 HR_SPO2_NADT_ADT）")
    ap.add_argument("--func", default="HR,SPO2", help="要开启的功能，逗号分隔（默认 HR,SPO2；可加 ADT / SOFT_ADT_GREEN）")
    ap.add_argument("--seconds", type=float, default=0, help="运行秒数，0 = 直到 Ctrl-C")
    ap.add_argument("--csv", default="", help="把每帧数据和算法结果存到 csv")
    ap.add_argument("--plain", action="store_true", help="不刷屏，只在数值变化时打印一行")
    ap.add_argument("--name", default="GHealth", help="按名字子串找设备（XIAO 固件用 --name GH-XIAO --listen）")
    ap.add_argument("--listen", action="store_true", help="不下发配置/不启动，只接收（GH-XIAO 固件自带配置并自启动）")
    ap.add_argument("--address", default="", help="按地址直连（macOS 是 CoreBluetooth UUID）")
    ap.add_argument("--scan-time", type=float, default=10.0)
    args = ap.parse_args()
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
