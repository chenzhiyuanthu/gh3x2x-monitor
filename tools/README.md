# tools/ — 在 Mac 上直接用蓝牙和 GH3x2x EVK 对话

## 全量仪表盘：`dashboard.py`（和 WHOOP 等设备逐项核对用这个）

```
tools/.venv/bin/python tools/dashboard.py                    # 连 GH-XIAO，全屏刷新；q 退出，r 重置会话统计
tools/.venv/bin/python tools/dashboard.py --plain            # 不全屏，每秒一行（可重定向）
tools/.venv/bin/python tools/dashboard.py --raw-csv data/raw_今天.csv   # 顺便把每一帧原始数据存下来
tools/.venv/bin/python tools/dashboard.py --replay data/raw_今天.csv --speed 5   # 回放（不连蓝牙）
tools/.venv/bin/python tools/dashboard.py --name GHealth --func HR,SPO2,HRV      # 原 EVK 路线：下发 ini 配置再采
```

一屏显示：连接/包率/帧号缺口、心率（汇顶算法 + 置信度 + 1 分钟趋势 + 会话 min/max + 静息心率）、血氧（% / 置信 / 等级 / R 值 / 无效标记位）、
HRV（RMSSD，和 iPhone App 同一套筛选：置信 ≥60、去重复、±20% 中位数、5 分钟窗口 ≥30 个）、呼吸率（RIFV/RIAV/RIIV + Smart Fusion，和 App 的
`RespiratoryRate.swift` 同一实现，能看到三路各自的值）、佩戴（硬件 ADT 事件 + 活体 NADT）、运动（帧里的 ACC，Still/Light/Active + mg）、
绿光 4 通道原始值 + AGC + 6 s 波形、事件日志。**每秒一行摘要自动存到 `data/dashboard_<日期时间>.csv`**（第一列是墙钟时间，
直接和 WHOOP 导出的时间轴对）；`--csv ""` 关闭。

注意：GH-XIAO 同时只能连一个设备，跑仪表盘前把 iPhone 上的 App 退掉。

## 实时心率 / 血氧监测：`vitals.py`（轻量版）


```
cd /Users/cmac/chenzhiyuanthu/test-GH3x2x
tools/.venv/bin/python tools/vitals.py                      # HR+SPO2，终端实时刷新，Ctrl-C 停止
tools/.venv/bin/python tools/vitals.py --csv data/今天.csv   # 顺便存每帧数据
tools/.venv/bin/python tools/vitals.py --func ADT,HR,SPO2   # 再开硬件佩戴检测（会报 wear on/off 事件）
tools/.venv/bin/python tools/vitals.py --plain              # 不刷屏，数值变化时打印一行（重定向/记录用）
tools/.venv/bin/python tools/vitals.py --seconds 60         # 跑 60 秒自动停
```

界面：心率 bpm + 置信度条、血氧 % + R 值/异常标记、佩戴/活体状态、绿光和红/红外的 ch0 波形（sparkline）、每通道 rawdata 和 AGC（增益档/drv0/drv1 电流）、丢帧统计、最近事件。

- **一定要贴皮肤**：模组光窗（圆形黑色透镜）贴在手腕内侧或外侧，松紧适中，别动。没贴皮肤时界面会提示"光窗前没有皮肤/手指"（rawdata≈2^23）；贴了但没脉搏成分时算法也可能硬出一个 30~40 bpm 的假值，看波形有没有规律的脉搏波再信数值。
- 心率行后面的 **"波形估算 xx bpm (主峰占比 q)"** 是脚本自己从最近 10 s 原始绿光做 DFT 算出来的脉率，和汇顶算法无关。q≥0.5 且两者一致才可信；两者相差 >1.6 倍会打 ⚠（算法锁到倍频/次谐波，2026-09-18 实测出现过 32 bpm@置信 100 而波形 55 bpm 的情况）；"无明显脉搏波" 说明没贴紧皮肤。
- 心率约 10 s 出值，血氧约 15 s。**这版 EVK 固件的血氧置信度恒为 0**（旧版算法去掉了置信度模块，FAQ 有说明），只看 % 值和"等级"。
- G-sensor 未开启（EVK 模式下 ACC 全 0），静止测试无影响；运动场景的心率不可信。
- 它复用 `evk_ble.py` 的连接/协议/解压缩代码。

汇顶官方上位机 GHTestTool 只有 Windows 版，Mac 上没有官方工具。EVK 主板上的 GR5515 蓝牙对外就是一个普通 BLE 外设（广播名 `GHealth_Device`，服务 UUID `0000190e-...`），所以可以不用 GR551x dongle，直接用 Mac 自带蓝牙 + 汇顶的串口协议（`AA 11 cmd len payload crc8`）来做基础调试。

## 准备（已做）

```
python3 -m venv tools/.venv
tools/.venv/bin/pip install bleak
```

## 用法（必须在 macOS 的 Terminal.app / iTerm 里跑，第一次会弹蓝牙权限请求，点允许）

```
cd /Users/cmac/chenzhiyuanthu/test-GH3x2x
tools/.venv/bin/python tools/evk_ble.py scan          # 扫描，看有没有 GHealth_Device
tools/.venv/bin/python tools/evk_ble.py info          # 查固件/驱动/芯片版本、芯片连接状态、读 0x0036/0x0030/0x0032
tools/.venv/bin/python tools/evk_ble.py reg 0x0108    # 读任意寄存器
tools/.venv/bin/python tools/evk_ble.py -v info       # 顺便打印 GATT 服务表
tools/.venv/bin/python tools/evk_ble.py raw 19 0E     # 发裸命令（十六进制），例：查协议版本
```

- 报 `Bluetooth device is turned off` 但系统蓝牙明明开着 → 是当前进程没有蓝牙权限。到 系统设置 > 隐私与安全性 > 蓝牙 里给 Terminal（或你用的终端）打开；从 Claude Code 里直接跑会因为宿主进程没权限而失败。
- 扫不到设备 → EVK 的 S5 要拨到 BLE（右），LED1 在闪；周围别开着 Windows 工具或手机 APP 占着连接（BLE 一次只能一个中心连它）。
- `info` 里 `0x0036 = 0xAA55`、`0x0030 = 0x0201`、`0x0032 = 0x0301` 就说明主板↔芯片链路正常。

## 采样（下发 ini 配置 → 启动 → 收 rawdata/算法结果 → 存 csv）

```
tools/.venv/bin/python tools/evk_ble.py start \
    --ini "GH3x2x/3. 软件设计/GH3X2X_V41xx版本算法驱动以及移植文档/功能配置工具以及配置指南/V4100参考配置/HR_SPO2_NADT_ADT_V4100_EVK.ini" \
    --func HR --seconds 20 --csv data/hr_test.csv
```

- `--func` 可写 `HR` / `SPO2` / `ADT,HR` 等（必须在 ini 的功能列表里）。流程：`0x10` 工作模式(EVK) → `0x17 5A` 硬复位 → `0xA1` 分包写入 ini 的 `[drvregister-table]` 和 `[algoregister-table]`（每包 ≤56 个寄存器，大端 addr/val）→ `0x0C` 启动 → 收 `0x0B` → `0x0C` 停止。
- csv 列：`t, func, frame_id, gs_x/y/z, ch, rawdata(24bit), agc(gain档位/drv0 mA/drv1 mA), results(算法结果 dict)`。HR 结果 `{0: bpm, 1: 置信度 0~100, ...}`。
- 已在这套 EVK 上验证（2026-09-18）：固件 `GHealth_EVK2_INT_V10.9(config3.4)_DRV_LIB`，驱动库 v4.1.0.0，芯片 v12_ev04，0x0036=0xAA55；手指按光窗 HR 配置下 rawdata 被 AGC 拉到 ≈13.06M（目标 13086228），约 10 s 后出心率值，置信度升到 99。
- 0x0B 包是压缩格式（包标志 bit0=1）：奇数包首帧绝对值 `[tag][24bit BE]` + AGC GU32 小端 `[gain][drv0][drv1][dc]`，其余帧是 4bit 类型 + n 个 nibble 的差分（见 `RawdataDecoder`，逻辑照抄 V4300 demo `gh_zip.c`）。
- EVK 固件不回 `0xA0`（查最大包长）和 `0x1A`，属正常；`0x0D` 是周期上报的电流/电量。
- G-sensor 数据全 0：EVK 模式下没开 G-sensor（协议 `0x11` 可设置，脚本没做）。静态测试无影响。

## 协议要点

- 帧：`AA 11 <cmd> <len> <payload> <crc8>`，crc8 = poly 0x07 / init 0xFF，覆盖 crc 之前的全部字节。
- 常用 cmd：`0x19` 查版本（payload 1 字节类型：01 固件、0D BLE、0E 协议、10 驱动库、11 芯片、13 HR 算法、1A SPO2、1B ECG）、`0x1A` 查芯片连接状态、`0x03` 读写寄存器（`mode cnt addrH addrL [data]`，mode 0 读 1 写）、`0x17` 芯片复位（5A 硬复位 / C2 软复位 / C4 sleep / C3 wakeup）、`0x10` 工作模式、`0x1F` 下发驱动配置、`0x0C` 启动功能、`0x08/0x0B` rawdata 上报。完整表见 `GH3x2x/3. 软件设计/.../EVK工程/GH3x2x 工程介绍_20221117.pdf` 第 6 章。
- 写寄存器 / 下发配置 / 启动采样这些会改芯片状态的命令脚本没有封装成子命令，需要时用 `raw` 手动发。

## 要用完整的官方工具怎么办

1. Mac 上装 Windows 虚拟机（Parallels / VMware Fusion / UTM，Apple Silicon 用 Windows 11 ARM，GHTestTool 是 x86 程序靠系统自带转译运行），把 GR551x dongle（CP210x USB 串口）直通给虚拟机，然后按 `AGENTS.md` 4.0 节的流程用。汇顶文档本身也建议在虚拟机里跑工具避开加密软件。
2. 或者用安卓手机装 `GH3x2x/3. 软件设计/APP以及账号/signed_ghealth_64_V1.0.9.13_build005.apk`，走 GHealth APP 采数（需要向汇顶申请账号，见 `APP账号.txt` 里的飞书链接）。
