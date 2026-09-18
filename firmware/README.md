# firmware/xiao_imu — XIAO nRF52840 Sense 六轴 IMU 蓝牙上报

给 GH Monitor App 提供运动数据（EVK2 固件不读板上的加速度计，ACC 恒为 0）。

- 板子：Seeed XIAO nRF52840 Sense（LSM6DS3TR-C 六轴），Arduino 核心 `Seeeduino:mbed:xiaonRF52840Sense`，库 `ArduinoBLE` + `Seeed Arduino LSM6DS3`。
- 广播名 `XIAO-IMU`，服务 `7A1D0001-2B7E-4C9B-9E2F-3C1A0D5E6F70`，notify 特征 `7A1D0002-...`。
- 包格式（小端）：`u8 seq, u8 n(=8), u16 t_ms, n×{i16 ax,ay,az,gx,gy,gz}`，原始 LSB；加速度 ±4 g → 0.122 mg/LSB，陀螺 ±500 dps → 17.5 mdps/LSB；50 Hz 采样，每 160 ms 一包（100 字节）。
- 板载 LED：连上手机后常亮。

编译/烧录（USB 接 Mac，端口一般是 `/dev/cu.usbmodem2101`）：
```
cd firmware/xiao_imu
arduino-cli compile --fqbn Seeeduino:mbed:xiaonRF52840Sense .
arduino-cli upload  --fqbn Seeeduino:mbed:xiaonRF52840Sense -p /dev/cu.usbmodem2101 .
```
使用：XIAO 用充电宝/锂电池供电，和 EVK 光路模组绑在同一只手腕上；App 会自动连它（顶部第三个胶囊显示 Still / Moving / Active）。
