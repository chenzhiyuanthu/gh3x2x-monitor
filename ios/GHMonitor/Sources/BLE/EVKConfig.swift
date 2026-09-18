import Foundation
import Compression

/// Loads a GHTestTool `.ini` configuration: driver + algorithm register tables and the function list.
struct EVKConfig {
    let name: String
    let driverRegs: [(UInt16, UInt16)]
    let algoRegs: [(UInt16, UInt16)]
    let functions: GoodixFunction
    let functionNames: [String]

    static func bundled(named resource: String = "evk_config") -> EVKConfig? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ini"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, name: resource)
    }

    static func parse(_ rawText: String, name: String) -> EVKConfig? {
        // Normalise Windows line endings: Swift treats "\r\n" as one Character, which breaks "\n[" searches.
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        func section(_ title: String) -> String {
            guard let range = text.range(of: "[\(title)]") else { return "" }
            let rest = text[range.upperBound...]
            if let next = rest.range(of: "\n[") { return String(rest[..<next.lowerBound]) }
            return String(rest)
        }
        func regs(_ s: String) -> [(UInt16, UInt16)] {
            let pattern = #"\{\s*0x([0-9A-Fa-f]{1,4})\s*,\s*0x([0-9A-Fa-f]{1,4})\s*\}"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
                guard let a = UInt16(ns.substring(with: m.range(at: 1)), radix: 16),
                      let v = UInt16(ns.substring(with: m.range(at: 2)), radix: 16) else { return nil }
                return (a, v)
            }
        }
        let drv = regs(section("drvregister-table"))
        guard !drv.isEmpty else { return nil }
        let algo = regs(section("algoregister-table"))

        // Function list lives in the zlib-compressed JSON blob of [diagram-parameter] values=
        var names: [String] = []
        let diag = section("diagram-parameter")
        if let line = diag.split(separator: "\n").first(where: { $0.hasPrefix("values=") }) {
            var b64 = String(line.dropFirst("values=".count))
            b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "\" \r"))
            if let raw = Data(base64Encoded: b64), let json = zlibInflate(raw) ?? zlibInflate(raw.dropFirst(4)),
               let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
               let list = obj["sFunctionList"] as? [String], let first = list.first {
                names = first.split(separator: ",").compactMap { part in
                    let n = part.split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                    return (n?.isEmpty == false) ? n : nil
                }
            }
        }
        var mask = GoodixFunction()
        for n in names { if let f = GoodixFunction.byName[n] { mask.insert(f) } }
        return EVKConfig(name: name, driverRegs: drv, algoRegs: algo, functions: mask, functionNames: names)
    }

    /// Inflate a zlib stream (2-byte header + deflate + adler32).
    private static func zlibInflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let deflate = data.dropFirst(2) // skip zlib header; adler trailer is ignored by the decoder
        let dstSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let n = deflate.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dst, dstSize, base, deflate.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }
}
