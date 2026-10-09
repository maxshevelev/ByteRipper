import Foundation

/// Bytes as every tool that reads them shows them — `read`, and a node's
/// bytes read out of the buffer a compressed section opened to — so the two
/// answers look alike: rows as the dump draws them, text, or integers.
public enum AgentBytes {
    /// The formats a read takes.
    public static let formats = ["hex", "ascii", "utf16le", "u8", "u16", "u32", "u64"]

    /// The answer's members for `bytes` read at `address`, in `format`.
    public static func shown(_ bytes: [UInt8], at address: UInt64, format: String,
                             bigEndian: Bool) -> [String: JSONValue] {
        var answer: [String: JSONValue] = ["format": .string(format)]
        switch format {
        case "hex":
            answer["rows"] = .array(hexRows(bytes, at: address).map { .string($0) })
        case "ascii":
            answer["text"] = .string(printable(bytes))
        case "utf16le":
            answer["text"] = .string(utf16le(bytes))
        default:
            let width = ["u8": 1, "u16": 2, "u32": 4, "u64": 8][format] ?? 1
            answer["values"] = .array(integers(bytes, width: width, bigEndian: bigEndian))
            if width > 1 { answer["endian"] = .string(bigEndian ? "big" : "little") }
        }
        return answer
    }

    public static func printable(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self)
    }

    public static func utf16le(_ bytes: [UInt8]) -> String {
        let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    /// Rows as the dump draws them — address, sixteen bytes, their text —
    /// counted from `address` rather than from a row boundary, so the first
    /// row starts with the byte asked for.
    public static func hexRows(_ bytes: [UInt8], at address: UInt64) -> [String] {
        stride(from: 0, to: bytes.count, by: 16).map { start in
            let row = Array(bytes[start..<min(start + 16, bytes.count)])
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            return String(format: "%08llX  ", address + UInt64(start)) + padded + "  |" + printable(row) + "|"
        }
    }

    public static func integers(_ bytes: [UInt8], width: Int, bigEndian: Bool) -> [JSONValue] {
        guard bytes.count >= width else { return [] }
        return stride(from: 0, through: bytes.count - width, by: width).map { start in
            var value: UInt64 = 0
            for index in 0..<width {
                let byte = UInt64(bytes[start + (bigEndian ? index : width - 1 - index)])
                value = value << 8 | byte
            }
            return .string(String(format: "0x%0*llX", width * 2, value))
        }
    }

    /// Bytes as hex pairs, `DE AD BE EF`.
    public static func hexText(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
