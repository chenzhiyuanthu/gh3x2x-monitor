import SwiftUI

/// Connection details, discovered sensors, firmware versions and the protocol log.
struct DeviceSheet: View {
    @EnvironmentObject var evk: EVKManager
    @EnvironmentObject var store: VitalsStore
    @EnvironmentObject var imu: IMUManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Sensor") {
                    row("Status", evk.state.label)
                    if let r = evk.rssi { row("Signal", "\(r) dBm") }
                    if !evk.firmwareVersion.isEmpty { row("Firmware", evk.firmwareVersion) }
                    if !evk.driverVersion.isEmpty { row("Driver", evk.driverVersion) }
                    if !evk.chipVersion.isEmpty { row("Chip", evk.chipVersion) }
                    row("Wear", store.wear.label)
                    row("Packets / frames", "\(evk.packets) / \(store.frames)")
                    row("Dropped frames", "\(store.droppedFrames)")
                    row("CRC errors", "\(evk.crcErrors)")
                    if !store.lastRaw.isEmpty {
                        row("Green PPG raw", store.lastRaw.map { $0.formatted() }.joined(separator: "  "))
                        row("Gain / LED mA", zip(store.lastGain, store.lastCurrent).map { "g\($0) \($1)mA" }.joined(separator: "  "))
                    }
                    if let a = store.sensorHeartRate { row("Sensor algorithm HR", "\(a) bpm  (conf \(store.heartRateConfidence))") }
                    if let e = store.ppgPulseEstimate { row("PPG waveform HR", "\(e) bpm  (q \(String(format: "%.2f", store.ppgQuality)))") }
                    row("Displayed HR source", store.heartRateSource == .waveform ? "PPG waveform (sensor off by ~2x)" : "sensor algorithm")
                    if let r = store.spo2RValue { row("SpO₂ R value / level", String(format: "%.3f / %d", r, store.spo2Level)) }
                    if !store.respiratoryDetail.isEmpty {
                        row("Respiratory rate", "\(store.respiratoryWindows) windows · \(store.respiratoryDetail)")
                    }
                    if store.hrvSeenBeats > 0 {
                        row("HRV RR intervals", "conf \(store.hrvSensorConfidence) · \(store.hrvAcceptedBeats) in window / \(store.hrvSeenBeats) seen / \(store.hrvRejectedBeats) rejected · need \(VitalsStore.hrvMinBeats)")
                    }
                }
                Section {
                    Button("Restart sampling") { evk.restartSampling() }
                        .disabled(!evk.state.isStreaming)
                    Button("Reset session statistics") { store.resetSession() }
                    if case .streaming = evk.state {
                        Button("Disconnect", role: .destructive) { evk.disconnect() }
                    } else {
                        Button("Scan & connect") { evk.reconnect() }
                    }
                }
                Section("Motion sensor") {
                    row("Source", store.motionSource.label)
                    if store.frameAccActive {
                        row("Status", "ACC carried in the sensor frames — the on-board Goodix algorithm uses it")
                        row("Sample rate", String(format: "%.0f Hz · 3-axis · 512 LSB/g", store.frameAccRate))
                        if let s = store.lastFrameAcc {
                            row("Accel (g)", String(format: "%.2f %.2f %.2f  |a| %.2f", s.ax, s.ay, s.az, s.magnitude))
                        }
                        row("Motion", String(format: "%@ · %.0f mg", store.motionState.label, store.motionLevel))
                    } else if imu.state != .streaming {
                        row("XIAO-IMU", imu.state.label)
                    }
                    if imu.state == .streaming, !store.frameAccActive {
                        row("XIAO-IMU", imu.state.label)
                        row("Sample rate", String(format: "%.0f Hz · %d packets · %d lost", imu.sampleRate, imu.packets, imu.lostPackets))
                        if let s = imu.lastSample {
                            row("Accel (g)", String(format: "%.2f %.2f %.2f  |a| %.2f", s.ax, s.ay, s.az, s.magnitude))
                            row("Gyro (dps)", String(format: "%.0f %.0f %.0f", s.gx, s.gy, s.gz))
                        }
                        row("Motion", String(format: "%@ · %.0f mg · %.0f dps", store.motionState.label, store.motionLevel, store.gyroLevel))
                    }
                    if imu.state == .streaming {
                        Button("Disconnect XIAO-IMU") { imu.disconnect() }
                    } else if !store.frameAccActive {
                        Button("Connect XIAO-IMU") { imu.reconnect() }
                    }
                }
                Section("Nearby sensors") {
                    if evk.discovered.isEmpty {
                        Text("Searching for GHealth_Device…").foregroundStyle(.secondary)
                    }
                    ForEach(evk.discovered) { d in
                        Button {
                            evk.connect(to: d.id)
                        } label: {
                            HStack {
                                Text(d.name.isEmpty ? d.id.uuidString : d.name)
                                Spacer()
                                Text("\(d.rssi) dBm").foregroundStyle(.secondary).font(.footnote.monospacedDigit())
                            }
                        }
                    }
                }
                Section("Log") {
                    ForEach(Array(evk.log.suffix(60).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
        }
    }
}
