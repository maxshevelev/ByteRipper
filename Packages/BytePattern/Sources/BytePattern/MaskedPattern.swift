import Foundation

/// A pattern with holes in it: bytes, some of which match anything — the
/// `24 ?? 4D 49` of a hex search — compared by an encoding's case rules.
public struct MaskedPattern: Equatable, Sendable {
    /// The bytes to match; where `isWild` is true, the byte here is ignored.
    public let bytes: [UInt8]
    public let isWild: [Bool]
    public let folding: CaseFolding

    public init(bytes: [UInt8], isWild: [Bool]? = nil, folding: CaseFolding = .exact) {
        self.bytes = bytes
        self.isWild = isWild ?? [Bool](repeating: false, count: bytes.count)
        self.folding = folding
    }

    public var count: Int { bytes.count }

    /// Hex text with `??` for any byte: pairs of digits, spaces and `0x`
    /// prefixes as the find bar takes them, and `??` — on its own or between
    /// pairs, `24??4D` as well — for a byte that matches anything. A pattern
    /// of holes alone matches everywhere and is refused.
    public static func hex(_ text: String) throws -> MaskedPattern {
        var bytes: [UInt8] = []
        var wild: [Bool] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            var rest = Substring(token)
            if rest.lowercased().hasPrefix("0x") { rest = rest.dropFirst(2) }
            guard !rest.isEmpty, rest.count % 2 == 0 else { throw SearchError.invalidHexPattern }
            while !rest.isEmpty {
                let pair = rest.prefix(2)
                rest = rest.dropFirst(2)
                if pair == "??" {
                    bytes.append(0)
                    wild.append(true)
                } else if let byte = UInt8(pair, radix: 16) {
                    bytes.append(byte)
                    wild.append(false)
                } else {
                    throw SearchError.invalidHexPattern
                }
            }
        }
        guard !bytes.isEmpty else { throw SearchError.emptyPattern }
        guard wild.contains(false) else { throw SearchError.invalidHexPattern }
        return MaskedPattern(bytes: bytes, isWild: wild, folding: .exact)
    }

    /// `text` as ASCII bytes, any case of a letter with `ignoringCase`;
    /// throws for a text that is not ASCII.
    public static func ascii(_ text: String, ignoringCase: Bool) throws -> MaskedPattern {
        guard !text.isEmpty else { throw SearchError.emptyPattern }
        guard let bytes = text.data(using: .ascii) else { throw SearchError.undecodableText }
        return MaskedPattern(bytes: Array(bytes), folding: ignoringCase ? .asciiBytes : .exact)
    }

    /// `text` as UTF-16LE code units — how firmware keeps a name such as a
    /// variable's or a menu's.
    public static func utf16LE(_ text: String, ignoringCase: Bool) throws -> MaskedPattern {
        guard !text.isEmpty else { throw SearchError.emptyPattern }
        let bytes = Array(text.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        return MaskedPattern(bytes: bytes, folding: ignoringCase ? .utf16(littleEndian: true) : .exact)
    }
}
