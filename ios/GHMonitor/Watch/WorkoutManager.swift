import Foundation
import HealthKit
import WatchConnectivity

/// Runs an HKWorkoutSession so the watch samples heart rate continuously (Apple writes a sample every ~5 s during a
/// workout; there is no public API for beat-to-beat or raw PPG), logs every sample to a CSV and ships the files to the
/// iPhone app when the session ends.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    @Published var authorized = false
    @Published var running = false
    @Published var heartRate: Double?
    @Published var heartRateAt: Date?
    @Published var hrSamples = 0
    @Published var hrHistory: [Double] = []
    @Published var startedAt: Date?
    @Published var status = "Idle"
    @Published var lastTransfer = ""

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var hrQuery: HKAnchoredObjectQuery?
    private var hrFile: FileHandle?
    private var hrURL: URL?
    private var motionURLs: [URL] = []

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { status = "HealthKit unavailable"; return }
        let read: Set<HKObjectType> = [HKObjectType.quantityType(forIdentifier: .heartRate)!]
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        store.requestAuthorization(toShare: share, read: read) { ok, err in
            Task { @MainActor in
                self.authorized = ok
                self.status = ok ? "Ready" : "Health access denied: \(err?.localizedDescription ?? "")"
            }
        }
    }

    func start(motionFiles: @escaping () -> [URL]) {
        guard !running else { return }
        let cfg = HKWorkoutConfiguration()
        cfg.activityType = .other
        cfg.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: cfg)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: cfg)
            s.delegate = self
            b.delegate = self
            session = s; builder = b
            let now = Date()
            s.startActivity(with: now)
            b.beginCollection(withStart: now) { _, _ in }
            startedAt = now
            running = true
            hrSamples = 0
            hrHistory = []
            status = "Workout running"
            openHRFile(now)
            startHRQuery(from: now)
        } catch {
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop(motionFiles: [URL]) {
        guard running else { return }
        running = false
        status = "Stopping…"
        if let q = hrQuery { store.stop(q); hrQuery = nil }
        session?.end()
        builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.builder?.finishWorkout { _, _ in
                Task { @MainActor in
                    self?.session = nil; self?.builder = nil
                    self?.status = "Stopped"
                }
            }
        }
        try? hrFile?.close(); hrFile = nil
        var files = motionFiles
        if let u = hrURL { files.append(u) }
        transfer(files)
    }

    // MARK: - HR logging
    private func openHRFile(_ start: Date) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch_hr_\(f.string(from: start)).csv")
        try? "time,unix_s,bpm,source\n".write(to: url, atomically: true, encoding: .utf8)
        hrURL = url
        hrFile = try? FileHandle(forWritingTo: url)
        hrFile?.seekToEndOfFile()
    }

    private func logHR(_ bpm: Double, at date: Date, source: String) {
        heartRate = bpm; heartRateAt = date; hrSamples += 1
        hrHistory.append(bpm); if hrHistory.count > 120 { hrHistory.removeFirst() }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(iso.string(from: date)),\(String(format: "%.3f", date.timeIntervalSince1970)),\(String(format: "%.1f", bpm)),\(source)\n"
        hrFile?.write(line.data(using: .utf8)!)
    }

    /// Every heart-rate sample HealthKit writes during the workout (the live builder only exposes the latest statistic).
    private func startHRQuery(from start: Date) {
        let type = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
            Task { @MainActor in
                for s in samples.sorted(by: { $0.startDate < $1.startDate }) {
                    let bpm = s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    self?.logHR(bpm, at: s.startDate, source: "healthkit")
                }
            }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: pred, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler
        store.execute(q)
        hrQuery = q
    }

    // MARK: - Transfer to iPhone
    func transfer(_ urls: [URL]) {
        guard WCSession.isSupported() else { lastTransfer = "WCSession unsupported"; return }
        let s = WCSession.default
        guard s.activationState == .activated else { lastTransfer = "iPhone link not active"; return }
        for u in urls {
            s.transferFile(u, metadata: ["name": u.lastPathComponent, "kind": "watch-recording"])
        }
        lastTransfer = "Sending \(urls.count) file(s) to iPhone…"
    }

    func pendingFiles() -> [URL] {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "csv" }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Session error: \(error.localizedDescription)" }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        guard collectedTypes.contains(hrType), let stats = workoutBuilder.statistics(for: hrType),
              let q = stats.mostRecentQuantity() else { return }
        let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let when = stats.mostRecentQuantityDateInterval()?.start ?? Date()
        Task { @MainActor in
            // the anchored query logs every sample; this just keeps the display fresh
            if self.heartRateAt == nil || when > self.heartRateAt! { self.heartRate = bpm; self.heartRateAt = when }
        }
    }
}

extension WorkoutManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        Task { @MainActor in
            self.lastTransfer = error == nil ? "Sent \(fileTransfer.file.fileURL.lastPathComponent)" : "Transfer failed: \(error!.localizedDescription)"
            if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
        }
    }
}
