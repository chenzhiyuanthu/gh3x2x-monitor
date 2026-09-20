# GH Monitor — iPhone App（WHOOP Health Monitor 风格）

原生 SwiftUI + CoreBluetooth，优先连 `GH-XIAO`（`firmware/gh3x2x_xiao`，汇顶驱动+算法跑在 XIAO 上），也兼容原 EVK（BLE 名 `GHealth_Device`），实时显示心率、血氧、HRV、呼吸率、静息心率、佩戴状态、连接状态；界面按 `../whoop monitor.jpg` 还原。

```
ios/
  install.sh               一键：xcodegen → 签名构建 → 打 ipa → devicectl 装到 iPhone
  GHMonitor/
    project.yml            xcodegen 工程描述（bundle id com.chenzhiyuan.ghmonitor，Team 493WT6Z4J4，iOS 17+）
    Resources/evk_config.ini   汇顶参考配置 HRV_HR_SPO2_NADT_ADT_V4100_EVK.ini（原样打包，运行时解析）
    Resources/Assets.xcassets  图标、颜色
    Sources/
      GHMonitorApp.swift          入口；`--demo` 启动参数灌假数据（模拟器看布局）
      BLE/GoodixProtocol.swift    帧格式 AA 11 cmd len payload crc8、命令表、功能位、CRC8
      BLE/EVKConfig.swift         解析 ini 的 [drvregister-table]/[algoregister-table]/功能列表（zlib+base64）
      BLE/RawdataDecoder.swift    0x0B 数据包解压（奇数包首帧绝对值 + nibble 差分），与 tools/evk_ble.py 逐帧一致
      BLE/IMUManager.swift        第二路蓝牙：连 XIAO-IMU，解析 50 Hz 六轴包
      BLE/EVKManager.swift        CoreBluetooth：扫描→连接→notify→查版本→工作模式→硬复位→分包写配置→启动 ADT|HR|HRV|SPO2；断线自动重连；事件 ACK
      Model/VitalsStore.swift     汇总：HR/SpO2/HRV(RMSSD)/呼吸率(PPG 基线估算)/RHR/佩戴状态/心率历史/波形
      Model/SignalProcessing.swift 去趋势、DFT 主峰（脉率交叉校验、呼吸率）、RMSSD
      Views/HealthMonitorView.swift 主界面；Views/HeartRateChart.swift 网格+趋势线+虚线游标；Views/Theme.swift 配色/卡片/绿色标签
      Views/DeviceSheet.swift     点左上角 "<" 或右下角按钮：连接状态、固件版本、附近设备、原始数据、日志、重连/断开
      Report/HealthReport.swift   "SHARE YOUR HEALTH REPORT" → 生成 A4 PDF 分享
```

## 安装 / 更新

1. iPhone 用数据线连 Mac，解锁，弹窗点"信任"。
2. `ios/install.sh`（或在 Xcode 里打开 `GHMonitor/GHMonitor.xcodeproj`，选自己的 iPhone，⌘R）。
3. 首次打开允许蓝牙权限。用的是公司开发者账号（CHUMMI PTE. LTD）的 Team profile，有效期一年，不是 7 天的个人签名。
4. `GHMonitor/build/GHMonitor.ipa` 也可用 Xcode > Devices 或 Apple Configurator 拖进去装。

## 使用

- 打开 App 自动扫描：2.5 s 内看到 `GH-XIAO` 就连它（只监听，板子自己配置和启动采样）；否则连 `GHealth_Device`（EVK 的 S5 拨到 BLE，LED1 闪）并下发配置开始采样。**同一时间只能有一个设备连 EVK**，Mac 上的 `tools/vitals.py` 要先关掉。
- 顶部两个胶囊：连接状态（绿=已连并采样）、佩戴状态（硬件 ADT 事件 + 活体检测 + 光信号判断）。
- 心率：默认显示汇顶算法值。App 同时对原始绿光波形做频谱估算脉率（含次谐波校验）；当估算质量 ≥0.45 且算法值与它相差 1.6 倍以上（典型是算法锁到 ½ 或 2 倍频），主数字自动改用波形脉率并做平滑，下方橙色小字 "from PPG · sensor 34" 说明来源和算法原值；设备页可看两者。Zone 按 190 最大心率的百分比。
- 血氧：此 EVK 固件的置信度恒为 0（旧版算法），看 % 和 DeviceSheet 里的 R/等级。
- 呼吸率：从 PPG 基线呼吸调制估算，需 60 s 数据；RHR：本次会话最低的 60 s 平均；皮温：EVK 模组无 NTC，显示 "--"。
- HRV：汇顶 HRV 功能每秒给出最近 1 s 内的 RR 间期（ms）和置信度（文档：0 不可信 / 25 低 / 75 高 / 100 可信，实际输出 20/30/60/80）。25 Hz PPG 的 RR 间期在低置信度时抖动 ±100~200 ms，全部拿来算 RMSSD 会得到 200+ ms 的假值，所以 App 只收置信度 ≥ 60 的输出，丢掉算法在没有新有效心跳的秒里重复发的上一条，做 300~2000 ms 和 ±20 % 中位数的常规伪迹剔除，5 分钟窗口内攒够 30 个 RR 间期才显示（之前显示 "collecting…"），RMSSD 只对相邻心跳配对。设备页有 "HRV RR intervals" 一行显示置信度和接收/拒绝计数。裸模组没绑紧、或者在动的时候，高置信度输出很少，HRV 会一直 collecting，这是正常的。
- 运动数据：连的是 `GH-XIAO`（`firmware/gh3x2x_xiao`）时，每一帧数据里就带 XIAO 板载 LSM6DS3 的三轴加速度（25 Hz，512 LSB/g），这也正是板上汇顶算法拿来抗运动干扰的那份数据；App 直接用它显示顶部第三个胶囊 Still / Moving / Active，设备页"Motion sensor"显示来源、采样率和实时 g 值，大幅运动时暂停 RHR/HRV 统计。这种情况下心率只显示汇顶算法值，不再做 App 侧波形纠偏（算法已有运动参考）。连的是原 EVK（ACC 恒 0）时，帧里的零不算运动数据，App 退回去找第二块板 `XIAO-IMU`（`firmware/xiao_imu`，50 Hz 六轴）；两者都没有胶囊显示 "IMU —"。
- 心率纠偏只在 EVK 路线生效：EVK2 固件的算法没有 ACC，会锁到 ½ 倍频，App 用绿光波形频谱交叉校验后改显示波形脉率并标 "from PPG · sensor 34"。
- 后台：勾了 bluetooth-central，切到后台连接保持、数据继续累积。

## 修改

- 改界面：`Sources/Views/*`；改指标算法：`Sources/Model/*`；换传感器配置：替换 `Resources/evk_config.ini`（GHTestTool 保存的 ini 直接可用），并在 `EVKManager.functionsToStart` 调整要启动的功能。
- 改完 `project.yml` 要重新 `xcodegen generate`。
- 协议/解压器改动后可用 `tools/evk_ble.py` 抓的 `data/raw_dump1.txt` 做离线对比（见对话记录里的 swifttest 方法）。
