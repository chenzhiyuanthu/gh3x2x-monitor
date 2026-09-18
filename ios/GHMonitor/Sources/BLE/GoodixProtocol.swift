import Foundation

/// Goodix GH3x2x EVK universal protocol ("Gh3x2x_Uprotocol_v0.4").
/// Frame: AA 11 <cmd> <len> <payload...> <crc8>; crc8 poly 0x07 / init 0xFF over all bytes before the crc.
enum GoodixCmd: UInt8 {
    case regRW = 0x03
    case rawdata = 0x08
    case newRawdata = 0x0B
    case startCtrl = 0x0C
    case currentBattery = 0x0D
    case workMode = 0x10
    case eventReport = 0x16
    case chipCtrl = 0x17
    case getVersion = 0x19
    case chipConnected = 0x1A
    case functionInfo = 0x2C
    case getMaxLen = 0xA0
    case loadRegList = 0xA1
}

/// Function bit mask (gh_drv.h GH3X2X_FUNC_OFFSET_*).
struct GoodixFunction: OptionSet, Hashable {
    let rawValue: UInt32
    static let adt = GoodixFunction(rawValue: 1 << 0)
    static let hr = GoodixFunction(rawValue: 1 << 1)
    static let hrv = GoodixFunction(rawValue: 1 << 2)
    static let hsm = GoodixFunction(rawValue: 1 << 3)
    static let spo2 = GoodixFunction(rawValue: 1 << 6)
    static let ecg = GoodixFunction(rawValue: 1 << 7)
    static let pwtt = GoodixFunction(rawValue: 1 << 8)
    static let softAdtGreen = GoodixFunction(rawValue: 1 << 9)
    static let bt = GoodixFunction(rawValue: 1 << 10)
    static let resp = GoodixFunction(rawValue: 1 << 11)
    static let af = GoodixFunction(rawValue: 1 << 12)
    static let softAdtIR = GoodixFunction(rawValue: 1 << 15)
    static let leadDet = GoodixFunction(rawValue: 1 << 19)

    static let byName: [String: GoodixFunction] = [
        "ADT": .adt, "HR": .hr, "HRV": .hrv, "HSM": .hsm, "SPO2": .spo2, "ECG": .ecg, "PWTT": .pwtt,
        "SOFT_ADT_GREEN": .softAdtGreen, "BT": .bt, "RESP": .resp, "AF": .af, "SOFT_ADT_IR": .softAdtIR,
        "LEAD_DET": .leadDet,
    ]

    /// Function id offset (0...19) as carried in rawdata packets.
    static func name(forOffset offset: Int) -> String {
        for (k, v) in byName where v.rawValue == (1 << UInt32(offset)) { return k }
        return "F\(offset)"
    }
}

enum GoodixIRQ {
    static let names: [Int: String] = [
        0: "com_ready", 1: "lead_on", 2: "lead_off", 3: "fastrecovery", 4: "adc_done", 5: "fifo_full",
        6: "fifo_ov", 8: "led_tune_fail", 9: "led_tune_done", 10: "wear_on", 11: "wear_off",
        12: "timeslot_timeout", 13: "sample_rate_err", 14: "rst_irq",
    ]
    static let wearOn: UInt16 = 1 << 10
    static let wearOff: UInt16 = 1 << 11
}

enum GoodixProtocol {
    static let header: UInt8 = 0xAA
    static let version: UInt8 = 0x11

    static let crcTable: [UInt8] = [
        0x00, 0x07, 0x0E, 0x09, 0x1C, 0x1B, 0x12, 0x15, 0x38, 0x3F, 0x36, 0x31, 0x24, 0x23, 0x2A, 0x2D,
        0x70, 0x77, 0x7E, 0x79, 0x6C, 0x6B, 0x62, 0x65, 0x48, 0x4F, 0x46, 0x41, 0x54, 0x53, 0x5A, 0x5D,
        0xE0, 0xE7, 0xEE, 0xE9, 0xFC, 0xFB, 0xF2, 0xF5, 0xD8, 0xDF, 0xD6, 0xD1, 0xC4, 0xC3, 0xCA, 0xCD,
        0x90, 0x97, 0x9E, 0x99, 0x8C, 0x8B, 0x82, 0x85, 0xA8, 0xAF, 0xA6, 0xA1, 0xB4, 0xB3, 0xBA, 0xBD,
        0xC7, 0xC0, 0xC9, 0xCE, 0xDB, 0xDC, 0xD5, 0xD2, 0xFF, 0xF8, 0xF1, 0xF6, 0xE3, 0xE4, 0xED, 0xEA,
        0xB7, 0xB0, 0xB9, 0xBE, 0xAB, 0xAC, 0xA5, 0xA2, 0x8F, 0x88, 0x81, 0x86, 0x93, 0x94, 0x9D, 0x9A,
        0x27, 0x20, 0x29, 0x2E, 0x3B, 0x3C, 0x35, 0x32, 0x1F, 0x18, 0x11, 0x16, 0x03, 0x04, 0x0D, 0x0A,
        0x57, 0x50, 0x59, 0x5E, 0x4B, 0x4C, 0x45, 0x42, 0x6F, 0x68, 0x61, 0x66, 0x73, 0x74, 0x7D, 0x7A,
        0x89, 0x8E, 0x87, 0x80, 0x95, 0x92, 0x9B, 0x9C, 0xB1, 0xB6, 0xBF, 0xB8, 0xAD, 0xAA, 0xA3, 0xA4,
        0xF9, 0xFE, 0xF7, 0xF0, 0xE5, 0xE2, 0xEB, 0xEC, 0xC1, 0xC6, 0xCF, 0xC8, 0xDD, 0xDA, 0xD3, 0xD4,
        0x69, 0x6E, 0x67, 0x60, 0x75, 0x72, 0x7B, 0x7C, 0x51, 0x56, 0x5F, 0x58, 0x4D, 0x4A, 0x43, 0x44,
        0x19, 0x1E, 0x17, 0x10, 0x05, 0x02, 0x0B, 0x0C, 0x21, 0x26, 0x2F, 0x28, 0x3D, 0x3A, 0x33, 0x34,
        0x4E, 0x49, 0x40, 0x47, 0x52, 0x55, 0x5C, 0x5B, 0x76, 0x71, 0x78, 0x7F, 0x6A, 0x6D, 0x64, 0x63,
        0x3E, 0x39, 0x30, 0x37, 0x22, 0x25, 0x2C, 0x2B, 0x06, 0x01, 0x08, 0x0F, 0x1A, 0x1D, 0x14, 0x13,
        0xAE, 0xA9, 0xA0, 0xA7, 0xB2, 0xB5, 0xBC, 0xBB, 0x96, 0x91, 0x98, 0x9F, 0x8A, 0x8D, 0x84, 0x83,
        0xDE, 0xD9, 0xD0, 0xD7, 0xC2, 0xC5, 0xCC, 0xCB, 0xE6, 0xE1, 0xE8, 0xEF, 0xFA, 0xFD, 0xF4, 0xF3,
    ]

    static func crc8(_ bytes: some Sequence<UInt8>) -> UInt8 {
        var c: UInt8 = 0xFF
        for b in bytes { c = crcTable[Int(c ^ b)] }
        return c
    }

    static func build(_ cmd: GoodixCmd, _ payload: [UInt8] = []) -> Data {
        var body: [UInt8] = [header, version, cmd.rawValue, UInt8(payload.count)]
        body += payload
        body.append(crc8(body))
        return Data(body)
    }

    // Payload helpers -------------------------------------------------------

    static func workModePayload(mode: UInt8 = 0, functions: GoodixFunction) -> [UInt8] {
        [mode] + le32(functions.rawValue)
    }

    static func startPayload(start: Bool, functions: GoodixFunction) -> [UInt8] {
        [start ? 0x00 : 0x01, 0x00, 0x00] + le32(functions.rawValue)
    }

    static func chipHardResetPayload() -> [UInt8] { [0x5A] }

    static func readRegPayload(_ addr: UInt16, count: UInt8 = 1) -> [UInt8] {
        [0x00, count, UInt8(addr >> 8), UInt8(addr & 0xFF)]
    }

    /// Register list chunk for 0xA1: big-endian addr/value words.
    static func regListPayload(_ regs: ArraySlice<(UInt16, UInt16)>) -> [UInt8] {
        var p: [UInt8] = []
        p.reserveCapacity(regs.count * 4)
        for (a, v) in regs {
            p += [UInt8(a >> 8), UInt8(a & 0xFF), UInt8(v >> 8), UInt8(v & 0xFF)]
        }
        return p
    }

    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}

/// Splits the notification byte stream into complete frames.
struct GoodixFrame {
    let cmd: UInt8
    let payload: [UInt8]
    let crcOK: Bool
}

final class GoodixFrameParser {
    private var buffer: [UInt8] = []

    func feed(_ data: Data) -> [GoodixFrame] {
        buffer.append(contentsOf: data)
        var frames: [GoodixFrame] = []
        while true {
            guard let start = findHeader() else { buffer.removeAll(keepingCapacity: true); break }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 5 else { break }
            let len = Int(buffer[3])
            let need = 4 + len + 1
            guard buffer.count >= need else { break }
            let frame = Array(buffer[0..<need])
            buffer.removeFirst(need)
            let ok = GoodixProtocol.crc8(frame.dropLast()) == frame[need - 1]
            frames.append(GoodixFrame(cmd: frame[2], payload: Array(frame[4..<(4 + len)]), crcOK: ok))
        }
        return frames
    }

    private func findHeader() -> Int? {
        guard buffer.count >= 2 else { return buffer.isEmpty ? nil : (buffer[0] == GoodixProtocol.header ? 0 : nil) }
        for i in 0..<(buffer.count - 1) where buffer[i] == GoodixProtocol.header && buffer[i + 1] == GoodixProtocol.version {
            return i
        }
        // keep a trailing 0xAA in case the version byte arrives in the next chunk
        if buffer.last == GoodixProtocol.header { return buffer.count - 1 }
        return nil
    }
}
