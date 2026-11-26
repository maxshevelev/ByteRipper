import Foundation

/// What a short body (under Function ID's four instructions) is near to in
/// another module. Its key hashes its exact bytes, and a reference's operand
/// is part of them: `MOV [RIP + d], EDX` reaches the same global with another
/// `d` in every module (issue 33cc22d2). The shape masks the operand bytes that
/// encode a reference and keeps every other byte, so it only names candidates;
/// the key, the registry's ids and the marks stay what they were.
///
/// Computed here only, for both sides, from the rows the exporter stores for
/// an entry and the owner sends for a function: each instruction's address,
/// bytes and reference targets. The registry joins a bound short body of
/// another shape to its entry as a variant by it.
public enum LibraryShortShape {
    public struct Reference: Decodable, Equatable, Sendable {
        public var to: String
        public init(to: String) { self.to = to }
    }

    public struct Row: Decodable, Equatable, Sendable {
        public var address: String
        public var bytes: String
        public var references: [Reference]?
        public init(address: String, bytes: String, references: [Reference]?) {
            self.address = address
            self.bytes = bytes
            self.references = references
        }
    }

    /// A stored code object, as far as the shape reads it.
    public struct Code: Decodable, Sendable {
        public var instructions: [Row]
    }

    /// An entry object's, from the function it holds (`entry.function.instructions`).
    private struct Entry: Decodable {
        struct Function: Decodable { var instructions: [Row]? }
        var function: Function?
    }

    /// The shape of a code object (`LibraryCode.build`); nil when it is none.
    public static func shape(ofCode data: Data) -> String? {
        (try? JSONDecoder().decode(Code.self, from: data)).flatMap { shape($0.instructions) }
    }

    /// The names a code object gives the data it reaches (`label`), sorted.
    public static func labels(ofCode data: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let rows = object["instructions"] as? [[String: Any]] ?? []
        return rows.flatMap { ($0["references"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String } }.sorted()
    }

    /// The shape of the function an entry object holds; nil when it holds none.
    public static func shape(ofEntry data: Data) -> String? {
        guard let rows = (try? JSONDecoder().decode(Entry.self, from: data))?.function?.instructions else { return nil }
        return shape(rows)
    }

    /// The masked shape, `s<count>-<sha256>`; nil when a row cannot be read.
    public static func shape(_ rows: [Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        var tokens: [String] = []
        for row in rows {
            guard let masked = masked(row) else { return nil }
            tokens.append(masked)
        }
        let text = tokens.joined(separator: "|")
        return "s\(rows.count)-" + SHA256Digest(data: Data(text.utf8)).hex
    }

    /// The row's bytes in hex, `??` for each byte of a field that encodes one
    /// of its references: the target's eight or four low bytes (an absolute
    /// address), or the four of `target − end of the instruction` (a RIP- or
    /// EIP-relative displacement, a CALL or JMP rel32), little-endian. Another
    /// encoding of the reference, an 8- or 16-bit one, is kept as it is.
    public static func masked(_ row: Row) -> String? {
        guard let at = number(row.address) else { return nil }
        let words = row.bytes.split(separator: " ")
        var bytes: [UInt8] = []
        for word in words {
            guard let value = UInt8(word, radix: 16) else { return nil }
            bytes.append(value)
        }
        var hidden = [Bool](repeating: false, count: bytes.count)
        let end = at &+ UInt64(bytes.count)
        for reference in row.references ?? [] {
            guard let target = number(reference.to) else { continue }
            let fields: [[UInt8]] = [
                little(target, 8),
                little(target, 4),
                little(target &- end, 4)
            ]
            for field in fields where hide(field, in: bytes, &hidden) { break }
        }
        return zip(bytes, hidden).map { $1 ? "??" : String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func hide(_ field: [UInt8], in bytes: [UInt8], _ hidden: inout [Bool]) -> Bool {
        guard bytes.count >= field.count else { return false }
        // From the end: a displacement or address sits after the opcode and ModRM.
        for start in stride(from: bytes.count - field.count, through: 1, by: -1)
        where Array(bytes[start..<start + field.count]) == field {
            for index in start..<start + field.count { hidden[index] = true }
            return true
        }
        return false
    }

    private static func little(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    private static func number(_ hex: String) -> UInt64? {
        let digits = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? hex.dropFirst(2) : Substring(hex)
        return UInt64(digits, radix: 16)
    }
}
