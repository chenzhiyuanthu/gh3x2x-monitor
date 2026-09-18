import Foundation

/// Synthetic data for layout checks in the simulator (`--demo` launch argument). Not used on a real device.
enum DemoFeed {
    @MainActor
    static func start(store: VitalsStore) {
        store.sessionStart = Date()
        var t = 0.0
        var phase = 0.0
        // seed a few minutes of history
        let now = Date()
        for s in stride(from: -240.0, through: 0, by: 1) {
            store.hrHistory.append(HRPoint(time: now.addingTimeInterval(s), bpm: 54 + 3 * sin(s / 40)))
        }
        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
          MainActor.assumeIsolated {
            t += 0.04
            phase += 0.04 * 2 * Double.pi * 0.9
            let bpm = 54 + Int((3 * sin(t / 40)).rounded())
            store.heartRate = bpm
            store.sensorHeartRate = bpm
            store.heartRateSource = .sensor
            store.heartRateConfidence = 96
            store.heartRateUpdated = Date()
            store.spo2 = 95 + Int(t / 30) % 3
            store.spo2Confidence = 0
            store.spo2Level = 5
            store.spo2RValue = 0.487
            store.respiratoryRate = 16.5
            store.restingHeartRate = 54
            store.hrv = 49
            store.wear = .onWrist
            store.signalOK = true
            store.ppgQuality = 0.9
            store.ppgPulseEstimate = bpm
            store.lastRaw = [13_062_914, 13_088_697, 11_120_936, 11_634_766]
            store.lastGain = [5, 5, 5, 3]
            store.lastCurrent = [24, 24, 24, 24]
            store.frames += 1
            if Int(t) % 1 == 0, store.hrHistory.last.map({ Date().timeIntervalSince($0.time) >= 1 }) ?? true {
                store.hrHistory.append(HRPoint(time: Date(), bpm: Double(bpm)))
            }
            var wave = store.ppgWave
            wave.append(40_000 * max(0, sin(phase)) * (1 - 0.3 * max(0, sin(2 * phase))) - 12_000)
            if wave.count > 150 { wave.removeFirst(wave.count - 150) }
            store.ppgWave = wave
          }
        }
    }
}
