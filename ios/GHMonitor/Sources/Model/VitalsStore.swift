import Foundation
import Combine

struct HRPoint: Identifiable {
    let id = UUID()
    let time: Date
    let bpm: Double
}

enum HeartRateSource: Equatable {
    case none
    case sensor          // on-board algorithm, agrees with the waveform (or waveform unavailable)
    case waveform        // on-board algorithm was off by ~2x, showing the PPG-derived rate instead
}

enum MotionState: Equatable {
    case unknown, still, light, active
    var label: String {
        switch self {
        case .unknown: return "IMU —"
        case .still: return "Still"
        case .light: return "Moving"
        case .active: return "Active"
        }
    }
}

enum MotionSource: Equatable {
    case none
    case xiaoIMU          // separate XIAO-IMU board streaming 6-axis over BLE (firmware/xiao_imu)
    case sensorFrames     // ACC embedded in the sensor's data frames: the samples the on-board Goodix algorithm consumes
    var label: String {
        switch self {
        case .none: return "none"
        case .xiaoIMU: return "XIAO-IMU (BLE, 50 Hz 6-axis)"
        case .sensorFrames: return "On-board ACC in sensor frames"
        }
    }
}

enum WearState: Equatable {
    case unknown
    case onWrist
    case offWrist
    case noContact
    case notLiving

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .onWrist: return "On wrist"
        case .offWrist: return "Off wrist"
        case .noContact: return "No skin contact"
        case .notLiving: return "Not on skin"
        }
    }
    var isWorn: Bool { self == .onWrist }
}

/// Reference range shown in the green "within …" pills.
struct MetricRange {
    let low: Double
    let high: Double
    let format: (Double) -> String
    func contains(_ v: Double) -> Bool { v >= low && v <= high }
    var text: String { "\(format(low)) - \(format(high))" }
}

/// Aggregates decoded sensor frames into the values shown on screen.
@MainActor
final class VitalsStore: ObservableObject {
    // Live values
    @Published var heartRate: Int?                 // displayed value (sensor algorithm, corrected by the PPG waveform when it is clearly off)
    @Published var sensorHeartRate: Int?           // raw value from the on-board Goodix algorithm
    @Published var heartRateSource: HeartRateSource = .none
    @Published var heartRateConfidence: Int = 0
    @Published var heartRateUpdated: Date?
    @Published var spo2: Int?
    @Published var spo2Confidence: Int = 0
    @Published var spo2Level: Int = 0
    @Published var spo2RValue: Double?
    @Published var spo2Updated: Date?
    @Published var hrv: Double?                 // RMSSD ms (from sensor RR intervals)
    @Published var hrvSensorConfidence: Int = 0
    @Published var respiratoryRate: Double?     // rpm (estimated from PPG)
    @Published var respiratoryQuality: Double = 0
    @Published var restingHeartRate: Int?
    @Published var skinTempDelta: Double?       // no NTC on the EVK PD/LED module
    @Published var wear: WearState = .unknown
    @Published var livingConfidence: Int?

    // Motion: from the ACC carried in the sensor frames (GH-XIAO) or, failing that, a separate XIAO-IMU stream
    @Published var motionState: MotionState = .unknown
    @Published private(set) var frameAccActive = false      // frames carried a non-zero ACC in the last few seconds
    @Published private(set) var frameAccRate: Double = 0    // Hz, measured
    @Published private(set) var lastFrameAcc: IMUSample?
    @Published var motionLevel: Double = 0          // mg (std of |a| over 2 s)
    @Published var gyroLevel: Double = 0            // dps (mean |ω| over 2 s)
    @Published var motionAffected = false           // HR value produced while moving
    weak var imu: IMUManager?

    // Signal / diagnostics
    @Published var ppgPulseEstimate: Int?
    @Published var ppgQuality: Double = 0
    @Published var signalOK = false
    @Published var hrHistory: [HRPoint] = []
    @Published var ppgWave: [Double] = []        // last ~6 s of green channel AC for a sparkline
    @Published var frames = 0
    @Published var droppedFrames = 0
    @Published var sessionStart: Date?
    @Published var lastRaw: [UInt32] = []
    @Published var lastGain: [Int] = []
    @Published var lastCurrent: [Int] = []

    // Config
    var maxHeartRate: Double = 190

    private var ppgBuffer: [Double] = []         // green ch0, 25 Hz, ~70 s
    private var rri: [Double] = []               // ms, last ~2 min
    private var lastFrameId: [Int: UInt8] = [:]
    private var lastHRHistoryAt: Date = .distantPast
    private var lastAnalysisAt: Date = .distantPast
    private var rhrWindow: [(Date, Int)] = []
    private var hardwareWear: WearState?
    private var softWear: WearState?
    private var smoothedHR: Double?
    private var lastReconcileAt: Date = .distantPast
    private var accBuffer: [IMUSample] = []          // ~70 s
    private var lastMotionAt: Date = .distantPast
    private var lastMovementAt: Date?                // last time the arm moved (for wear heuristics)
    private var accSourceFunction: Int?              // which function's frames supply the ACC (all carry the same sample)
    private var lastFrameAccAt: Date = .distantPast
    private var frameAccTimes: [Date] = []

    var motionSource: MotionSource {
        if frameAccActive { return .sensorFrames }
        if imu?.state == .streaming { return .xiaoIMU }
        return .none
    }
    var imuAvailable: Bool { motionSource != .none }
    private var accSampleRate: Double { motionSource == .sensorFrames ? 25 : 50 }

    /// Samples from the separate XIAO-IMU board. Ignored while the sensor frames themselves carry an ACC.
    func ingestIMU(_ samples: [IMUSample]) {
        guard !frameAccActive else { return }
        appendMotion(samples)
    }

    /// ACC embedded in a sensor frame (512 LSB/g, one sample per 25 Hz frame). The EVK2 firmware sends zeros —
    /// those never count as a motion reference.
    private func ingestFrameAcc(_ f: SensorFrame) {
        guard let g = f.gsensor, g.0 != 0 || g.1 != 0 || g.2 != 0 else { return }
        let now = Date()
        if accSourceFunction == nil || (f.function != accSourceFunction && now.timeIntervalSince(lastFrameAccAt) > 3) {
            accSourceFunction = f.function
        }
        guard f.function == accSourceFunction else { return }
        lastFrameAccAt = now
        if !frameAccActive { frameAccActive = true; accBuffer.removeAll() }
        frameAccTimes.append(now)
        frameAccTimes.removeAll { now.timeIntervalSince($0) > 2 }
        frameAccRate = Double(frameAccTimes.count) / 2
        let s = IMUSample(t: now.timeIntervalSince(sessionStart ?? now),
                          ax: Double(g.0) / 512, ay: Double(g.1) / 512, az: Double(g.2) / 512, gx: 0, gy: 0, gz: 0)
        lastFrameAcc = s
        appendMotion([s])
    }

    private func appendMotion(_ samples: [IMUSample]) {
        accBuffer.append(contentsOf: samples)
        if accBuffer.count > 50 * 70 { accBuffer.removeFirst(accBuffer.count - 50 * 70) }
        let now = Date()
        guard now.timeIntervalSince(lastMotionAt) >= 0.5 else { return }
        lastMotionAt = now
        let tEnd = accBuffer.last?.t ?? 0
        let recent = accBuffer.drop(while: { $0.t < tEnd - 2 })   // last 2 s regardless of sample rate
        motionLevel = SignalProcessing.motionLevel(magnitude: recent.map(\.magnitude))
        gyroLevel = recent.isEmpty ? 0 : recent.map(\.gyroMagnitude).reduce(0, +) / Double(recent.count)
        // The on-board ACC is 512 LSB/g (≈2 mg steps) vs 0.122 mg on the XIAO-IMU, so allow a little more noise at rest
        let stillLimit: Double = motionSource == .sensorFrames ? 20 : 12
        let newState: MotionState
        if motionLevel < stillLimit && gyroLevel < 8 { newState = .still }
        else if motionLevel < 70 && gyroLevel < 60 { newState = .light }
        else { newState = .active }
        if newState != .still { lastMovementAt = now }
        motionState = newState
    }

    private var motionWeight: Double {
        guard imuAvailable else { return 0 }
        return min(1, max(0, (motionLevel - 12) / 60))
    }

    /// Decide what to show: the sensor's algorithm value, unless the PPG waveform (independent DFT estimate)
    /// says it is off by ~2x (sub-/super-harmonic lock), in which case the waveform rate is used.
    private func reconcileHeartRate() {
        let now = Date()
        guard now.timeIntervalSince(lastReconcileAt) >= 0.5 else { return }
        lastReconcileAt = now
        var candidate: Double?
        var source: HeartRateSource = .none
        let estOK = ppgPulseEstimate != nil && ppgQuality >= 0.45
        if let algo = sensorHeartRate {
            // With the ACC reaching the on-board algorithm (GH-XIAO) it handles motion itself; the waveform
            // cross-check only covers the EVK2 firmware, whose algorithm runs blind (ACC = 0) and can lock at ½×.
            if estOK, motionSource != .sensorFrames, let est = ppgPulseEstimate {
                let ratio = Double(algo) / Double(est)
                if ratio < 0.62 || ratio > 1.6 {
                    candidate = Double(est); source = .waveform
                } else {
                    candidate = Double(algo); source = .sensor
                }
            } else {
                candidate = Double(algo); source = .sensor
            }
        } else if estOK, let est = ppgPulseEstimate, ppgQuality >= 0.6 {
            candidate = Double(est); source = .waveform
        }
        guard let c = candidate else { return }
        // light smoothing so the number does not jump when the source switches
        if let prev = smoothedHR, abs(prev - c) < 25 {
            smoothedHR = prev * 0.6 + c * 0.4
        } else {
            smoothedHR = c
        }
        let shown = Int(smoothedHR!.rounded())
        heartRate = shown
        heartRateSource = source
        recordHR(shown, confidence: source == .waveform ? Int(ppgQuality * 100) : heartRateConfidence)
    }

    var sessionDuration: TimeInterval { sessionStart.map { Date().timeIntervalSince($0) } ?? 0 }

    var zone: Int {
        guard let hr = heartRate else { return 0 }
        let pct = Double(hr) / maxHeartRate
        switch pct {
        case ..<0.5: return 0
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default: return 5
        }
    }

    // Reference ranges (session-adaptive after enough data, sensible defaults before)
    var respiratoryRange: MetricRange { MetricRange(low: 12, high: 20) { String(format: "%.1f", $0) } }
    var spo2Range: MetricRange { MetricRange(low: 95, high: 100) { "\(Int($0))%" } }
    var rhrRange: MetricRange {
        if let r = restingHeartRate { return MetricRange(low: Double(r), high: Double(r + 9)) { "\(Int($0))" } }
        return MetricRange(low: 50, high: 80) { "\(Int($0))" }
    }
    var hrvRange: MetricRange { MetricRange(low: 20, high: 100) { "\(Int($0))" } }
    var tempRange: MetricRange { MetricRange(low: -0.2, high: 0.2) { String(format: "%+.1f", $0) } }

    func resetSession() {
        heartRate = nil; sensorHeartRate = nil; heartRateSource = .none; heartRateConfidence = 0; heartRateUpdated = nil
        smoothedHR = nil
        spo2 = nil; spo2Confidence = 0; spo2Level = 0; spo2RValue = nil; spo2Updated = nil
        hrv = nil; respiratoryRate = nil; respiratoryQuality = 0; restingHeartRate = nil
        wear = .unknown; livingConfidence = nil
        ppgPulseEstimate = nil; ppgQuality = 0; signalOK = false
        hrHistory.removeAll(); ppgWave.removeAll(); frames = 0; droppedFrames = 0
        ppgBuffer.removeAll(); rri.removeAll(); lastFrameId.removeAll(); rhrWindow.removeAll()
        hardwareWear = nil; softWear = nil
        accBuffer.removeAll(); lastMovementAt = nil; motionAffected = false
        frameAccActive = false; frameAccRate = 0; lastFrameAcc = nil; accSourceFunction = nil; frameAccTimes.removeAll()
        motionState = .unknown; motionLevel = 0; gyroLevel = 0
        sessionStart = Date()
    }

    // MARK: - Ingest

    func ingest(_ f: SensorFrame) {
        if sessionStart == nil { sessionStart = Date() }
        frames += 1
        if let last = lastFrameId[f.function] {
            let gap = Int(f.frameId &- last)
            if gap > 1 { droppedFrames += gap - 1 }
        }
        lastFrameId[f.function] = f.frameId
        ingestFrameAcc(f)

        let name = GoodixFunction.name(forOffset: f.function)
        switch name {
        case "HR":
            if let raw = f.raw {
                lastRaw = raw
                lastGain = f.gain
                lastCurrent = f.drv0
                if let g = raw.first {
                    ppgBuffer.append(Double(g))
                    if ppgBuffer.count > 25 * 70 { ppgBuffer.removeFirst(ppgBuffer.count - 25 * 70) }
                }
            }
            if let bpm = f.algo[0], bpm > 0 {
                sensorHeartRate = Int(bpm)
                heartRateConfidence = Int(f.algo[1] ?? 0)
                heartRateUpdated = Date()
                reconcileHeartRate()
            }
        case "SPO2":
            if let v = f.algo[0], v > 0 {
                spo2 = Int(v)
                spo2Confidence = Int(f.algo[2] ?? 0)
                spo2Level = Int(f.algo[3] ?? 0)
                spo2RValue = f.algo[1].map { Double($0) / 10000 }
                spo2Updated = Date()
            }
        case "HRV":
            // snResult[0..3] = RR intervals (ms) produced in the last second, [4] confidence, [5] count
            let count = Int(f.algo[5] ?? 0)
            if count > 0, motionState != .active {
                hrvSensorConfidence = Int(f.algo[4] ?? 0)
                for i in 0..<min(count, 4) {
                    if let v = f.algo[i], v > 250, v < 2500 { rri.append(Double(v)) }
                }
                if rri.count > 150 { rri.removeFirst(rri.count - 150) }
                if let r = SignalProcessing.rmssd(Array(rri.suffix(60))) { hrv = r }
            }
        case "SOFT_ADT_GREEN", "SOFT_ADT_IR":
            if let s = f.algo[0] {
                switch s & 3 {
                case 1: softWear = .onWrist
                case 2: softWear = .offWrist
                case 3: softWear = .notLiving
                default: break
                }
                livingConfidence = f.algo[1].map(Int.init)
            }
        default:
            break
        }
        periodicAnalysis()
        updateWear()
    }

    func ingestEvent(_ irq: UInt16) {
        if irq & GoodixIRQ.wearOn != 0 { hardwareWear = .onWrist }
        if irq & GoodixIRQ.wearOff != 0 { hardwareWear = .offWrist }
        updateWear()
    }

    // MARK: - Derived values

    private func recordHR(_ bpm: Int, confidence: Int) {
        let now = Date()
        if now.timeIntervalSince(lastHRHistoryAt) >= 1 {
            lastHRHistoryAt = now
            hrHistory.append(HRPoint(time: now, bpm: Double(bpm)))
            let cutoff = now.addingTimeInterval(-10 * 60)
            if let idx = hrHistory.firstIndex(where: { $0.time >= cutoff }), idx > 0 { hrHistory.removeFirst(idx) }
        }
        motionAffected = motionState == .active
        // Resting HR: lowest 60-second average with decent confidence, never while moving
        if confidence >= 50, motionState != .active, motionState != .light || !imuAvailable {
            rhrWindow.append((now, bpm))
            rhrWindow.removeAll { now.timeIntervalSince($0.0) > 60 }
            if rhrWindow.count >= 30, now.timeIntervalSince(rhrWindow.first!.0) >= 45 {
                let avg = Int((Double(rhrWindow.map { $0.1 }.reduce(0, +)) / Double(rhrWindow.count)).rounded())
                restingHeartRate = min(restingHeartRate ?? avg, avg)
            }
        }
    }

    private func periodicAnalysis() {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysisAt) >= 1 else { return }
        lastAnalysisAt = now
        if frameAccActive, now.timeIntervalSince(lastFrameAccAt) > 3 {
            frameAccActive = false; frameAccRate = 0; motionState = .unknown
        }
        let accMag: [Double]? = imuAvailable ? accBuffer.suffix(Int(accSampleRate * 10)).map(\.magnitude) : nil
        if let est = SignalProcessing.pulseRate(ppg: ppgBuffer, acc: accMag, accFs: accSampleRate, motionWeight: motionWeight) {
            ppgPulseEstimate = est.peakToPeak > 4000 && est.peakToPeak < 2_000_000 ? est.bpm : nil
            ppgQuality = ppgPulseEstimate == nil ? 0 : est.quality
        }
        if let rr = SignalProcessing.respiratoryRate(ppg: ppgBuffer), rr.quality > 0.15, signalOK {
            respiratoryRate = respiratoryRate.map { 0.8 * $0 + 0.2 * rr.rpm } ?? rr.rpm
            respiratoryQuality = rr.quality
        }
        let ac = SignalProcessing.detrend(Array(ppgBuffer.suffix(25 * 6)), window: 12)
        ppgWave = Array(ac.suffix(25 * 6))
        if sensorHeartRate != nil || ppgQuality >= 0.6 { reconcileHeartRate() }
    }

    private func updateWear() {
        let maxRaw = lastRaw.max() ?? 0
        let contact = maxRaw > (1 << 23) + 300_000
        signalOK = contact && (ppgQuality > 0.25)
        if !contact && !lastRaw.isEmpty {
            wear = .noContact
            return
        }
        if let s = softWear, s != .onWrist { wear = s; return }
        if imuAvailable, let moved = lastMovementAt ?? sessionStart, Date().timeIntervalSince(moved) > 180, ppgQuality < 0.25 {
            wear = .offWrist   // arm has not moved for 3 min and there is no pulse: sensor is lying somewhere
            return
        }
        if let h = hardwareWear { wear = h; return }
        if let s = softWear { wear = s; return }
        if !lastRaw.isEmpty { wear = ppgQuality > 0.25 ? .onWrist : .unknown }
    }
}
