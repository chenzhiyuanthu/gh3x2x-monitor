import Foundation
import CoreMotion

/// High-rate 6-axis motion from the watch's IMU, logged to CSV.
/// Apple Watch Series 8 / Ultra and later (watchOS 10+): CMBatchedSensorManager, 200 Hz device motion (fused
/// 6-axis) and optionally 800 Hz raw accelerometer — only while a workout session is running.
/// Older watches (this Series 6 included): CMMotionManager device motion at 100 Hz.
@MainActor
final class MotionRecorder: ObservableObject {
    @Published var recording = false
    @Published var mode = "—"
    @Published var rateHz: Double = 0
    @Published var samples = 0
    @Published var accelMag: Double = 0       // g (user + gravity)
    @Published var gyroMag: Double = 0        // deg/s
    @Published var accelHistory: [Double] = []
    @Published var gyroHistory: [Double] = []
    @Published var want800HzAccel = false

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let io = DispatchQueue(label: "motion.io")
    private var dmFile: FileHandle?
    private var accFile: FileHandle?
    private var buffer = ""
    private var accBuffer = ""
    private var lastFlush = Date()
    private var files: [URL] = []
    private var rateWindow: [Double] = []
    private var batchedTask: Task<Void, Never>?
    private var accelTask: Task<Void, Never>?
    /// device-motion timestamps are seconds since boot; convert to unix time
    private let bootUnix = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    var recordedFiles: [URL] { files }

    func start() {
        guard !recording else { return }
        files = []
        samples = 0; rateWindow = []; accelHistory = []; gyroHistory = []
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = f.string(from: Date())
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dmURL = dir.appendingPathComponent("watch_motion_\(stamp).csv")
        try? "unix_s,user_ax_g,user_ay_g,user_az_g,grav_x_g,grav_y_g,grav_z_g,gyro_x_dps,gyro_y_dps,gyro_z_dps,roll,pitch,yaw\n"
            .write(to: dmURL, atomically: true, encoding: .utf8)
        dmFile = try? FileHandle(forWritingTo: dmURL); dmFile?.seekToEndOfFile()
        files.append(dmURL)
        recording = true

        if #available(watchOS 10.0, *), CMBatchedSensorManager.isDeviceMotionSupported {
            mode = "batched 200 Hz"
            let bm = CMBatchedSensorManager()
            batchedTask = Task { [weak self] in
                do {
                    for try await batch in bm.deviceMotionUpdates() {
                        guard let self, self.recording else { break }
                        for dm in batch { self.handle(dm) }
                    }
                } catch {
                    await MainActor.run { self?.mode = "batched failed: \(error.localizedDescription)" }
                }
            }
            if want800HzAccel, CMBatchedSensorManager.isAccelerometerSupported {
                let accURL = dir.appendingPathComponent("watch_accel800_\(stamp).csv")
                try? "unix_s,ax_g,ay_g,az_g\n".write(to: accURL, atomically: true, encoding: .utf8)
                accFile = try? FileHandle(forWritingTo: accURL); accFile?.seekToEndOfFile()
                files.append(accURL)
                accelTask = Task { [weak self] in
                    do {
                        for try await batch in bm.accelerometerUpdates() {
                            guard let self, self.recording else { break }
                            var s = ""
                            for a in batch {
                                s += String(format: "%.4f,%.4f,%.4f,%.4f\n", self.bootUnix + a.timestamp,
                                            a.acceleration.x, a.acceleration.y, a.acceleration.z)
                            }
                            let data = s
                            self.io.async { self.accFile?.write(data.data(using: .utf8)!) }
                        }
                    } catch {}
                }
            }
        } else {
            mode = "CMMotionManager 100 Hz"
            manager.deviceMotionUpdateInterval = 1.0 / 100.0
            queue.maxConcurrentOperationCount = 1
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
                guard let dm, let self else { return }
                Task { @MainActor in self.handle(dm) }
            }
        }
    }

    func stop() -> [URL] {
        guard recording else { return files }
        recording = false
        batchedTask?.cancel(); accelTask?.cancel()
        manager.stopDeviceMotionUpdates()
        flush(force: true)
        io.sync {
            try? self.dmFile?.close(); self.dmFile = nil
            try? self.accFile?.close(); self.accFile = nil
        }
        mode = "stopped"
        return files
    }

    private func handle(_ dm: CMDeviceMotion) {
        let t = bootUnix + dm.timestamp
        let ua = dm.userAcceleration, g = dm.gravity, r = dm.rotationRate, att = dm.attitude
        let toDeg = 180 / Double.pi
        buffer += String(format: "%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f\n", t,
                         ua.x, ua.y, ua.z, g.x, g.y, g.z, r.x * toDeg, r.y * toDeg, r.z * toDeg, att.roll, att.pitch, att.yaw)
        samples += 1
        rateWindow.append(t)
        if rateWindow.count > 400 { rateWindow.removeFirst(rateWindow.count - 400) }
        if samples % 10 == 0 {
            accelMag = ((ua.x + g.x) * (ua.x + g.x) + (ua.y + g.y) * (ua.y + g.y) + (ua.z + g.z) * (ua.z + g.z)).squareRoot()
            gyroMag = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * toDeg
            accelHistory.append(accelMag); if accelHistory.count > 60 { accelHistory.removeFirst() }
            gyroHistory.append(gyroMag); if gyroHistory.count > 60 { gyroHistory.removeFirst() }
            if rateWindow.count > 20, let a = rateWindow.first, let b = rateWindow.last, b > a {
                rateHz = Double(rateWindow.count - 1) / (b - a)
            }
        }
        flush(force: false)
    }

    private func flush(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastFlush) > 0.5 || buffer.count > 16_000 else { return }
        lastFlush = now
        let data = buffer; buffer = ""
        guard !data.isEmpty else { return }
        io.async { self.dmFile?.write(data.data(using: .utf8)!) }
    }
}
