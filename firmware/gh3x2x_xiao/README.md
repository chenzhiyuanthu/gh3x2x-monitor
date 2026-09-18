# firmware/gh3x2x_xiao — 汇顶 V4300 驱动 + 算法跑在 XIAO nRF52840 Sense 上

目的：EVK2 固件不读加速度计、也没法重编译，所以把汇顶 **V4300 驱动库 + 算法库（HR exclusive v2.0.3.0 / HRV / SpO2 premium / NADT / ADT）** 搬到 XIAO 上跑，XIAO 板载 LSM6DS3 的 ACC 直接喂给汇顶算法做运动抗干扰，再用汇顶原协议经 BLE 上报给 iPhone App（广播名 `GH-XIAO`）。EVK 主板只负责给模组供电。

## 接线（EVK 主板 H6 "外接 GH3x2x 模组 DIP" 排针 → XIAO）

| H6 | XIAO | 说明 |
|---|---|---|
| SCLK | D8 (SCK) | SPI mode 0, 4 MHz |
| MISO | D9 (MISO) | |
| MOSI | D10 (MOSI) | |
| CS | D2 | 软件 CS，驱动库控制 |
| INT | D1 | 上升沿中断 |
| RST | D3 | 硬复位 |
| GND | GND | 必须共地 |

- 模组仍插在 EVK 卡座上，EVK 继续供电（S4 开；AVDD 3.3 V、VLED 5 V 跳线默认）。**不要**把 XIAO 3V3 和 EVK 的 VDDIO 连在一起。
- **SWD_MCU 排针上把 NRST 和 GND 短接**（相邻两根），让 STM32 保持复位、不再驱动 SPI 总线，否则两个主控会打架。EVK 的蓝牙芯片仍会广播 `GHealth_Device`，App 会优先连 `GH-XIAO`。
- H6 引脚位置见 `notes/EVK主板-接口说明图.png` / EVK 硬件使用说明 图 5。

## 目录

```
gh3x2x_xiao.ino          主循环：init → StartSampling(ADT|HR|HRV|SPO2) → INT 触发 Gh3x2xDemoInterruptProcess
src/platform_xiao.cpp    HAL：SPI/CS/RST/INT、延时、log(USB 串口)、LSM6DS3 25 Hz 采样→512 LSB/g、BLE(ArduinoBLE, 汇顶 GATT)、协议发送定时器、多传感器定时器
src/xiao_hal.h / xiao_app.h   C 接口
src/goodix/demo_kernel_code   V4300 demo（含 patch1-3），改动：gh_demo_config.h、gh_demo_reg_array.c（EVK 模组配置 + V4300 芯片补丁寄存器）、gh_demo_inner.h（平台宏映射到 xiao_hal.h）
src/goodix/demo_algo_code     V4300 算法调用层，改动：gh3x2x_demo_algo_config.h（HR EXCLUSIVE / SPO2 PREMIUM，关 ECG）、gh3x2x_demo_algo_reg_array.c
src/goodix/algo_params        HR exclusive 网络参数、SpO2 gh3x2x-v2.23 网络参数、HRV/NADT 配置
lib/                          softfp 静态库：驱动 common + hr/spo2/hrv/nadt/common_dsp/common_dl
build.sh                      arduino-cli 编译；`build.sh flash` 烧录到 /dev/cu.usbmodem2101（或 PORT=…）
```

资源：Flash 545 KB / 811 KB，静态 RAM 129 KB / 232 KB（算法内存池 30 KB，协议发送缓冲 16 KB）。

## 验证

- 串口 115200：开机打印驱动/算法版本；`Gh3x2xDemoInit -> 0` 且 `sampling ADT+HR+HRV+SPO2` 表示芯片通了；`-4` = SPI 没通（查接线/NRST）。每 15 s 自动重试。
- Mac：`tools/.venv/bin/python tools/evk_ble.py --name GH-XIAO info`（查版本/寄存器），`tools/.venv/bin/python tools/vitals.py --name GH-XIAO --listen`（实时心率/血氧，不下发配置）。
- iPhone App 自动优先连 GH-XIAO，只监听。

## 实测（2026-09-18，EVK 模组 + XIAO）

- 芯片通信、ADT 佩戴事件、HR/HRV/SpO2 三路 25 Hz 帧全部正常，帧里 ACC 为真实值（静止时模长 ≈ 512 LSB = 1 g）。
- 汇顶 HR：戴好后 30 s 内出值，77~94 bpm，置信度 95~99；之前 EVK 固件（ACC 恒 0）常见的 30 bpm 次谐波锁定没再出现。
- SpO2 只有红/红外脉动足够时才出值：裸模组贴得不实时 red 通道 AC 只有 ~12 k counts（DC 4.6 M，灌注 ≈ 0.26 %），R 值在 0.5~1.1 乱跳，算法置 `snResult[5]` 的 bit3（R 无效）/bit4 拒绝出值（显示 0 %，置信 ≈ 19，等级 0）；模组用带子/胶布压实在手腕背面静止 30~60 s 后能出 86~88 %。这是结构/贴合问题，不是固件问题（见 AGENTS.md 4.5 "算法出值与结构强相关"）。
- **BLE 丢包坑**：协议发送定时器原来是 10 ms，比 BLE 连接间隔（15~30 ms）短，中断处理一次会攒 6 个包连发，nRF52 控制器只有几个 ACL 缓冲，超出的包被静默丢掉（Mac 端 40 % 帧丢失，先发的 HR 丢得少、后发的 HRV/SpO2 丢得多）。汇顶移植指南也写了"定时器周期须大于 BLE 连接间隔"。现在 `__GH3X2X_PROTOCOL_SEND_TIMER_PERIOD__` = 40 ms（≈25 包/s 上限，实际需要 ~14 包/s），60 s 内 0 丢帧。
- `__GH3X2X_RAWDATA_BUFFER_SIZE__` 改成 800×4（芯片 FIFO 满容量），一次中断读空 FIFO，不再刷 `process need repeat, soft evt = 0x4`。
- 串口里 `Driver lib can't analyze this protocol` 出现在收到事件 ACK（0x16）时：ACK 处理函数按设计返回 IGNORE 且无回包，demo 就打这行，ACK 其实已生效，忽略即可。

## 已知限制 / 备注

- 配置表来自 `HRV_HR_SPO2_NADT_ADT_V4100_EVK.ini`（EVK 光路：绿灯 L0+L4、红 L2、红外 L1、4 PD）加上 V4300 公版新增的 5 个芯片补丁寄存器（0x0020/0x0022 pad ctrl、0x0120、0x0506、0x069A）。
- 协议命令 0x1A（芯片连接状态）demo 不支持，属正常。
- ADT 佩戴事件由芯片硬件产生；NADT（活体）用 SOFT_ADT_GREEN 通道，需要 ACC，已由 XIAO 提供。
- 换算法档位/功能：改 `gh3x2x_demo_algo_config.h` + `build.sh` 里的库文件名。
