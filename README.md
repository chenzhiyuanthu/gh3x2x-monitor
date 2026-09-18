# GH3x2x Monitor — 汇顶 GH3x2x（Cardiff A）PPG 心率/血氧从零调通

把汇顶 GH3220 系列 PPG 芯片的 EVK 调通，并做成一套能实时看心率、血氧、HRV、佩戴状态和运动状态的工具链：

| 目录 | 内容 |
|---|---|
| `AGENTS.md` | 从汇顶资料包提炼的"必读摘要"：芯片关键事实、SDK 结构、EVK 开关/接口、调试流程、常见问题、验收阈值。给人和 AI agent 一起看。 |
| `tools/` | Mac 直接用自带蓝牙连 EVK / XIAO 的 Python 工具：`vitals.py` 实时心率血氧，`evk_ble.py` 汇顶 Uprotocol 协议、数据解压、寄存器读写、下发配置采数 |
| `ios/` | iPhone App "GH Monitor"（SwiftUI + CoreBluetooth，WHOOP Health Monitor 风格）：实时心率/血氧/HRV/呼吸率/静息心率/佩戴/运动，PDF 健康报告 |
| `firmware/gh3x2x_xiao/` | **主线**：汇顶 V4300 驱动 + 算法跑在 XIAO nRF52840 Sense 上，板载加速度计喂给汇顶算法做运动抗干扰，汇顶协议 BLE 上报（`GH-XIAO`） |
| `firmware/xiao_imu/` | 第一版方案：XIAO 只当六轴 IMU 蓝牙上报 |
| `notes/` `data/` | EVK 开关/接口截图；抓到的原始数据 |

汇顶的客户资料包（`GH3x2x/`）和 SDK（驱动库、算法库、demo 源码、算法网络参数）是保密资料，**不在本仓库里**；`firmware/gh3x2x_xiao/GOODIX_SDK.md` 说明了拿到资料包后如何一步步还原出可编译的固件工程（本仓库对 SDK 的全部改动在 `goodix_sdk.patch`）。

主要经验（详见各目录 README）：
- 汇顶 EVK2 出厂固件不读板上加速度计，算法在无运动参考下会锁到 ½ 倍频（心率显示 30 多）；把驱动+算法搬到 XIAO 上并喂真实 ACC 后心率 77~94 bpm、置信度 95~99。
- 自己实现 BLE 上报时，协议发送定时器周期必须大于 BLE 连接间隔，否则突发包被蓝牙控制器静默丢弃（40% 帧丢失）。
- SpO2 只在红/红外脉动足够（模组压实在手腕）时才出值，裸模组贴不实时算法会置无效标记拒绝出值。
