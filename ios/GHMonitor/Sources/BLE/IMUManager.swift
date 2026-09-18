import Foundation
import CoreBluetooth
import Combine

struct IMUSample {
    let t: TimeInterval          // seconds since session start (host clock)
    let ax: Double, ay: Double, az: Double   // g
    let gx: Double, gy: Double, gz: Double   // dps
    var magnitude: Double { (ax * ax + ay * ay + az * az).squareRoot() }
    var gyroMagnitude: Double { (gx * gx + gy * gy + gz * gz).squareRoot() }
}

/// Connects to the XIAO nRF52840 Sense running firmware/xiao_imu and streams 6-axis samples (50 Hz).
@MainActor
final class IMUManager: NSObject, ObservableObject {
    enum State: Equatable {
        case off, scanning, connecting, streaming, disconnected
        var label: String {
            switch self {
            case .off: return "IMU: Bluetooth off"
            case .scanning: return "IMU: searching…"
            case .connecting: return "IMU: connecting…"
            case .streaming: return "IMU: connected"
            case .disconnected: return "IMU: disconnected"
            }
        }
    }

    static let serviceUUID = CBUUID(string: "7A1D0001-2B7E-4C9B-9E2F-3C1A0D5E6F70")
    static let dataUUID = CBUUID(string: "7A1D0002-2B7E-4C9B-9E2F-3C1A0D5E6F70")
    static let deviceName = "XIAO-IMU"
    static let accelScale = 0.122 / 1000.0   // g per LSB at ±4 g
    static let gyroScale = 17.5 / 1000.0     // dps per LSB at ±500 dps

    @Published private(set) var state: State = .scanning
    @Published private(set) var packets = 0
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var lastSample: IMUSample?
    @Published private(set) var lostPackets = 0
    @Published var enabled = true

    var onSamples: (([IMUSample]) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var lastSeq: UInt8?
    private var rateWindow: [Date] = []
    private let t0 = Date()
    private var reconnectTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScanning() {
        guard enabled, central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        // Also catch it by name in case the service UUID is not in the advertisement.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func reconnect() {
        enabled = true
        if let p = peripheral, p.state == .connected { return }
        startScanning()
    }

    func disconnect() {
        enabled = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        central.stopScan()
        state = .disconnected
    }

    private func handle(_ data: Data) {
        guard data.count >= 4 else { return }
        let b = [UInt8](data)
        let seq = b[0]
        let n = Int(b[1])
        guard data.count >= 4 + n * 12 else { return }
        if let last = lastSeq {
            let gap = Int(seq &- last)
            if gap > 1 { lostPackets += gap - 1 }
        }
        lastSeq = seq
        packets += 1
        let now = Date()
        rateWindow.append(now)
        rateWindow.removeAll { now.timeIntervalSince($0) > 2 }
        if rateWindow.count > 2 { sampleRate = Double(rateWindow.count * n) / 2.0 }

        var samples: [IMUSample] = []
        samples.reserveCapacity(n)
        let tEnd = now.timeIntervalSince(t0)
        for i in 0..<n {
            let o = 4 + i * 12
            func i16(_ k: Int) -> Double { Double(Int16(bitPattern: UInt16(b[o + k]) | UInt16(b[o + k + 1]) << 8)) }
            // spread the samples backwards from "now" at 50 Hz
            let t = tEnd - Double(n - 1 - i) * 0.02
            samples.append(IMUSample(t: t,
                                     ax: i16(0) * Self.accelScale, ay: i16(2) * Self.accelScale, az: i16(4) * Self.accelScale,
                                     gx: i16(6) * Self.gyroScale, gy: i16(8) * Self.gyroScale, gz: i16(10) * Self.gyroScale))
        }
        lastSample = samples.last
        onSamples?(samples)
    }

    private func scheduleReconnect() {
        guard enabled else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.enabled else { return }
            if let p = self.peripheral { self.state = .connecting; self.central.connect(p, options: nil) } else { self.startScanning() }
        }
    }
}

extension IMUManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: startScanning()
            case .poweredOff: state = .off
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            guard name == Self.deviceName || services.contains(Self.serviceUUID) else { return }
            guard case .scanning = state else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { peripheral.discoverServices([Self.serviceUUID]) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { state = .disconnected; scheduleReconnect() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            dataChar = nil
            lastSeq = nil
            state = .disconnected
            scheduleReconnect()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in peripheral.services ?? [] where s.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.dataUUID], for: s)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] where c.uuid == Self.dataUUID {
                dataChar = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if error == nil, characteristic.isNotifying { state = .streaming }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.dataUUID, let d = characteristic.value else { return }
            handle(d)
        }
    }
}
