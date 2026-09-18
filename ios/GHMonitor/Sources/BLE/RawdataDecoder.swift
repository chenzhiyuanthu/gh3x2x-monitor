import Foundation

/// One decoded sample frame of a function (e.g. HR) — mirrors gh_uprotocol.c / gh_zip.c 0x0B packets.
struct SensorFrame {
    let function: Int            // function id offset (1 = HR, 6 = SPO2, ...)
    let frameId: UInt8
    let gsensor: (Int16, Int16, Int16)?
    let raw: [UInt32]?           // 24-bit ADC per channel (nil until an absolute frame has been seen)
    let agc: [UInt32]?           // bit0-3 gain, bit8-15 drv0 mA, bit16-23 drv1 mA
    let flags: [UInt8: Int32]    // result tags 0/2/3/4
    let algo: [Int: Int32]       // algorithm results index -> value

    var gain: [Int] { (agc ?? []).map { Int($0 & 0xF) } }
    var drv0: [Int] { (agc ?? []).map { Int(($0 >> 8) & 0xFF) } }
}

struct DecodedPacket {
    let function: Int
    let channelCount: Int
    let channelMask: UInt32
    let frames: [SensorFrame]
}

enum DecodeError: Error { case truncated, splitPacket }

/// Stateful decoder: keeps the last absolute rawdata / AGC per function so compressed diff frames can be rebuilt.
final class RawdataDecoder {
    private var lastRaw: [Int: [UInt32]] = [:]
    private var lastAgc: [Int: [UInt32]] = [:]

    func reset() { lastRaw.removeAll(); lastAgc.removeAll() }

    func decode(_ p: [UInt8]) throws -> DecodedPacket {
        guard p.count >= 8 else { throw DecodeError.truncated }
        let function = Int(p[0])
        let dtype = p[1]
        let mask = UInt32(p[2]) << 24 | UInt32(p[3]) << 16 | UInt32(p[4]) << 8 | UInt32(p[5])
        let pkgFlag = p[6]
        let total = Int(p[7])
        let chn = mask.nonzeroBitCount
        let gs = dtype & 1 != 0, agc = dtype & 4 != 0, amb = dtype & 8 != 0
        let gyro = dtype & 16 != 0, cap = dtype & 32 != 0, temp = dtype & 64 != 0
        let zip = pkgFlag & 1 != 0, odd = pkgFlag & 2 != 0, fifoPkg = pkgFlag & 4 != 0
        if (pkgFlag >> 3) & 0xF != 0 { throw DecodeError.splitPacket }
        guard p.count >= 8 + total else { throw DecodeError.truncated }
        let body = Array(p[8..<(8 + total)])
        var i = 0
        var frames: [SensorFrame] = []
        var first = true

        func need(_ n: Int) throws { if i + n > body.count { throw DecodeError.truncated } }

        while i < body.count {
            try need(1)
            let fid = body[i]; i += 1
            var gsv: (Int16, Int16, Int16)? = nil
            if gs {
                try need(6)
                gsv = (Int16(bitPattern: UInt16(body[i]) << 8 | UInt16(body[i + 1])),
                       Int16(bitPattern: UInt16(body[i + 2]) << 8 | UInt16(body[i + 3])),
                       Int16(bitPattern: UInt16(body[i + 4]) << 8 | UInt16(body[i + 5])))
                i += 6
                if gyro { try need(6); i += 6 }
            }
            if cap { try need(12); i += 12 }
            if temp { try need(12); i += 12 }

            let absolute = !zip || (odd && first)
            var raw: [UInt32]? = nil
            if fifoPkg {
                try need(1); i += 1
            } else if absolute {
                try need(4 * chn)
                var r: [UInt32] = []
                r.reserveCapacity(chn)
                for k in 0..<chn {
                    let o = i + 4 * k
                    r.append(UInt32(body[o + 1]) << 16 | UInt32(body[o + 2]) << 8 | UInt32(body[o + 3]))
                }
                i += 4 * chn
                raw = r
                lastRaw[function] = r
            } else {
                let (diffs, used) = try diffBlock(body, at: i, channels: chn, hasTagFlag: true)
                i += used
                if let last = lastRaw[function], last.count == chn {
                    var r = last
                    for k in 0..<chn { r[k] = UInt32(truncatingIfNeeded: Int64(last[k]) + Int64(diffs[k])) }
                    raw = r
                    lastRaw[function] = r
                }
            }

            var agcv: [UInt32]? = nil
            if agc {
                if absolute || !zip {
                    try need(4 * chn)
                    var a: [UInt32] = []
                    for k in 0..<chn {
                        let o = i + 4 * k
                        a.append(UInt32(body[o]) | UInt32(body[o + 1]) << 8 | UInt32(body[o + 2]) << 16 | UInt32(body[o + 3]) << 24)
                    }
                    i += 4 * chn
                    agcv = a
                    lastAgc[function] = a
                } else {
                    let (diffs, used) = try diffBlock(body, at: i, channels: chn, hasTagFlag: false)
                    i += used
                    if let last = lastAgc[function], last.count == chn {
                        var a = last
                        for k in 0..<chn { a[k] = UInt32(truncatingIfNeeded: Int64(last[k]) + Int64(diffs[k])) }
                        agcv = a
                        lastAgc[function] = a
                    }
                }
            }
            if amb { try need(3 * chn); i += 3 * chn }

            // result section: [n][tag(1) value(4 LE)]*
            try need(1)
            let n = Int(body[i])
            var flags: [UInt8: Int32] = [:]
            var algo: [Int: Int32] = [:]
            var j = i + 1
            let end = min(i + 1 + n, body.count)
            while j + 5 <= end {
                let tag = body[j]
                let v = Int32(bitPattern: UInt32(body[j + 1]) | UInt32(body[j + 2]) << 8 | UInt32(body[j + 3]) << 16 | UInt32(body[j + 4]) << 24)
                if tag & 0x80 != 0 { algo[Int(tag & 0x7F)] = v } else { flags[tag] = v }
                j += 5
            }
            i += 1 + n
            frames.append(SensorFrame(function: function, frameId: fid, gsensor: gsv, raw: raw, agc: agcv, flags: flags, algo: algo))
            first = false
        }
        return DecodedPacket(function: function, channelCount: chn, channelMask: mask, frames: frames)
    }

    /// Diff block: [len][tag-change flag][tags...][nibble stream]; size = len + 1.
    private func diffBlock(_ body: [UInt8], at start: Int, channels: Int, hasTagFlag: Bool) throws -> ([Int64], Int) {
        guard start < body.count else { throw DecodeError.truncated }
        let len = Int(body[start])
        let size = len + 1
        guard start + size <= body.count else { throw DecodeError.truncated }
        let blk = Array(body[start..<(start + size)])
        var nib: Int
        if hasTagFlag {
            guard blk.count >= 2 else { throw DecodeError.truncated }
            nib = blk[1] != 0 ? (2 + channels) * 2 : 4
        } else {
            nib = 2
        }
        func read() throws -> Int64 {
            let idx = nib / 2
            guard idx < blk.count else { throw DecodeError.truncated }
            let b = blk[idx]
            let v = (nib % 2 == 0) ? (b >> 4) : (b & 0xF)
            nib += 1
            return Int64(v)
        }
        var diffs: [Int64] = []
        diffs.reserveCapacity(channels)
        for _ in 0..<channels {
            let t = try read()
            var v: Int64 = 0
            for _ in 0..<(Int(t) / 2 + 1) { v = (v << 4) | (try read()) }
            diffs.append((t & 1) != 0 ? -v : v)
        }
        return (diffs, size)
    }
}
