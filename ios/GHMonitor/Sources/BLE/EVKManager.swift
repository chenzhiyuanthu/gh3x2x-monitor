import Foundation
import CoreBluetooth
import Combine

/// Connects to the Goodix GH3x2x EVK over BLE, pushes the sensor configuration, starts sampling
/// and streams decoded frames / chip events to the app.
@MainActor
final class EVKManager: NSObject, ObservableObject {
    enum State: Equatable {
        case bluetoothOff
        case unauthorized
        case scanning
        case connecting(String)
        case configuring(String)
        case streaming(String)
        case disconnected(String?)

        var isStreaming: Bool { if case .streaming = self { return true } else { return false } }
        var label: String {
            switch self {
            case .bluetoothOff: return "Bluetooth off"
            case .unauthorized: return "Bluetooth not allowed"
            case .scanning: return "Searching for sensor…"
            case .connecting(let n): return "Connecting to \(n)…"
            case .configuring(let n): return "Configuring \(n)…"
            case .streaming(let n): return "Connected · \(n)"
            case .disconnected(let n): return n.map { "Disconnected from \($0)" } ?? "Disconnected"
            }
        }
    }

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    static let serviceUUID = CBUUID(string: "0000190E-0000-1000-8000-00805F9B34FB")
    static let txUUID = CBUUID(string: "00000003-0000-1000-8000-00805F9B34FB")   // notify: device -> phone
    static let rxUUID = CBUUID(string: "00000004-0000-1000-8000-00805F9B34FB")   // write:  phone -> device
    static let namePrefix = "GHealth"
    static let xiaoPrefix = "GH-XIAO"       // XIAO nRF52840 running firmware/gh3x2x_xiao (config + algorithms on board)
    static func isSensorName(_ n: String) -> Bool { n.hasPrefix(namePrefix) || n.hasPrefix(xiaoPrefix) }

    @Published private(set) var state: State = .scanning
    @Published private(set) var discovered: [Discovered] = []
    @Published private(set) var rssi: Int?
    @Published private(set) var firmwareVersion = ""
    @Published private(set) var driverVersion = ""
    @Published private(set) var chipVersion = ""
    @Published private(set) var log: [String] = []
    @Published private(set) var packets = 0
    @Published private(set) var crcErrors = 0
    @Published var autoReconnect = true
    /// True for GH-XIAO: the firmware carries its own configuration and starts sampling by itself,
    /// so the app only listens (no work-mode / config push / start).
    @Published private(set) var selfContained = false

    /// Functions to start after configuration. Defaults to everything the bundled config supports.
    var functionsToStart: GoodixFunction = [.adt, .hr, .hrv, .spo2]
    private(set) var activeFunctions: GoodixFunction = []

    var onFrame: ((SensorFrame) -> Void)?
    var onEvent: ((UInt16) -> Void)?
    var onStreamingStarted: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private let parser = GoodixFrameParser()
    private let decoder = RawdataDecoder()
    private var pending: [UInt8: CheckedContinuation<[UInt8], Error>] = [:]
    private var pendingTimeouts: [UInt8: Task<Void, Never>] = [:]
    private var configTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var config: EVKConfig?
    private var lastEventId: UInt8?
    private var notifyRequested = false
    private var scanStartedAt: Date?
    private var discoveredNames: [UUID: String] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        config = EVKConfig.bundled()
        if let c = config {
            appendLog("Config \(c.name): \(c.driverRegs.count) driver regs, \(c.algoRegs.count) algo regs, functions \(c.functionNames.joined(separator: "+"))")
        } else {
            appendLog("⚠️ evk_config.ini missing from bundle")
        }
    }

    // MARK: - Public control

    func startScanning() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        state = .scanning
        scanStartedAt = Date()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        appendLog("Scanning…")
    }

    func connect(to id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        peripheral = p
        p.delegate = self
        let shown = discoveredNames[id] ?? p.name ?? "sensor"
        state = .connecting(shown)
        appendLog("Connecting to \(shown)")
        central.connect(p, options: nil)
    }

    func disconnect() {
        autoReconnect = false
        configTask?.cancel()
        if let p = peripheral {
            if !selfContained {
                Task { try? await self.send(.startCtrl, GoodixProtocol.startPayload(start: false, functions: activeFunctions), timeout: 1.0) }
            }
            central.cancelPeripheralConnection(p)
        }
    }

    func reconnect() {
        autoReconnect = true
        if let p = peripheral, p.state == .connected {
            restartSampling()
        } else {
            startScanning()
        }
    }

    func restartSampling() {
        guard let p = peripheral, p.state == .connected, rxChar != nil else { return }
        configTask?.cancel()
        configTask = Task { await self.configureAndStart() }
    }

    // MARK: - Protocol I/O

    private func write(_ data: Data) {
        guard let p = peripheral, let rx = rxChar else { return }
        let type: CBCharacteristicWriteType = rx.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: rx, type: type)
    }

    /// Send a command and wait for the response frame with the same cmd id.
    @discardableResult
    func send(_ cmd: GoodixCmd, _ payload: [UInt8] = [], timeout: TimeInterval = 2.0) async throws -> [UInt8] {
        guard peripheral?.state == .connected, rxChar != nil else { throw EVKError.notConnected }
        pending[cmd.rawValue]?.resume(throwing: EVKError.superseded)
        pendingTimeouts[cmd.rawValue]?.cancel()
        return try await withCheckedThrowingContinuation { cont in
            pending[cmd.rawValue] = cont
            pendingTimeouts[cmd.rawValue] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if let c = self.pending.removeValue(forKey: cmd.rawValue) {
                    c.resume(throwing: EVKError.timeout(cmd))
                }
            }
            write(GoodixProtocol.build(cmd, payload))
        }
    }

    private func configureAndStart() async {
        guard let p = peripheral, let cfg = config else {
            appendLog("⚠️ no config / peripheral")
            return
        }
        state = .configuring(p.name ?? "sensor")
        decoder.reset()
        do {
            // Versions (informational)
            if let v = try? await send(.getVersion, [0x01]) { firmwareVersion = versionString(v) }
            if let v = try? await send(.getVersion, [0x10]) { driverVersion = versionString(v) }
            if let v = try? await send(.getVersion, [0x11]) { chipVersion = versionString(v) }
            appendLog("FW \(firmwareVersion) / drv \(driverVersion) / chip \(chipVersion)")

            let advName = discoveredNames[p.identifier] ?? p.name ?? ""
            selfContained = advName.hasPrefix(Self.xiaoPrefix) || firmwareVersion.hasPrefix("GH-XIAO")
            if selfContained {
                // GH-XIAO configures the sensor and starts ADT+HR+HRV+SPO2 itself; just listen.
                activeFunctions = [.adt, .hr, .hrv, .spo2]
                state = .streaming(advName.isEmpty ? "sensor" : advName)
                appendLog("GH-XIAO: on-board config/algorithms, listening")
                onStreamingStarted?()
                return
            }

            let all = cfg.functions
            let resp = try await send(.workMode, GoodixProtocol.workModePayload(mode: 0, functions: all))
            guard resp.first == 0 else { throw EVKError.deviceRejected("work mode") }
            _ = try? await send(.chipCtrl, GoodixProtocol.chipHardResetPayload(), timeout: 1.5)
            try await Task.sleep(nanoseconds: 300_000_000)

            let maxWrite = p.maximumWriteValueLength(for: .withoutResponse)
            let regsPerChunk = max(4, min(56, (maxWrite - 5) / 4))
            appendLog("MTU write len \(maxWrite) → \(regsPerChunk) regs/packet")
            for (label, regs) in [("driver", cfg.driverRegs), ("algo", cfg.algoRegs)] {
                var k = 0
                while k < regs.count {
                    try Task.checkCancellation()
                    let slice = regs[k..<min(k + regsPerChunk, regs.count)]
                    let r = try await send(.loadRegList, GoodixProtocol.regListPayload(slice), timeout: 3.0)
                    guard r.first == 0 else { throw EVKError.deviceRejected("\(label) config chunk \(k / regsPerChunk)") }
                    k += regsPerChunk
                }
                appendLog("\(label) config: \(regs.count) registers loaded")
            }
            var funcs = functionsToStart.intersection(all)
            var s = try await send(.startCtrl, GoodixProtocol.startPayload(start: true, functions: funcs))
            if s.first != 0 {
                appendLog("Start rejected for 0x\(String(funcs.rawValue, radix: 16)), retrying with HR+SPO2")
                funcs = GoodixFunction([.hr, .spo2]).intersection(all)
                s = try await send(.startCtrl, GoodixProtocol.startPayload(start: true, functions: funcs))
            }
            guard s.first == 0 else { throw EVKError.deviceRejected("start") }
            activeFunctions = funcs
            state = .streaming(p.name ?? "sensor")
            appendLog("Sampling started (0x\(String(funcs.rawValue, radix: 16)))")
            onStreamingStarted?()
        } catch is CancellationError {
            appendLog("Configuration cancelled")
        } catch {
            appendLog("⚠️ \(error.localizedDescription)")
            state = .disconnected(p.name)
            scheduleReconnect()
        }
    }

    private func versionString(_ payload: [UInt8]) -> String {
        guard payload.count >= 2 else { return "" }
        let n = Int(payload[1])
        let bytes = payload.dropFirst(2).prefix(n)
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handle(_ frame: GoodixFrame) {
        guard frame.crcOK else { crcErrors += 1; return }
        if let cont = pending.removeValue(forKey: frame.cmd) {
            pendingTimeouts[frame.cmd]?.cancel()
            pendingTimeouts[frame.cmd] = nil
            cont.resume(returning: frame.payload)
            return
        }
        switch frame.cmd {
        case GoodixCmd.newRawdata.rawValue:
            packets += 1
            do {
                let pkt = try decoder.decode(frame.payload)
                for f in pkt.frames { onFrame?(f) }
            } catch {
                // a split (oversized) frame or a diff frame before the first absolute one – skip
            }
        case GoodixCmd.eventReport.rawValue where frame.payload.count >= 3:
            let irq = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
            let id = frame.payload[2]
            write(GoodixProtocol.build(.eventReport, [id]))
            if lastEventId != id {
                lastEventId = id
                let names = (0..<16).filter { irq >> $0 & 1 == 1 }.map { GoodixIRQ.names[$0] ?? "bit\($0)" }
                if irq & ~(1 << 5) != 0 { appendLog("Event: \(names.joined(separator: ","))") }
                onEvent?(irq)
            }
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard autoReconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.autoReconnect else { return }
            self.startScanning()
        }
    }

    private func appendLog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

enum EVKError: LocalizedError {
    case notConnected, superseded, timeout(GoodixCmd), deviceRejected(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .superseded: return "Command superseded"
        case .timeout(let c): return "No reply to command 0x\(String(c.rawValue, radix: 16))"
        case .deviceRejected(let s): return "Device rejected \(s)"
        }
    }
}

// MARK: - CoreBluetooth delegates (central created with the main queue, so these run on the main actor)

extension EVKManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if autoReconnect { startScanning() }
            case .poweredOff:
                state = .bluetoothOff
            case .unauthorized:
                state = .unauthorized
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            // iOS caches peripheral.name; the advertised local name is authoritative (a re-flashed XIAO changes it).
            let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = advName ?? peripheral.name ?? ""
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let isEVK = Self.isSensorName(name) || Self.isSensorName(peripheral.name ?? "") || services.contains(Self.serviceUUID)
            guard isEVK else { return }
            discoveredNames[peripheral.identifier] = name
            if let idx = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
                discovered[idx].rssi = RSSI.intValue
            } else {
                discovered.append(Discovered(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
                appendLog("Found \(name) (\(RSSI.intValue) dBm)")
            }
            guard case .scanning = state else { return }
            // Prefer a GH-XIAO (algorithms + IMU on board). Give it a moment to show up before
            // settling for the EVK mainboard, whose STM32 may be held in reset.
            if name.hasPrefix(Self.xiaoPrefix) {
                connect(to: peripheral.identifier)
            } else if scanStartedAt.map({ Date().timeIntervalSince($0) > 2.5 }) ?? true {
                connect(to: peripheral.identifier)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            appendLog("Connected, discovering services")
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            appendLog("Connect failed: \(error?.localizedDescription ?? "?")")
            state = .disconnected(peripheral.name)
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            appendLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
            configTask?.cancel()
            for (_, c) in pending { c.resume(throwing: EVKError.notConnected) }
            pending.removeAll()
            txChar = nil
            rxChar = nil
            notifyRequested = false
            state = .disconnected(peripheral.name)
            scheduleReconnect()
        }
    }
}

extension EVKManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in peripheral.services ?? [] {
                peripheral.discoverCharacteristics([Self.txUUID, Self.rxUUID], for: s)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == Self.txUUID { txChar = c }
                if c.uuid == Self.rxUUID { rxChar = c }
            }
            if let tx = txChar, rxChar != nil, !tx.isNotifying, !notifyRequested {
                notifyRequested = true
                peripheral.setNotifyValue(true, for: tx)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.txUUID else { return }
            if let e = error {
                appendLog("Notify failed: \(e.localizedDescription)")
                return
            }
            appendLog("Notifications on, starting configuration")
            peripheral.readRSSI()
            configTask?.cancel()
            configTask = Task { await self.configureAndStart() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.txUUID, let data = characteristic.value else { return }
            for frame in parser.feed(data) { handle(frame) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            rssi = RSSI.intValue
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.peripheral?.state == .connected else { return }
                self.peripheral?.readRSSI()
            }
        }
    }
}
