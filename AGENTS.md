# GH3x2x (Goodix Cardiff A) 项目 — Agent 工作指南

本目录是汇顶 GH3x2x 系列健康监测芯片（PPG + ECG）的客户资料包 `GH3x2x/`，目标是把 GH3x2x 板子调通并跑起汇顶驱动/算法。本文件是从资料包里提炼出来的"必读摘要"，先看这里，再按索引去翻原始文档。

**当前状态**：手上是汇顶原装 GH3x2x EVK（通用 PPG 评估套件）。第一阶段按第 4.0 节"PC 工具直接评估"的通用流程从 Mac 走 BLE 调通；因 EVK2 固件不读加速度计且不可重编译，**现在主线是 `firmware/gh3x2x_xiao/`**：V4300 驱动 + 汇顶算法跑在 XIAO nRF52840 Sense 上（模组仍插在 EVK 上供电，SPI 经 H6 接 XIAO，STM32 NRST 接地），已验证 HR/HRV/SpO2/ADT 全链路、0 丢帧。移植章节（3、4.1~4.3）对这条路线直接适用。

**本仓库自己写的东西**（不属于汇顶资料）：
- `tools/`：Mac 蓝牙直连 EVK 的 Python 工具（`vitals.py` 实时心率/血氧，`evk_ble.py` 协议/解压/采数），见 `tools/README.md`。
- `ios/`：iPhone App "GH Monitor"（SwiftUI + CoreBluetooth，WHOOP Health Monitor 风格，按 `whoop monitor.jpg` 还原），见 `ios/README.md`；`ios/install.sh` 一键装机。Swift 端的协议/解压器已用真实抓包和 Python 版逐帧比对一致。
- `firmware/xiao_imu/`：XIAO nRF52840 Sense 的六轴 IMU 蓝牙上报固件（arduino-cli），给 App 提供运动数据（第一版方案）。
- `firmware/gh3x2x_xiao/`：**当前主线**——V4300 驱动 + 汇顶算法跑在 XIAO 上，板载 ACC 喂算法，走汇顶协议 BLE 上报（广播 `GH-XIAO`）；模组仍插在 EVK 上供电，SPI 经 H6 排针接 XIAO，STM32 NRST 接地。见 `firmware/gh3x2x_xiao/README.md`。Mac 上 `tools/vitals.py --name GH-XIAO --listen` 可直接看结果。
- `data/`：抓到的原始数据 csv/txt；`notes/`：从 PDF 截的 EVK 开关/接口图。
- **EVK2 固件不读板上加速度计**：`EvkPrj_V10.9` 的 `g_sensor.c` 里 LIS2DH/LSM6DSOX 驱动全在 `#if (BOARD_PLANFORM == DEMO_BOARD)` 内，EVK2 目标（`STM32F412Rx`, `BOARD_PLANFORM=EVK2_BOARD`）编译后 `gsensor_drv_get_fifo_data` 只返回全零 buffer，所以协议里 ACC 恒为 (0,0,0)，汇顶心率算法在无运动参考下运行。主板那颗 "G-Sensor" 是 LIS2DH 三轴（非六轴）。
- 注意 EVK 同时只能被一个中心设备连接：跑 iPhone App 时先停掉 Mac 上的脚本，反之亦然。

---

## 0. 工作约定（给 Agent）

- **资料是只读的**：不要修改/移动 `GH3x2x/` 下的任何原始文件；新代码、笔记放在仓库根目录或新建子目录。
- **PDF 读取**：`pdftotext -layout file.pdf -` 可用。PDF 带斜向水印，文本里会混入 `n ly`、`Go`、`d i x`、`lier` 之类的碎片，属于水印噪声，忽略即可。
- **压缩包**：`.zip` 用 `unzip`；`.7z` 用 `7zz`（`/opt/homebrew/bin/7zz`）或 `bsdtar -xf`。**不要**把解压产物放进 `GH3x2x/`。
- **xlsx**：没有 openpyxl，可用 `python3 zipfile + xml` 解析 `xl/sharedStrings.xml` 与 `xl/worksheets/sheetN.xml`。
- **文本文件编码**：资料包里的 `.txt` 多为 GB18030，`iconv -f GB18030 -t UTF-8` 后再读。
- **版本选择**：新项目一律用 **V4300**（`3. 软件设计/.../V4300版本驱动库以及移植指南/`）。V4100 目录名已标注"新项目不建议使用"，V4200 的 `000_README.txt` 说明示例 Demo 源码不是最新的。

---

## 1. 资料索引（先看哪份）

| 想做什么 | 看这份 |
|---|---|
| 项目整体流程（研发→整机验收→产测→性能验收） | `GH3x2x/GH3X2X 项目开发流程_V2.0.pdf` |
| 驱动移植总纲、宏配置、用户需实现的函数、常见问题 | `3. 软件设计/.../V4300.../GH(M)3x2x驱动库移植指南_v4.7.pdf`（对应驱动 v4.0.1.2 / DriverLib 4.3.0.0，DemoCode V1.6） |
| 移植快速版（PPT，含 SPI/CS/RST 排错） | `3. 软件设计/GH3X2X驱动调试说明.pdf` |
| 算法库调用、算法结果字段含义、内存池 | `3. 软件设计/.../V4300.../Goodix算法调用SDK接口说明书_v0.5.pdf` |
| 用 GHTestTool 生成寄存器配置数组 | `3. 软件设计/.../功能配置工具以及配置指南/Cardiff A 快速生成专属配置数组_V0.5.pdf` |
| 配置项详细含义（LED/PD map、slot、AGC、ADT、ECG） | `.../V4300.../GH3x2x customer project parameter adjustment guide (1).pdf`，`.../功能配置工具以及配置指南/GH(M)3x2x_EVK工具使用指南_V2.7.pdf` |
| 调光（AGC）异常分析 | `.../V4300.../GH3X2X and GH30XX AGC problem analysis-20250321.pdf` |
| 寄存器级细节（引脚、SPI/IIC 时序、中断、FIFO 格式、上电时序） | `1. 芯片介绍/(带寄存器版)GH3220_Datasheet_B_V1.5.pdf`（英文：`1. 芯片介绍/en/`） |
| 硬件设计（供电、PPG/ECG 原理图、layout 禁忌） | `2. 硬件设计/GH3220_硬件设计简介_V1.1.pdf`、`2. 硬件设计/*_Schematic_*.pdf`、`GH3x2x原理图及PCB设计审核CheckList_V1-1206.xlsx` |
| EVK 主板接口 / 跳线 | `.../功能配置工具以及配置指南/GH(M)3x2x_EVK硬件使用说明_V1.0.pdf` |
| EVK STM32 固件工程 & 上位机协议 | `.../功能配置工具以及配置指南/EVK工程/GH3x2x 工程介绍_20221117.pdf` + `EvkPrj_V10.9.7z` |
| 常见问题 FAQ（原始数据获取、ADC=0、Lead 事件没有、栈大小…） | `.../V4100.../GH3X2X 常见问题解答（FQA）文档-2022-12-07.pdf`（内容对 V4300 仍适用） |
| 手机 APP 采数（无感透传模式） | `3. 软件设计/APP以及账号/（A）GHealth数据采集App使用手册_V1.4_20220830.pdf`、apk：`signed_ghealth_64_V1.0.9.13_build005.apk`；账号在飞书 `7. 整机验收/GHealth 版本汇总.txt` 链接里 |
| 整机验收阈值 | `7. 整机验收/V4100版本驱动对应apk/GH(M)3x2x_整机验收说明和标准_V1.0 (1).pdf` |
| SDK 版本配套表 / RAM·ROM 资源统计 | `.../V4300.../GH3x2x_SDK_版本记录和配套表_20250530.xlsx`、`CardiffA 驱动库资源统计_v5.0.xlsx`、`0-【必须确认】GH3X2X客户需求确认表-V1.0.xlsx` |
| 第三方平台移植 demo | `.../V4300.../GR5xx_GH3220_Application/`（GR5515/GR5526 + FreeRTOS）、`.../V4300.../(c3_c6)esp-idf-v5.5_application_cardiff_a_kernel_v4300_algo_v4201.7z`（ESP32-C3/C6）、V4100 下有 nRF52840(NCS) demo |
| 参考配置 ini | `.../功能配置工具以及配置指南/V4300参考配置/*.ini`（HR_ADT / HR_HRV_ADT / HR_SPO2_NADT_ADT / SPO2_ADT / ECG(256/320/800hz)_ADT / BT） |

配置工具本体：`.../功能配置工具以及配置指南/PCTOOL-release-2.3.7.1.7z`（GHTestTool.exe，Windows；被杀毒/加密软件拦截时闪退，要加白名单或用虚拟机）。

**培训视频（全包只有这 3 个 mp4）**
- `GH3x2x/3. 软件设计/GH3X2X_V41xx版本算法驱动以及移植文档/功能配置工具以及配置指南/配置工具使用讲解.mp4` —— GHTestTool 改 LED/PD/slot 配置
- `GH3x2x/3. 软件设计/GH3X2X_V41xx版本算法驱动以及移植文档/功能配置工具以及配置指南/GH3X2X EVK2.3.x版本工具使用培训.mp4` —— EVK 工具整体使用培训
- `GH3x2x/3. 软件设计/APP以及账号/无感透传模式数据采集流程演示.mp4` —— GHealth APP 无感透传采数

`notes/` 目录存放从 PDF 截出来的图（EVK 开关位置、接口说明图），是本仓库自己生成的，不属于原始资料。

---

## 2. 芯片关键事实（以 GH3220 为准，GH3020/3026/3228T 同族）

**家族**：GH3020（4PD PPG，无 ECG）、GH3026（2PD）、GH3220（4PD + 单导联 ECG）、GH3220T/3026T/3228T（带 NTC 体温）。汇顶算法支持：HR、HRV、SpO2（仅腕部）、ECG、NADT（活体佩戴）、BT（体温）。**汇顶 PPG 算法只支持 25Hz 及其倍数采样率**，不要改公版配置的频率。

**电源**
- AVDD 2.0–3.6V（典型 3.3V），VDDIO 1.62–3.6V（决定通信电平，必须与 MCU IO 电平一致），VDDTX/VLED 2.0–5.5V（推荐 5.0V；LED 压降 Vf ≤ VLED − 0.35~0.7V，视电流档而定），LDOEN 接 AVDD。
- 三路电源建议同时上电；AVDD 起来后拉高 RESET，**RESET 拉高 ≥ 7ms 后主控才能访问总线**。
- RESET 低有效，拉低 ≥10µs 复位并进入 DeepSleep；也可用软件命令复位（SPI 首字节 / IIC 地址 0xDDDD 写 `0xC2`）。`CMD_SLP=0xC4`，`CMD_RESUME=0xC3`（resume 后等 500µs 再访问）。

**通信接口**（IICEN 引脚选择：1=IIC，0=SPI，两者不可同时用）
- SPI：最高 12MHz，**只支持 CPOL=0/CPHA=0**。寄存器地址 16bit，数据 16bit，FIFO 数据 32bit，**大端**。
  - 写：`0xF0 + addr(16) + len(16, 单位=寄存器个数) + data...`
  - 读：`0xF0 + addr(16)` → CS 拉高 ≥1µs → `0xF1` + 连续读。FIFO 地址 `0xAAAA`。
  - CS 在软件 CS 模式下**只能由驱动库控制**（`hal_gh3x2x_spi_cs_ctrl`），用户的 `spi_write/spi_read` 里**不要碰 CS**；CS 引脚初始化为普通 GPIO，不要交给 SPI 外设自动控制。硬件 CS 模式则需实现 `hal_gh3x2x_spi_write_F1_and_read`（CS LOW + 0xF1 + read... + CS HIGH）。
- IIC：最高 1MHz。7bit 地址高 5 位默认 0x05，低 2 位由 MISO(bit1)/CS(bit0) 引脚电平决定：
  | MISO | CS | 7bit | 写 | 读 | 宏 |
  |---|---|---|---|---|---|
  | L | L | 0x14 | 0x28 | 0x29 | `GH3X2X_I2C_ID_SEL_1L0L`（默认） |
  | L | H | 0x15 | 0x2A | 0x2B | `_1L0H` |
  | H | L | 0x16 | 0x2C | 0x2D | `_1H0L` |
  | H | H | 0x17 | 0x2E | 0x2F | `_1H0H` |
- INT：默认上升沿/脉冲输出（可配电平/极性），复位后 INT 会打出 40ms 周期方波（Rst_irq）。主控 INT 引脚配成**上升沿中断输入**。

**通信自检寄存器**
- `0x0036` chip_ready_code：读到 **0xAA55** 表示可以正常读写寄存器/FIFO（demo 代码用它做通信测试）。
- `0x0030` product_id_l = 0x0201，`0x0032` product_id_h = 0x0301，`0x0034` chip_id。
- `0x0000` system_ctrl：bit0 `rg_top_start`（开始采样），bit1 `rg_nosleep`，bit10 `rg_int_pwrup`。
- `0x000A` fifo_waterline（采样点数，≥3，最大 800）；`0x0108` slot enable；`0x0500/0x0502` 中断控制/使能；`0x0380` SPI/IIC 配置。

**FIFO 数据格式**（每点 4 字节）：bit31~29 = slotCfg 编号，bit28~27 = ADC 编号，bit26 = 调光标志（ECG 数据时表示 Fast Recovery 中），bit25 = 调光方向，bit23~0 = 24bit ADC。FIFO 共 800 点，超水线触发 Fifo_full，溢出触发 Fifo_ov 并覆盖旧数据。**PPG 的 24bit ADC code 正常应 > 8388607 (2^23)**，ECG 会小于 2^23 但不会到 0。

**工作模式**：No Sleep / INT Wakeup / INT doesn't Wakeup；驱动库（V4100+）已把唤醒逻辑内置到底层寄存器访问，可以在 demo 任意位置调用 `GH3X2X_ReadReg/WriteReg` 调试。

**中断源**（int_str）：com_ready、lead_on/off、fastrecovery、adc_done、fifo_full、fifo_ov、led_tune_fail/done、wearon/wearoff、timeslot_timeout（slot 太短）、sample_rate_err（采样周期放不下所有 slot）、rst_irq。

**LED/PD 拓扑**：2 个 LED Driver，Driver0 驱动 LED0~3，Driver1 驱动 LED4~7，每 slot 每 driver 只点一颗，两 driver 可同时点亮；4 路 PD（差分 PDxA/PDxC）可任意映射到 4 个 TIA，可并联。TIA 增益 10k~2000k，最多 8 个 slot × 4 ADC = 32 数据通道。

---

## 3. SDK 结构（V4300）

解压 `3-demo_code-4300_patch1-3.7z`（已含 patch1~3；如用旧包需按 `勘误文件（BUG修复）/ReadMe.txt` 用 `patch -p1` 打 3 个补丁，patch3 修 AGC 非对齐访问）：

```
demo_kernel_code/
  kernel/   gh_demo.c(主流程) gh_demo.h(对外API) gh_demo_config.h(★宏配置)
            gh_demo_user.c(★平台相关，用户实现) gh_demo_hook.c(★回调) gh_demo_reg_array.c(★驱动配置表)
            gh_demo_protocol.c gh_demo_inner.h gh_demo_version.h
  driver/   gh_drv*.h/.c（芯片寄存器/控制/接口/dump；gh_drv_registers.h 有全部寄存器地址宏）
  module/   gh_agc(调光) gh_ecg(lead off/降采样) gh_protocol(上位机协议+zip) gh_soft_adt(多传感器佩戴) gh_other
demo_algo_code/
  goodix_algo_application/  gh3x2x_demo_algo_config.h(★算法宏) gh3x2x_demo_algo_reg_array.c(★算法配置表) gh3x2x_demo_algo_hook.c(★结果回调)
  goodix_algo_call/         各算法调用封装 + 头文件
1-drv_lib-4300.7z   闭源驱动库 *common.a/.lib（按内核/编译器选：M0/M3/M4/M33/M7/A5/RISC-V/ESP32…，有 release/debug 两版，debug 版能打驱动库内部 log）
2-algo_lib-4300.7z  算法库：COMMON_DSP（必需）、COMMON_DL（HR/SPO2 需要，basic/medium 与 premium/exclusive 二选一）、HR(4 档资源)、SPO2(2 档)、ECG、HRV、NADT 以及 algo_params/ 网络参数 .c
```

**只允许改 `gh_demo_config.h`、`gh_demo_user.c`、`gh_demo_hook.c`、`gh_demo_reg_array.c`**（算法侧同理改 `*_algo_config.h`、`*_algo_reg_array.c`、`*_algo_hook.c`），其余文件不要动，便于以后升级 SDK。

**对外顶层 API**（`gh_demo.h`）：`Gh3x2xDemoInit()`（返回 `GH3X2X_RET_OK`=0；`-4` = `GH3X2X_RET_COMM_ERROR` 通信失败；`-3` = 读写函数未注册）、`Gh3x2xDemoInterruptProcess()`、`Gh3x2xDemoStartSampling(GH3X2X_FUNCTION_ADT|HR|SPO2|ECG|LEAD_DET|...)`、`Gh3x2xDemoStopSampling()`、`Gh3x2xDemoProtocolProcess(buf,len)`（上位机下行）、`Gh3x2xDemoArrayCfgSwitch(idx)`、`GH3X2X_FifoWatermarkThrConfig()`、工程模式 `Gh3x2xDemoStartSamplingForEngineeringMode()`。**以上函数 + `GhMultiSensorTimerHandle` 必须在同一线程调用，否则要加互斥锁**；RTOS 下 GH3x2x 任务栈 ≥4K，推荐 6K。

**用户必须在 `gh_demo_user.c` 实现的函数**（默认是空的 `GOODIX_PLATFORM_*_ENTITY()` 宏，什么都不做——这是初始化返回 -4 的最常见原因）：
- 接口：`hal_gh3x2x_spi_init/spi_write/spi_read/spi_cs_ctrl`（或 `hal_gh3x2x_i2c_init/i2c_write/i2c_read`）。`length` 是 `GU16`，缓冲是 `GU8[]`，**不要改成 uint8 长度或 16/32bit 数组**，单次读长度可能 >255。
- 复位/中断：`hal_gh3x2x_reset_pin_init/reset_pin_ctrl`（`__SUPPORT_HARD_RESET_CONFIG__=1`）、`hal_gh3x2x_int_init`（上升沿中断），中断 ISR 里调 `hal_gh3x2x_int_handler_call_back()`。
- 延时：`Gh3x2x_BspDelayUs/Ms`（只能比要求长，不能短）。
- Log：`GH3X2X_PlatformLog(char*)`（METHOD_0，依赖 snprintf）或 `GH3X2X_RegisterPrintf(&printf)`（METHOD_1）。
- G-sensor：`hal_gsensor_start/stop_cache_data`、`hal_gsensor_drv_get_fifo_data`（ACC 建议 ±4g 以上、100Hz、512LSB/g）。
- 协议上行（对接 APP/PC 工具时）：`Gh3x2x_HalSerialSendData`、`Gh3x2xSerialSendTimerInit/Start/Stop`，定时器周期 = `__GH3X2X_PROTOCOL_SEND_TIMER_PERIOD__`（10~50ms，须大于 BLE 连接间隔），定时器回调调 `Gh3x2xSerialSendTimerHandle()`。
- 多传感器佩戴定时器：`Gh3x2x_Create/Start/Stop/DeleteMultiSensorTimer`，定时器回调调 `GhMultiSensorTimerHandle()`。
- 可选：`Gh3x2xMallocUser/FreeUser`（动态内存）、`Gh3x2x_UserHandleCurrentInfo`（自定义调光）。

**关键宏（`gh_demo_config.h`）**
- `__GH3X2X_INTERFACE__` = `__GH3X2X_INTERFACE_SPI__` / `_I2C__`；`__GH3X2X_SPI_TYPE__` = `SOFTWARE_CS` / `HARDWARE_CS`；`__GH3X2X_I2C_DEVICE_ID__`。
- `__INTERRUPT_PROCESS_MODE__` = `__NORMAL_INT_PROCESS_MODE__`(中断) / `__POLLING_INT_PROCESS_MODE__`(轮询，周期 ≤1s 否则 AGC 来不及) / `__MIX_INT_PROCESS_MODE__`；`__PLATFORM_WITHOUT_OS__`。
- `__GH3X2X_INFO_LOG_TYPE__`（METHOD_0/1）、`__GH3X2X_INFO_LOG_LEVEL__`（LV_1 info | LV_2 debug | LV_3 warn | LV_4 error，可按位或）。**第一步先把 log 调通。**
- `__SUPPORT_PROTOCOL_ANALYZE__`=1 + `__PROTOCOL_SERIAL_TYPE__`（UART/BLE）：对接 GHealth APP / PC 工具；商用固件关掉即可。
- `__FUNC_TYPE_*_ENABLE__`：裁剪功能，用不到的关掉省 RAM/ROM；非 Keil-M4 平台商用算法只有 ECG/HR/SPO2/NADT/HRV，其它算法要在 `gh3x2x_demo_algo_config.h` 关掉否则链接报错。
- `__DRIVER_OPEN_ALL_SOURCE__`=0（用汇顶算法，链接 common 库）/1（全开源，不用汇顶算法，不链 common 库）。
- `__GH3X2X_ARRAY_CFG_MANUAL_SWITCH_EN__`：每张配置表只含一种主功能（HR+ADT / SPO2+ADT / ECG+ADT）时设 0 自动切表；否则设 1 手动 `Gh3x2xDemoArrayCfgSwitch()`。
- `__SUPPORT_HOOK_FUNC_CONFIG__`=1、`__SUPPORT_ALGO_INPUT_OUTPUT_DATA_HOOK_CONFIG__`=1：在 `gh_demo_hook.c` 的 `gh3x2x_get_rawdata_hook_func`（FIFO 原始数据，可解析 slot/ADC）和 `gh3x2x_algorithm_get_io_data_hook_func`（按功能送算法的帧数据）拿数据；`__SUPPORT_ALGO_INPUT_OUTPUT_DATA_LOG__`=1 直接打印算法输入输出。
- `__HARD_ADT_ALGO_CHECK_EN__`=1 + `__ADT_ONLY_PARTICULAR_WM_CONFIG__`=5：指环/指夹等无法用硬件 ADT 的形态，用软件判佩戴；阈值在 `gh3x2x_demo_algo_call_adt.c` 的 `__HARD_ADT_WAER_ON/OFF_THRD__`。
- BLE profile（对接 GHealth）：Service UUID `0000190e-0000-1000-8000-00805f9b34fb`，TX `00000003-...`，RX `00000004-...`，MTU 247。

**算法结果**在 `gh3x2x_demo_algo_hook.c` 的 `GH3X2X_<Func>AlgorithmResultReport()` 里取，`snResult[]` 含义：HR `[0]`=bpm `[1]`=置信度 0~100；SPO2 `[0]`=% `[2]`=置信度 `[3]`=置信等级(−3~5) `[5]`=无效标记位；HRV `[0..3]`=RRI ms `[4]`=置信 `[5]`=RRI 个数；ECG `[0]`=电压(10µV) `[1]`=bpm；NADT `[0]` bit0-1 佩戴状态(1 佩戴 2 脱落 3 非活体)；BT `[0]/[1]`=NTC 温度 0.01℃。算法运行 log 在 `GH3X2X_AlgoLog`。

**资源参考（Cortex-M4/Keil/O2）**：驱动+Demo ≈ 17~21KB ROM / 1~1.5KB RAM；透传协议 +6~8KB ROM / 9~18KB RAM；HR(4PD,S版) ≈ 45KB ROM / 11KB RAM 峰值；SPO2(4PD) ≈ 33KB ROM / 31KB RAM；ECG ≈ 28KB ROM / 26KB RAM。算法串行运行取最大值，并行运行取总和，详见资源统计表。

---

## 4. 板子调试流程（按顺序）

### 4.0 手上是汇顶原装 EVK 时：直接用 PC 工具，不需要移植驱动

EVK 套件 = EVK 主板（STM32F412 + GR5515 BLE，出厂固件已含驱动库）+ GH3x2x 载板模组 + PD/LED 光路模组（BTB 连接）+ GR551x BLE dongle + USB 线。`3. 软件设计/.../功能配置工具以及配置指南/` 整个目录就是围绕 EVK 的；本项目当前就是这条路线。

**主板上的开关/指示灯位置**（把 USB 口朝左放，看 `notes/EVK主板-开关与指示灯位置.png`、`notes/EVK主板-接口说明图.png`，原图在 EVK 硬件使用说明 图 2 和 GH3228T EVK quick start guide 图 2-1）
- **S5 通信切换开关**：板子**左上角**、`G-Sensor` 丝印旁边、USB 口正上方那颗拨动开关。拨**左**=USB 有线（丝印 `CH340-ARM`），拨**右**=BLE（丝印 `ARM-BLE`）。
- **S4 电源开关**：USB 口**右下方**、丝印带 `ON` 的拨动开关。拨**左**=ON，拨**右**=OFF。
- **LED3 充电指示**：S4 左边、紧靠左板边（SWD_MCU 排针上方）。
- **LED2 MCU 状态**（丝印 `ARM`）：板子上边缘中间；**LED1 BLE 状态**（丝印 `BLE`）：板子上边缘偏右。上电正常后 LED2 规律闪，选 BLE 后 LED1 规律闪。
- 板子下边缘四个按键从左到右：**GH3x2x RST、MCU RST、预留按键 1、预留按键 2**（EVK 工程里 KEY-2 可模拟 G-sensor 动作）。
- 左下角一排跳线从上到下：VLED、AVDD、VDDTX 电源 Jumper、IICEN、LDOEN；再往下是 ECG 导联接口（3.5mm 座）。
- 中间 PCIe 形状卡座插 GH3x2x 载板模组，模组上圆形黑色部分是 PD/LED 光路模组（BTB 连接）；模组右侧一排排针是外接模组的 DIP 接口 H6，右边缘 FPC 座是 BLE SWD / 外接 BTB。屏幕在右上方。

**硬件准备**
- 模组插好，接 USB（LED3 亮）；S4 拨左 ON（LED2 规律闪）；S5：有线拨左 `CH340-ARM`，无线拨右 `ARM-BLE`（LED1 规律闪，此时可拔 USB 用电池）。
- 跳线默认即可：AVDD 3.3V、LDOEN→VDD（AVDD 为 3.3V 时；1.8V 时接 GND）、VDDTX 跟 VLED、VLED 选 DC5V 或 VIN。
- **测 ECG 必须用 BLE + 电池**，接着 USB/串口会引入工频共模干扰，Lead 检测会失败。
- 板上按键：MCU RST、GH3x2x RST；AVDD/VDDTX/VLED 三处有串万用表的功耗测试口（读数减去不插模组的静态电流）。
- 外接自制模组：BTB 座 H3 或 DIP 排针 H6（有 PCIE→DIP 转接板资料包）；改 I2C 时要拆掉黑色小模组、外接模组自带上拉，且主板丝印 MISO 接模组 SDA、MOSI/SDA 接模组 SCL。

**开发机是 Mac 时（当前实际路线）**：官方 GHTestTool 只有 Windows 版。日常实时看心率/血氧用 `tools/vitals.py`（终端实时刷新，Ctrl-C 停；`--plain` 按行打印；`--csv` 存数据）。底层工具 `tools/evk_ble.py`（bleak，走 Mac 自带蓝牙，不需要 dongle）已经能完成：`scan`/`info`（版本、0x0036 自检）、`reg`（读寄存器）、`raw`（裸命令）、`start --ini … --func HR --csv …`（下发参考配置、启动采样、解压缩 0x0B 数据、输出心率结果并存 csv）。详见 `tools/README.md`。蓝牙权限：给 Terminal 开过一次后 Claude Code 里也能跑（Bash 需 `dangerouslyDisableSandbox`）。这套 EVK 已验证：固件 EVK2 V10.9 / 驱动库 v4.1.0.0（V4100 代）/ 芯片 v12_ev04，BLE 名 `GHealth_Device`，地址 `088DC357-D4A5-2EEC-C2A5-51D84C63172B`（macOS 的 CoreBluetooth UUID，换电脑会变）。要用完整 GUI 工具就在 Parallels/UTM 的 Windows 里跑并把 GR551x dongle USB 直通，或用安卓手机 + GHealth APK。

**PC 端准备**（Windows）
1. 装驱动：有线 CH340（`CH341SER.exe`）、无线 dongle CP210x VCP。
2. 解压 `PCTOOL-release-2.3.7.1.7z` → 运行 `GHTestTool.exe` → 直接 Login → 选芯片型号，Drive Mode（芯片+算法参数）或 Evaluation Mode（只有芯片参数）→ Save。闪退 = 杀毒/加密软件拦截。
3. View > Device Type Select：有线选 `CH340 (EVK Mainboard)`；无线选 `GR551x Dongle`（460800）→ View > BLE Device Scan → Start Scan → 选 `GHealth_Device`（多台时选 RSSI 最小/信号最强的）→ Connect。左下角状态变为已连接。多台 EVK 混用先 View > BLE Addr Setting 改 MAC。
4. View > Communication test：长短包收发 / 读写寄存器 / 硬件 Reset，这是判断"主板↔芯片"链路的第一步。Reg RW 页读 `0x0036` 应为 `0xAA55`。
5. 电流校准（要看功耗时）：View 里 Current Calibration → Automatic Calibration；EVK 复位/重新上电后要重做。

**采样**
1. View > Evaluation → Load 一份 ini：
   - PPG：`V4100参考配置/HR_SPO2_NADT_ADT_V4100_EVK.ini`（EVK 光路：slot0 绿灯 L0+L4 → HR+SOFT_ADT，slot1 红灯 L2 / slot2 红外 L1 → SPO2，slot3/4 → SOFT_ADT，slot5 红外 5Hz → ADT；4 颗 PD 接 RX0~RX3），或 `V4300参考配置/HR_SPO2_NADT_ADT_V4300.ini`（公版，单绿灯 L0）。**这些是 EVK 公版参考配置，换自己硬件必须按原理图重做 LED/PD 映射。**
   - ECG：`V4300参考配置/ECG(800hz)_ADT_V4300.ini`（slot0 ECG 800Hz→软件降到 500Hz，slot1 ADT）。左手握 ECGP+RLD，右手握 ECGN，反了波形倒置；导联线要带 GND 屏蔽，<1m，对地电容 <200pF。
   - 体温：`V4300参考配置/BT_V4300.ini`（仅 3220T/3026T/3228T）。
2. 功能组合下拉框选功能 → Start → Select 选显示通道（同名带 LED 颜色的通道就是 PPG，`CHx_F` 是滤波后通道；总通道 ≤32）。
3. 手指按在光窗上或戴手腕，应看到 PPG 脉搏波；区域 3 显示佩戴/导联状态；右下角 TX Current / Chipset Current 为功耗。
4. 数据自动存 csv（可在 File Save 设路径、备注、行数 Count=0 存全部）。csv 里带 LED 颜色的列即 PPG rawdata，"ECG" 列即 ECG；用第 4.6 节公式换算。
5. 改参数：View > User Configuration → Load → 改 → Save（工具会做合法性和时序检查，Log Information 里看报错）→ 回 Evaluation 重新 Load。Decode 可把配置导出成 C 数组给以后的移植用。
6. 固件升级只能走 View > Firmware Update（bin），**不要用 JLINK 直接烧 STM32**，会破坏 bootloader；无线升级后要重连，等 10s 再读版本。

**EVK 也可以当 MCU 开发板用**：`EVK工程/EvkPrj_V10.9.7z` 是 STM32 Keil + FreeRTOS 工程（线程 TaskCardiffChipRespond 跑 `Gh3x2xDemoInterruptProcess/ProtocolProcess`），在里面改 `__GH3X2X_INTERFACE__`、`__INTERRUPT_PROCESS_MODE__`、`SLAVER_LOG_EN`（RTT log）就能验证自己的应用逻辑；开 `GSENSOR_MOVE_VIA_KEY_S1` 后按 KEY-2 可模拟 G-sensor 动作；设为无感透传模式后连 GHealth APP 采数。

### 4.1 硬件 & 上电检查（自制板 / 外接模组时）
1. 确认接口（SPI/IIC，IICEN 引脚电平）、VDDIO 与 MCU IO 电平一致、AVDD/VDDTX 电压范围、LDOEN 接 AVDD、VREF/VBG 各 1µF 到地。
2. 上电顺序：电源稳定 → RESET 拉高 → 等 ≥7ms（demo 里 HardReset 后 delay 30ms）→ 才做总线操作。
3. 用示波器/逻辑分析仪看 SCLK/MOSI/MISO/CS：CS 波形不对 → CS 没配成普通 GPIO；MOSI 电平不对 → VDDIO 与 MCU 不匹配；SPI 模式必须 mode 0。
4. INT 引脚复位后应看到 40ms 周期方波（rst_irq），这是芯片活着的最直观信号。

### 4.2 通信打通（最小验证）
1. 先只做：初始化 SPI/IIC + RESET + delay → 读 `0x0036`，期望 `0xAA55`；再读 `0x0030/0x0032` 期望 `0x0201/0x0301`。
2. 读不到：逐项排查供电、RESET 时序、IICEN 电平、IIC 地址低两位（看 MISO/CS 硬件接法）、读写函数的长度类型/大端、CS 控制归属、延时函数是否偏短。
3. `Gh3x2xDemoInit()` 返回 −4 = 上面这些没通；−3 = 读写函数没注册（接口宏与实现不一致）。

### 4.3 驱动移植（按移植指南 v4.7 第 3 章）
1. 把 `demo_kernel_code`、`demo_algo_code`、对应平台的 `*common.a/.lib` 加进工程；include 路径加 `kernel/`、`driver/inc`、`module/*`、算法 `inc/`。GCC/CMake 平台用 `-Wl,--start-group ... --end-group` 包住所有 goodix 库，链接顺序问题见指南附录四。
2. 改 `gh_demo_config.h`：接口、中断模式、有无 OS、log 方式、要启用的功能、协议开关。
3. 填 `gh_demo_user.c` 全部 HAL 函数（见第 3 节）。
4. 生成并替换配置表（4.4 节），填到 `gh_demo_reg_array.c` 的 `gh3x2x_reg_listX` 与 `gh3x2x_demo_algo_reg_array.c` 的 `gh3x2x_algo_reg_listX`，**两者索引 X 必须一一对应**，初始化默认加载 list0。
5. 主流程：`Gh3x2xDemoInit()` → `Gh3x2xDemoStartSampling(GH3X2X_FUNCTION_ADT)` →（中断信号量 / 轮询定时器）→ `Gh3x2xDemoInterruptProcess()`；在 `Gh3x2x_WearEventHook` 收到 wear on 后再开 HR/SPO2，wear off 关闭。ECG：先 `Start(GH3X2X_FUNCTION_LEAD_DET)`，`Gh3x2x_LeadOnEventHook` 里再 `Start(GH3X2X_FUNCTION_ECG)`，lead off 时 Stop。
6. 编译报 malloc/free/snprintf 缺失 → 换 `__GH3X2X_INFO_LOG_METHOD_1__` 或用平台等效函数；链接报 `__sbrk/_write/...` 同理。RAM/ROM 超 → 关掉没用的功能宏、缩小 `__GH3X2X_RAWDATA_BUFFER_SIZE__` 等 buffer。

### 4.4 生成自己硬件的配置数组（GHTestTool 2.3.7.1，Windows）
1. `GHTestTool.exe` → Login（无需改参数）→ View > User Configuration → Load `V4300参考配置/xxx.ini`。
2. Wizard → LED CONFIG：按原理图删掉默认映射、按颜色重新 Add（同色 LED 同时勾选）。
3. SLOT CONFIG：绿灯 slot0、红灯 slot1、红外 slot2~5；右键 LED → Check config info 设初始电流 / AGC 类型（单 LED0~3 用 drv0，LED4~7 用 drv1，双 LED 用 drv0&drv1 且电流上下限减半）。参考电流：单灯手环 20/20/20/10/0/10mA，AGC UP 150 DOWN 10；双灯或戒指 10/10/10/6/0/6，UP 100 DOWN 5。PD 列表拖到 slot 对应 RX 上，用不到的 RX 选 32 关闭。
4. CONFIG 保存 → 顶部 HR 页把用不到的 `ALGO_CHx` 改成 32（只有 2 个 PD 就把 CH2 之后全设 32），CTR 最大的通道放 ALGO_CH0。
5. **Save → 重新 Load → Decode** 导出 txt；文件末尾两个同名 `STGh3x2xReg stGh3x2xRegConfigArr` 数组，第一个是驱动表，第二个是算法表。ini 的 `[drvregister-table]` 字段也可直接复制。
6. ADT 阈值：Wizard 里勾选 ADT→common→FIFODATA_OUTPUT_ENABLE 先把 ADT 原始数据放出来；5 人左右手各戴 10s 取均值 A，对空 10s 取均值 B，`WEARON = B + (A−B)×0.437`，`WEAROFF = B + (A−B)×0.437×0.9`。对空 ADT 原始值 < 8460000 说明漏光尚可。
7. 采样率 = 32000 / ((1+FASTEST_SAMPLE_RATE) × (1+SAMPLE_RATE_DIVIDER))，默认 31/39 → 25Hz。高频功能 slot 放前面，各 slot 频率要成倍数关系。软件 AGC 时 FIFO 水线建议每 0.5s 中断一次（8 通道×25Hz → 水线 100）。
8. ECG 配置只改 ADT 部分（slot1）；ECG 硬件采样率固定 800Hz（导联检测需要），软件降采样到 500/250Hz 送算法，`gh_ecg.c` 里 `RESAMPLE_800HZ_TO_500HZ` 等宏选一个为 1、`GH3X2X_DOWNSAMPLE_OPENALL` 设 0；ECG Auto Control 选 2（software）。

### 4.5 冒烟测试 & 数据核对
- AGC 冒烟：戴好静置 30s，再微微抬离皮肤 30s，看 LED 电流或 TIA gain 有没有变化，变了说明 AGC 在工作。默认 gain：HR 250k（档 5），SPO2 ≤50k（档 2）；默认电流 绿 20mA / 红 50mA / 红外 40mA；AGC 电流范围 绿 10~200mA、红/红外 40~100mA。
- 原始数据 sanity：PPG ADC code 应 > 2^23；大量 0 → 读写函数长度/类型/单次长度限制/总线干扰。
- 数据落地：接好 BLE 协议后用 GHealth APP "无感透传（Auto Pass Through）"连接，数据按功能存到手机 `/sdcard/GoodixHBD/server/<功能>/*.csv`；也可用 EVK PC 工具（有线 CH340 或 GR551x dongle）View > Evaluation 采集/保存 csv。EVK 固件只能通过 PC 工具升级，JLINK 直接烧会破坏 bootloader。
- 算法出值与结构强相关：没有整机结构前只要算法能跑通即可，**不要**在裸板上纠结 HR/SpO2 准确度。

### 4.6 换算公式
- PD 电流 (µA) = (ADC_code − 2^23) × A，A 为 TIA 折算因子（10k:1.07e-5, 25k:4.29e-6, 50k:2.15e-6, 100k:1.07e-6, 250k:4.29e-7, 500k:2.15e-7, 1000k:1.07e-7, 2000k:5.36e-8 µA/LSB）；开 DC cancel 时再加 `BG_cancel × DC_cancel/255`。
- CTR (nA/mA) = (rawdata − 2^23) × 1800 × 1000 / (I_LED(mA) × R(kΩ) × 2 × 2^23)。
- ECG 电压 (V) = (ADC_code − 2^23) × 1.8 / 2^23 / 20。
- 6 导联换算：ECG2 = ECG0−ECG1，ECG3 = 0.5·ECG1−ECG0，ECG4 = 0.5·ECG0−ECG1，ECG5 = 0.5·(ECG0+ECG1)。

---

## 5. 常见问题速查

| 现象 | 优先排查 |
|---|---|
| `Gh3x2xDemoInit: init fail, error code: -4` | 电源/RESET≥7ms/IICEN/VDDIO 电平/CS 归属/SPI mode0/IIC 地址/HAL 函数是不是还是空宏；逻辑分析仪对照 datasheet 时序 |
| 程序卡在某函数出不来 | 掉进 while(1) 陷阱：关看门狗、开 log 看报错、单步 |
| 概率性开启功能失败 / 数据异常 | 顶层 API 不在同一线程且没加锁；栈不够（≥4K）；FIFO 溢出（通信太慢或其它线程占用久）；I2C 读偶发错误加恢复机制 |
| 原始数据很多 ADC=0 | 读函数把 GU16 length 改成 uint8_t、缓冲改成 16/32bit 数组、平台单次读 ≤255 字节限制、总线干扰 |
| ECG 接电极没有 Lead 事件 | 样机连着电脑 USB/串口引入工频干扰（改电池+BLE）、桌面附近电线、采样率被改动（必须 800Hz）；研发期用心电模拟仪 |
| 开 SPO2 后 ADT 报脱落 | 红/红外比绿灯亮，结构漏光 → 改结构；GHealth 整机验收测漏光 |
| 活体检测长时间不出值 | 运动幅度大时算法故意不出值，用 `lubFrameId/25` 算运行秒数自行兜底 |
| 血氧置信度恒为 0 | 旧算法版本剔除了置信度模块，属正常 |
| 非 Keil-M4 平台编译缺算法库 | 只交付 ECG/HR/SPO2/NADT/HRV，其它在 `gh3x2x_demo_algo_config.h` 关掉 |
| 工具 GHTestTool 闪退 | 加密/杀毒软件拦截，加白名单或换机/虚拟机 |
| AGC 分析提示"default gain 用不上 / 异常比例高" | 检查 GAIN_ADJ_EN 总开关、每 slot AGC_ENABLE 选 drv0/drv1 是否与硬件一致、默认 gain/电流/上下限 |
| 自己移植的 BLE 固件上位机丢帧（帧号成块跳 6~8，先发的功能丢得少） | `__GH3X2X_PROTOCOL_SEND_TIMER_PERIOD__` 比 BLE 连接间隔短，突发包被蓝牙控制器静默丢弃；设为 ≥ 连接间隔（XIAO 上用 40 ms），见 `firmware/gh3x2x_xiao/README.md` |
| 想用自己的调光 | 配置里关硬件调光、`__SUPPORT_SOFT_AGC_CONFIG__`=0，在 `Gh3x2x_UserHandleCurrentInfo` 里调 `GH3X2X_SlotLedCurrentConfig/GH3X2X_SlotLedTiaGainConfig` |

---

## 6. 整机验收 / 产测阈值（备查）

- 基本通路：丢包率 <1%，采样率 25Hz ±1%。
- G-sensor：512LSB/g（±15%），量程 ≥±4g，无跳点，噪声 ≤100LSB。
- AFE 噪声（暗盒，Gain=100k，Tint=158µs）：≤11.2µVrms。
- 漏光（对空）：RED/IR ≤0.8nA/mA 或 ≤1.5%CTR；GR ≤1.03nA/mA 或 ≤3.7%CTR。
- 基础光学灵敏度 CTR：GR ≥28、IR ≥36、RED ≥36 nA/mA。
- 产测工单：10 台过验收样机 × 每台治具采 CTR，治具间均值离散 ±10% 内，数据填 `6. 产测资料/产测治具工单调整&CTR数据收集.xlsx`。
- 性能验收：GHealth 无感透传 + Polar 带对比，≥10 名黄种人，用例见 `8. 性能验收/*.xlsx`。

---

## 7. 硬件/结构红线（改板前看）

- GH3x2x 与 LED、PD 做在同一小板上（方便半成品产测和拆解），屏蔽罩接 GND。
- PD 走线远离 SPI/IIC/INT/LED driver 数字线，差分等长并有 GND 屏蔽；ECGN/ECGP/ECDR 4~5mil 内层走线、GND 包地、走线电容 <15pF，0.2mm 内避开数字线，1mm 内避开时钟线；DCS0/DCS1 间 2.2µF 高通电容就近放。
- 电极串 100k + TVS（结电容 ≤1pF，漏电 ≤1nA）；VLED 线宽 ≥0.2mm（推荐 0.3mm）。
- 光路结构参数（LED-PD 间距、透镜、遮光墙）须符合 `4. 结构设计/GH3220&GH33XX_结构及工艺设计规范_V1.3.pdf`，否则汇顶不保证算法性能。
- 推荐器件：LED 聚飞 IRRG1816C / 欧司朗 SFH7016，PD 聚飞 RA4437P94N01 / 欧司朗 SFH2703，三轴 MXC3439/MXC3635，主控 GR5515IGND。
