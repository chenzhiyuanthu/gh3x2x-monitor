#!/usr/bin/env python3
"""
Goodix GH3x2x EVK — 在 macOS 上用自带蓝牙直接和 EVK 主板对话的小工具。

依赖: tools/.venv (bleak)。用法:
  tools/.venv/bin/python tools/evk_ble.py scan                 # 扫描，列出 BLE 设备
  tools/.venv/bin/python tools/evk_ble.py info  [--name GHealth] # 连上后查版本 / 芯片连接状态 / 读 0x0036、0x0030、0x0032
  tools/.venv/bin/python tools/evk_ble.py reg   0x0036 [count]  # 读寄存器
  tools/.venv/bin/python tools/evk_ble.py raw   19 01           # 发任意命令(十六进制: cmd payload...)，打印回包

协议(《GH3x2x 工程介绍_20221117.pdf》第 6 章 / demo gh_uprotocol.c):
  帧 = AA 11 <cmd> <len> <payload...> <crc8>
  crc8: poly 0x07, init 0xFF, 覆盖从 0xAA 到 payload 末尾的所有字节。
BLE profile(驱动库移植指南 7.1.4):
  Service 0000190e-0000-1000-8000-00805f9b34fb
  TX(设备->手机, notify) 00000003-0000-1000-8000-00805f9b34fb
  RX(手机->设备, write)  00000004-0000-1000-8000-00805f9b34fb
"""
import argparse
import asyncio
import sys

from bleak import BleakClient, BleakScanner

SVC_UUID = "0000190e-0000-1000-8000-00805f9b34fb"
TX_UUID = "00000003-0000-1000-8000-00805f9b34fb"  # notify: device -> host
RX_UUID = "00000004-0000-1000-8000-00805f9b34fb"  # write:  host -> device

CRC8_TAB = [
    0x00, 0x07, 0x0E, 0x09, 0x1C, 0x1B, 0x12, 0x15, 0x38, 0x3F, 0x36, 0x31, 0x24, 0x23, 0x2A, 0x2D,
    0x70, 0x77, 0x7E, 0x79, 0x6C, 0x6B, 0x62, 0x65, 0x48, 0x4F, 0x46, 0x41, 0x54, 0x53, 0x5A, 0x5D,
    0xE0, 0xE7, 0xEE, 0xE9, 0xFC, 0xFB, 0xF2, 0xF5, 0xD8, 0xDF, 0xD6, 0xD1, 0xC4, 0xC3, 0xCA, 0xCD,
    0x90, 0x97, 0x9E, 0x99, 0x8C, 0x8B, 0x82, 0x85, 0xA8, 0xAF, 0xA6, 0xA1, 0xB4, 0xB3, 0xBA, 0xBD,
    0xC7, 0xC0, 0xC9, 0xCE, 0xDB, 0xDC, 0xD5, 0xD2, 0xFF, 0xF8, 0xF1, 0xF6, 0xE3, 0xE4, 0xED, 0xEA,
    0xB7, 0xB0, 0xB9, 0xBE, 0xAB, 0xAC, 0xA5, 0xA2, 0x8F, 0x88, 0x81, 0x86, 0x93, 0x94, 0x9D, 0x9A,
    0x27, 0x20, 0x29, 0x2E, 0x3B, 0x3C, 0x35, 0x32, 0x1F, 0x18, 0x11, 0x16, 0x03, 0x04, 0x0D, 0x0A,
    0x57, 0x50, 0x59, 0x5E, 0x4B, 0x4C, 0x45, 0x42, 0x6F, 0x68, 0x61, 0x66, 0x73, 0x74, 0x7D, 0x7A,
    0x89, 0x8E, 0x87, 0x80, 0x95, 0x92, 0x9B, 0x9C, 0xB1, 0xB6, 0xBF, 0xB8, 0xAD, 0xAA, 0xA3, 0xA4,
    0xF9, 0xFE, 0xF7, 0xF0, 0xE5, 0xE2, 0xEB, 0xEC, 0xC1, 0xC6, 0xCF, 0xC8, 0xDD, 0xDA, 0xD3, 0xD4,
    0x69, 0x6E, 0x67, 0x60, 0x75, 0x72, 0x7B, 0x7C, 0x51, 0x56, 0x5F, 0x58, 0x4D, 0x4A, 0x43, 0x44,
    0x19, 0x1E, 0x17, 0x10, 0x05, 0x02, 0x0B, 0x0C, 0x21, 0x26, 0x2F, 0x28, 0x3D, 0x3A, 0x33, 0x34,
    0x4E, 0x49, 0x40, 0x47, 0x52, 0x55, 0x5C, 0x5B, 0x76, 0x71, 0x78, 0x7F, 0x6A, 0x6D, 0x64, 0x63,
    0x3E, 0x39, 0x30, 0x37, 0x22, 0x25, 0x2C, 0x2B, 0x06, 0x01, 0x08, 0x0F, 0x1A, 0x1D, 0x14, 0x13,
    0xAE, 0xA9, 0xA0, 0xA7, 0xB2, 0xB5, 0xBC, 0xBB, 0x96, 0x91, 0x98, 0x9F, 0x8A, 0x8D, 0x84, 0x83,
    0xDE, 0xD9, 0xD0, 0xD7, 0xC2, 0xC5, 0xCC, 0xCB, 0xE6, 0xE1, 0xE8, 0xEF, 0xFA, 0xFD, 0xF4, 0xF3,
]

CMD_REG_RW = 0x03
CMD_RAWDATA = 0x08
CMD_NEW_RAWDATA = 0x0B
CMD_START_CTRL = 0x0C
CMD_CURRENT_BAT = 0x0D
CMD_WORK_MODE = 0x10
CMD_EVENT_REPORT = 0x16
CMD_CHIP_CTRL = 0x17
CMD_GET_VER = 0x19
CMD_CHIP_CONN = 0x1A
CMD_FUNC_INFO = 0x2C
CMD_GET_MAX_LEN = 0xA0
CMD_LOAD_REG_LIST = 0xA1

# 功能位 (gh_drv.h GH3X2X_FUNC_OFFSET_*)
FUNC_BITS = {
    "ADT": 0, "HR": 1, "HRV": 2, "HSM": 3, "FPBP": 4, "PWA": 5, "SPO2": 6, "ECG": 7,
    "PWTT": 8, "SOFT_ADT_GREEN": 9, "BT": 10, "RESP": 11, "AF": 12, "TEST1": 13,
    "TEST2": 14, "SOFT_ADT_IR": 15, "LEAD_DET": 19,
}
FUNC_NAMES = {v: k for k, v in FUNC_BITS.items()}

IRQ_BITS = {
    0: "com_ready", 1: "lead_on", 2: "lead_off", 3: "fastrecovery", 4: "adc_done", 5: "fifo_full",
    6: "fifo_ov", 8: "led_tune_fail", 9: "led_tune_done", 10: "wear_on", 11: "wear_off",
    12: "timeslot_timeout", 13: "sample_rate_err", 14: "rst_irq",
}

VER_TYPES = {
    0x01: "EVK 固件版本",
    0x0B: "虚拟寄存器版本",
    0x0C: "bootloader 版本",
    0x0D: "BLE 版本",
    0x0E: "协议版本",
    0x10: "驱动库版本",
    0x11: "芯片版本",
    0x13: "HR 算法版本",
    0x1A: "SPO2 算法版本",
    0x1B: "ECG 算法版本",
}

REG_NAMES = {
    0x0000: "system_ctrl",
    0x000A: "fifo_waterline",
    0x0030: "product_id_l (期望 0x0201)",
    0x0032: "product_id_h (期望 0x0301)",
    0x0034: "chip_id",
    0x0036: "chip_ready_code (期望 0xAA55)",
    0x0108: "slot_enable",
    0x0380: "spi/iic cfg",
    0x0500: "int_cr",
    0x0502: "int_cr2",
}


def crc8(data: bytes) -> int:
    c = 0xFF
    for b in data:
        c = CRC8_TAB[(c ^ b) & 0xFF]
    return c


def build(cmd: int, payload: bytes = b"") -> bytes:
    body = bytes([0xAA, 0x11, cmd & 0xFF, len(payload)]) + payload
    return body + bytes([crc8(body)])


class FrameParser:
    """把 notify 过来的字节流切成完整帧。"""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data: bytes):
        self.buf += data
        frames = []
        while True:
            i = self.buf.find(b"\xAA\x11")
            if i < 0:
                self.buf.clear()
                break
            if i:
                del self.buf[:i]
            if len(self.buf) < 5:
                break
            ln = self.buf[3]
            need = 4 + ln + 1
            if len(self.buf) < need:
                break
            frame = bytes(self.buf[:need])
            del self.buf[:need]
            ok = crc8(frame[:-1]) == frame[-1]
            frames.append((frame[2], frame[4:-1], ok))
        return frames


def hx(b: bytes) -> str:
    return " ".join(f"{x:02X}" for x in b)


async def scan(seconds: float):
    print(f"扫描 {seconds:.0f}s ...（第一次会弹出蓝牙权限请求，要允许）")
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    rows = []
    for dev, adv in found.values():
        rows.append((adv.rssi or -999, dev.name or adv.local_name or "", dev.address, list(adv.service_uuids or [])))
    rows.sort(reverse=True)
    for rssi, name, addr, uuids in rows:
        mark = "  <== 可能是 EVK" if ("ghealth" in name.lower() or "goodix" in name.lower() or SVC_UUID in uuids) else ""
        print(f"{rssi:5d} dBm  {name:24s} {addr}{mark}")
    if not rows:
        print("什么都没扫到：检查系统设置里终端的蓝牙权限、EVK 的 S5 是否拨到 BLE、LED1 是否在闪。")


async def find_device(name_sub: str, address: str, seconds: float):
    if address:
        dev = await BleakScanner.find_device_by_address(address, timeout=seconds)
    else:
        dev = await BleakScanner.find_device_by_filter(
            lambda d, adv: (name_sub.lower() in ((adv.local_name or "").lower() + "|" + (d.name or "").lower()))
            or (SVC_UUID in (adv.service_uuids or [])),
            timeout=seconds,
        )
    if dev is None:
        sys.exit(f"没找到设备（name 含 '{name_sub}' 或带 {SVC_UUID} 服务）。先跑 scan 看看。")
    print(f"连接 {dev.name} {dev.address} ...")
    return dev


class Evk:
    def __init__(self, client: BleakClient):
        self.client = client
        self.parser = FrameParser()
        self.q: asyncio.Queue = asyncio.Queue()
        self.tx = None
        self.rx = None

    def _on_notify(self, _handle, data: bytearray):
        for cmd, payload, ok in self.parser.feed(bytes(data)):
            self.q.put_nowait((cmd, payload, ok))

    async def start(self, verbose: bool):
        svcs = self.client.services
        for s in svcs:
            if verbose:
                print(f"service {s.uuid}  {s.description}")
            for c in s.characteristics:
                if verbose:
                    print(f"   char {c.uuid}  props={','.join(c.properties)}")
                if c.uuid.lower() == TX_UUID:
                    self.tx = c
                if c.uuid.lower() == RX_UUID:
                    self.rx = c
        if self.tx is None or self.rx is None:
            # 兜底：找任意一个 notify 和一个 write 特征
            for s in svcs:
                for c in s.characteristics:
                    if self.tx is None and "notify" in c.properties:
                        self.tx = c
                    if self.rx is None and ("write" in c.properties or "write-without-response" in c.properties):
                        self.rx = c
            print("警告：没有找到 Goodix 标准 UUID，退而使用:", self.tx and self.tx.uuid, self.rx and self.rx.uuid)
        await self.client.start_notify(self.tx, self._on_notify)

    async def send(self, cmd: int, payload: bytes = b"", timeout: float = 2.0, want: int = None):
        pkt = build(cmd, payload)
        print(f"-> {hx(pkt)}")
        resp = "write-without-response" not in self.rx.properties
        await self.client.write_gatt_char(self.rx, pkt, response=resp)
        want = cmd if want is None else want
        deadline = asyncio.get_event_loop().time() + timeout
        while True:
            remain = deadline - asyncio.get_event_loop().time()
            if remain <= 0:
                print("   (超时，没有回包)")
                return None
            try:
                rcmd, rpayload, ok = await asyncio.wait_for(self.q.get(), remain)
            except asyncio.TimeoutError:
                print("   (超时，没有回包)")
                return None
            tag = "" if ok else "  [CRC 错]"
            if rcmd == want:
                print(f"<- cmd=0x{rcmd:02X} len={len(rpayload)} payload={hx(rpayload)}{tag}")
                return rpayload
            if rcmd in (CMD_NEW_RAWDATA, CMD_RAWDATA, CMD_CURRENT_BAT):
                continue  # 采样数据/电量周期包，等待回包时不刷屏
            print(f"<- (其它) cmd=0x{rcmd:02X} len={len(rpayload)} payload={hx(rpayload[:24])}{tag}")

    async def get_ver(self, vtype: int):
        p = await self.send(CMD_GET_VER, bytes([vtype]))
        if p and len(p) >= 2:
            s = p[2:2 + p[1]].decode("ascii", "replace")
            print(f"   {VER_TYPES.get(vtype, f'type 0x{vtype:02X}')}: {s}")
            return s

    async def read_reg(self, addr: int, count: int = 1):
        p = await self.send(CMD_REG_RW, bytes([0x00, count, (addr >> 8) & 0xFF, addr & 0xFF]))
        vals = []
        if p and len(p) >= 4 + 2 * count:
            for i in range(count):
                v = (p[4 + 2 * i] << 8) | p[5 + 2 * i]
                vals.append(v)
                a = addr + 2 * i
                print(f"   reg 0x{a:04X} = 0x{v:04X}   {REG_NAMES.get(a, '')}")
        return vals

    async def chip_connected(self):
        p = await self.send(CMD_CHIP_CONN)
        if p:
            print("   GH3x2x 芯片连接状态:", "已连接" if p[0] == 0 else f"未连接 (0x{p[0]:02X})")


# ---------------------------------------------------------------- ini 配置解析
import base64
import json
import re
import zlib


def parse_ini(path: str):
    """返回 (drv_regs, algo_regs, functions)。regs 为 [(addr, val), ...]；functions 为配置里包含的功能名列表。"""
    txt = open(path, encoding="utf-8", errors="ignore").read()

    def section(name):
        m = re.search(r"^\[" + re.escape(name) + r"\]\s*$(.*?)(?=^\[|\Z)", txt, re.M | re.S)
        return m.group(1) if m else ""

    def regs_of(sec):
        pairs = re.findall(r"\{\s*0x([0-9A-Fa-f]{1,4})\s*,\s*0x([0-9A-Fa-f]{1,4})\s*\}", sec)
        return [(int(a, 16), int(v, 16)) for a, v in pairs]

    drv = regs_of(section("drvregister-table"))
    algo = regs_of(section("algoregister-table"))
    funcs = []
    m = re.search(r'^values="?([A-Za-z0-9+/=]+)"?$', section("diagram-parameter"), re.M)
    if m:
        raw = base64.b64decode(m.group(1))
        for cut in (0, 4):
            try:
                d = json.loads(zlib.decompress(raw[cut:]).decode("utf-8", "ignore"))
                fl = d.get("sFunctionList", [""])[0]
                funcs = [x.split(":")[0].strip() for x in fl.split(",") if x.strip()]
                break
            except Exception:
                continue
    return drv, algo, funcs


def func_mask(names):
    m = 0
    for n in names:
        n = n.strip().upper()
        if n not in FUNC_BITS:
            sys.exit(f"未知功能名 {n}，可选: {', '.join(FUNC_BITS)}")
        m |= 1 << FUNC_BITS[n]
    return m


# ---------------------------------------------------------------- rawdata 解析 (gh_uprotocol.c / gh_zip.c 的 0x0B 格式)
# 包头 8 字节: [func_id][dtype: b0 gs,b1 algo,b2 agc,b3 amb,b4 gyro,b5 cap,b6 temp][chnl mask 4B BE][pkg flag: b0 zip,b1 odd,b2 fifo-pkg-mode][data len]
# 帧: frame_id(1) [gs 6 BE int16] [gyro 6] [cap 12] [temp 12] rawdata agc [amb] result
#   非压缩 / 压缩奇数包首帧: rawdata = chn × [tag][d2 d1 d0]，agc = chn × GU32 小端 [gain|drv0mA|drv1mA|dc]
#   压缩差分帧: rawdata 块 [len][tag改变标志][tags…][nibble 流]，agc 块 [len][nibble 流]；块总长 = len+1
#     nibble 流每通道: 类型 T (T//2+1 个数据 nibble, 高位在前, T 奇数为负)，差分相对上一帧
#   result: [n][tag(1) val(4 LE)]*   tag 0/2/3/4 = flag，0x80|i = 算法结果 i
class RawdataDecoder:
    def __init__(self):
        self.last_raw = {}   # func_id -> [24bit]
        self.last_agc = {}   # func_id -> [GU32]

    @staticmethod
    def _diff_block(buf, chn, has_tagflag):
        L = buf[0]
        blk = buf[:L + 1]
        tags = None
        if has_tagflag:
            if blk[1]:
                tags = list(blk[2:2 + chn])
                nib = (2 + chn) * 2
            else:
                nib = 4
        else:
            nib = 2
        pos = [nib]

        def rd():
            b = blk[pos[0] // 2]
            v = (b >> 4) if pos[0] % 2 == 0 else (b & 0xF)
            pos[0] += 1
            return v

        diffs = []
        for _ in range(chn):
            t = rd()
            v = 0
            for _ in range(t // 2 + 1):
                v = (v << 4) | rd()
            diffs.append(-v if (t & 1) else v)
        return diffs, tags, L + 1

    def parse(self, p: bytes):
        """返回 (func_id, chn, mask, frames)。frames: dict(frame_id, gs, raw[], tag[], agc[], results{tag:val})"""
        func_id, dtype = p[0], p[1]
        mask = int.from_bytes(p[2:6], "big")
        pkg_flag, total = p[6], p[7]
        chn = bin(mask).count("1")
        gs, agc, amb, gyro, cap, temp = dtype & 1, (dtype >> 2) & 1, (dtype >> 3) & 1, (dtype >> 4) & 1, (dtype >> 5) & 1, (dtype >> 6) & 1
        zip_en, odd, fifo_pkg = pkg_flag & 1, (pkg_flag >> 1) & 1, (pkg_flag >> 2) & 1
        if (pkg_flag >> 3) & 0xF:
            raise ValueError("拆分大帧包(splic)暂不支持")
        body = p[8:8 + total]
        i = 0
        frames = []
        first = True
        while i < len(body):
            f = {"frame_id": body[i]}
            i += 1
            if gs:
                f["gs"] = tuple(int.from_bytes(body[i + 2 * k:i + 2 * k + 2], "big", signed=True) for k in range(3))
                i += 6
                if gyro:
                    i += 6
            if cap:
                i += 12
            if temp:
                i += 12
            absolute = (not zip_en) or (odd and first)
            if fifo_pkg:
                f["fifo_id"] = body[i]
                i += 1
                f["raw"], f["tag"] = [], []
            elif absolute:
                words = [body[i + 4 * k:i + 4 * k + 4] for k in range(chn)]
                i += 4 * chn
                f["raw"] = [int.from_bytes(w[1:4], "big") for w in words]
                f["tag"] = [w[0] for w in words]
                self.last_raw[func_id] = list(f["raw"])
            else:
                d, tags, used = self._diff_block(body[i:], chn, True)
                i += used
                last = self.last_raw.get(func_id)
                if last is None or len(last) != chn:
                    f["raw"] = None  # 还没收到绝对帧
                else:
                    f["raw"] = [a + b for a, b in zip(last, d)]
                    self.last_raw[func_id] = list(f["raw"])
                f["tag"] = tags
            if agc:
                if absolute or not zip_en:
                    f["agc"] = [int.from_bytes(body[i + 4 * k:i + 4 * k + 4], "little") for k in range(chn)]
                    i += 4 * chn
                    self.last_agc[func_id] = list(f["agc"])
                else:
                    d, _, used = self._diff_block(body[i:], chn, False)
                    i += used
                    last = self.last_agc.get(func_id)
                    f["agc"] = None if (last is None or len(last) != chn) else [a + b for a, b in zip(last, d)]
                    if f["agc"] is not None:
                        self.last_agc[func_id] = list(f["agc"])
            if amb:
                i += 3 * chn
            n = body[i]
            res = {}
            j = i + 1
            while j + 4 < i + 1 + n + 1 and j + 5 <= len(body):
                res[body[j]] = int.from_bytes(body[j + 1:j + 5], "little", signed=True)
                j += 5
            i += 1 + n
            f["results"] = res
            frames.append(f)
            first = False
        return func_id, chn, mask, frames


def decode_agc(v):
    # punFrameAgcInfo GU32: bit0-3 gain 档位, bit8-15 drv0 电流 mA, bit16-23 drv1 电流 mA, bit24-31 dc cancel
    if v is None:
        return "?"
    return f"g{v & 0xF}/{(v >> 8) & 0xFF}mA/{(v >> 16) & 0xFF}mA"


# ---------------------------------------------------------------- 启动采样
async def cmd_start(args):
    drv, algo, funcs_in_cfg = parse_ini(args.ini)
    if not drv:
        sys.exit("ini 里没找到 [drvregister-table]")
    want = [x.strip() for x in args.func.split(",") if x.strip()]
    print(f"配置: {args.ini}\n  驱动寄存器 {len(drv)} 个, 算法寄存器 {len(algo)} 个, 配置包含功能: {funcs_in_cfg or '未知'}")
    all_mask = func_mask(funcs_in_cfg) if funcs_in_cfg else func_mask(want)
    start_mask = func_mask(want)
    print(f"  work-mode 功能掩码 0x{all_mask:08X}, 启动功能 {want} -> 0x{start_mask:08X}")

    async def run(evk: Evk):
        # 1. 工作模式 = EVK
        p = await evk.send(CMD_WORK_MODE, bytes([0x00]) + all_mask.to_bytes(4, "little"))
        if not p or p[0] != 0:
            sys.exit("设置工作模式失败")
        # 2. 芯片硬复位（PC 工具下发配置前会复位）
        if not args.no_reset:
            p = await evk.send(CMD_CHIP_CTRL, bytes([0x5A]))
            await asyncio.sleep(0.3)
        # 3. 最大包长
        chunk_regs = 56
        p = await evk.send(CMD_GET_MAX_LEN)
        if p:
            maxlen = p[0]
            chunk_regs = max(1, min(chunk_regs, (maxlen - 5) // 4))
            print(f"   设备最大包长 {maxlen} -> 每包 {chunk_regs} 个寄存器")
        # 4. 下发寄存器表（大端 addr16,val16）
        for name, regs in (("驱动", drv), ("算法", algo)):
            for k in range(0, len(regs), chunk_regs):
                part = regs[k:k + chunk_regs]
                payload = b"".join(a.to_bytes(2, "big") + v.to_bytes(2, "big") for a, v in part)
                p = await evk.send(CMD_LOAD_REG_LIST, payload, timeout=3.0)
                if not p or p[0] != 0:
                    sys.exit(f"{name}配置第 {k // chunk_regs} 包下发失败")
            print(f"   {name}配置 {len(regs)} 个寄存器下发完成")
        # 5. 启动
        p = await evk.send(CMD_START_CTRL, bytes([0x00, 0x00, 0x00]) + start_mask.to_bytes(4, "little"))
        if not p or p[0] != 0:
            sys.exit("启动失败（功能不在配置里？）")
        print(f"=== 采样中 {args.seconds}s，把手指按在光窗上 ===")
        csv = open(args.csv, "w") if args.csv else None
        if csv:
            csv.write("t,func,frame_id,gs_x,gs_y,gs_z,ch,rawdata,agc,results\n")
        t0 = asyncio.get_event_loop().time()
        n_pkt = n_frame = 0
        first_dump = True
        decoder = RawdataDecoder()
        while asyncio.get_event_loop().time() - t0 < args.seconds:
            try:
                rcmd, rp, ok = await asyncio.wait_for(evk.q.get(), 1.0)
            except asyncio.TimeoutError:
                continue
            t = asyncio.get_event_loop().time() - t0
            if rcmd == CMD_EVENT_REPORT and len(rp) >= 3:
                irq = (rp[0] << 8) | rp[1]
                names = [IRQ_BITS.get(b, f"bit{b}") for b in range(16) if irq >> b & 1]
                print(f"[{t:6.2f}s] 事件 0x{irq:04X} {names}")
                await evk.client.write_gatt_char(evk.rx, build(CMD_EVENT_REPORT, bytes([rp[2]])), response=False)
            elif rcmd == CMD_NEW_RAWDATA:
                n_pkt += 1
                try:
                    func_id, chn, mask, frames = decoder.parse(rp)
                except Exception as e:
                    print(f"[{t:6.2f}s] 0x0B 解析失败({e}): {hx(rp[:48])} ...")
                    continue
                fname = FUNC_NAMES.get(func_id, func_id)
                if first_dump:
                    first_dump = False
                    print(f"[{t:6.2f}s] 首包: func={fname} 通道数={chn} 通道掩码=0x{mask:08X} 每包 {len(frames)} 帧 (payload {len(rp)} B, 压缩={rp[6] & 1})")
                for f in frames:
                    n_frame += 1
                    if f["raw"] is None:
                        continue
                    agcs = [decode_agc(a) for a in (f.get("agc") or [])]
                    gs = f.get("gs", ("", "", ""))
                    algo_res = {k & 0x7F: v for k, v in f["results"].items() if k & 0x80}
                    if csv:
                        for c, w in enumerate(f["raw"]):
                            csv.write(f"{t:.3f},{fname},{f['frame_id']},{gs[0]},{gs[1]},{gs[2]},{c},{w},{agcs[c] if c < len(agcs) else ''},\"{algo_res if algo_res else ''}\"\n")
                    if algo_res:
                        print(f"[{t:6.2f}s] {fname} 算法结果 {algo_res}   (HR: 0=bpm 1=置信度; SPO2: 0=% 2=置信度)")
                    if n_frame % args.print_every == 0:
                        print(f"[{t:6.2f}s] {fname} #{f['frame_id']:3d} gs={gs} raw={f['raw']} agc={agcs}")
            elif rcmd == CMD_RAWDATA:
                n_pkt += 1
                if first_dump:
                    first_dump = False
                    print(f"[{t:6.2f}s] 收到旧格式 0x08 rawdata: {hx(rp[:48])} ...")
            elif rcmd == CMD_FUNC_INFO:
                print(f"[{t:6.2f}s] 功能信息 0x2C: {hx(rp)}")
            elif rcmd == CMD_CURRENT_BAT:
                pass
            else:
                print(f"[{t:6.2f}s] cmd=0x{rcmd:02X} {hx(rp)}")
        await evk.send(CMD_START_CTRL, bytes([0x01, 0x00, 0x00]) + start_mask.to_bytes(4, "little"))
        if csv:
            csv.close()
        print(f"=== 结束: 收到 {n_pkt} 个数据包, {n_frame} 帧" + (f", 已存 {args.csv}" if args.csv else ""))

    await with_device(args, run)


async def with_device(args, fn):
    dev = await find_device(args.name, args.address, args.scan_time)
    async with BleakClient(dev, timeout=15.0) as client:
        print("已连接, MTU =", client.mtu_size)
        evk = Evk(client)
        await evk.start(verbose=args.verbose)
        await asyncio.sleep(0.3)
        await fn(evk)


async def cmd_info(args):
    async def run(evk: Evk):
        for t in (0x01, 0x0D, 0x0E, 0x10, 0x11):
            await evk.get_ver(t)
        await evk.chip_connected()
        await evk.read_reg(0x0036, 1)
        await evk.read_reg(0x0030, 2)
        await evk.read_reg(0x0000, 1)
    await with_device(args, run)


async def cmd_reg(args):
    async def run(evk: Evk):
        await evk.read_reg(int(args.addr, 0), args.count)
    await with_device(args, run)


async def cmd_raw(args):
    async def run(evk: Evk):
        b = bytes(int(x, 16) for x in args.hexbytes)
        await evk.send(b[0], b[1:], timeout=args.wait)
        # 再等一会，收零散回包
        end = asyncio.get_event_loop().time() + args.wait
        while asyncio.get_event_loop().time() < end:
            try:
                rcmd, rpayload, ok = await asyncio.wait_for(evk.q.get(), 0.2)
                print(f"<- cmd=0x{rcmd:02X} len={len(rpayload)} payload={hx(rpayload)}{'' if ok else '  [CRC 错]'}")
            except asyncio.TimeoutError:
                pass
    await with_device(args, run)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", default="GHealth", help="按名字子串找设备（默认 GHealth）")
    ap.add_argument("--address", default="", help="直接按地址/UUID 连接")
    ap.add_argument("--scan-time", type=float, default=8.0)
    ap.add_argument("-v", "--verbose", action="store_true", help="打印 GATT 服务列表")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    sub.add_parser("info")
    r = sub.add_parser("reg")
    r.add_argument("addr")
    r.add_argument("count", nargs="?", type=int, default=1)
    w = sub.add_parser("raw")
    w.add_argument("hexbytes", nargs="+", help="cmd payload... 十六进制字节")
    w.add_argument("--wait", type=float, default=2.0)
    s = sub.add_parser("start", help="下发 ini 配置并采样")
    s.add_argument("--ini", required=True, help="GHTestTool 的 .ini 配置文件")
    s.add_argument("--func", default="HR", help="要启动的功能，逗号分隔，如 HR 或 ADT,HR,SPO2")
    s.add_argument("--seconds", type=float, default=15.0)
    s.add_argument("--csv", default="", help="保存 rawdata 到 csv")
    s.add_argument("--print-every", type=int, default=25, help="每 N 帧打印一行")
    s.add_argument("--no-reset", action="store_true", help="下发配置前不做芯片硬复位")
    args = ap.parse_args()

    if args.cmd == "scan":
        asyncio.run(scan(args.scan_time))
    elif args.cmd == "info":
        asyncio.run(cmd_info(args))
    elif args.cmd == "reg":
        asyncio.run(cmd_reg(args))
    elif args.cmd == "raw":
        asyncio.run(cmd_raw(args))
    elif args.cmd == "start":
        asyncio.run(cmd_start(args))


if __name__ == "__main__":
    main()
