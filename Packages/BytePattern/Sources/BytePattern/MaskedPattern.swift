import Foundation

/// A pattern with holes in it: bytes, some of which match anything — the
/// `24 ?? 4D 49` of a hex search — compared by an encoding's case rules.
public struct MaskedPattern: Equatable, Sendable {
    /// The bytes to match; where `isWild` is true, the byte here is ignored.
    public let bytes: [UInt8]
    public let isWild: [Bool]
    public let folding: CaseFolding

    public init(bytes: [UInt8], isWild: [Bool]? = nil, folding: CaseFolding = .exact) {
        // A hole per byte: a shorter or longer mask is a caller's mistake,
        // caught here rather than as a read past the end inside a scan.
        precondition(isWild.map { $0.count == bytes.count } ?? true, "isWild must have one entry per byte")
        self.bytes = bytes
        self.isWild = isWild ?? [Bool](repeating: false, count: bytes.count)
        self.folding = folding
    }

    public var count: Int { bytes.count }

    /// Hex text with `??` for any byte — the one reading of a hex search, the
    /// find bar's and the agent's.
    ///
    /// Digits are read in pairs across the whole text: spaces between them,
    /// and a `0x` in front of a group, are for the eye and change nothing, so
    /// `DEADBEEF`, `DE AD BE EF`, `0xDE 0xAD` and `D EADBEEF` are the same four
    /// bytes, as the find bar has always taken them. `??` in place of a pair is
    /// a byte that matches anything — `24 ?? 4D 49`, `24??4D` as well.
    ///
    /// A hole is a whole byte. A `?` paired with a digit (`2?`) would mask
    /// half a byte, which the scan does not do, and is refused as
    /// `partialByteMask` rather than read as something else; so is a lone `?`.
    /// A pattern of holes alone matches everywhere and is refused as
    /// `holesOnly`.
    public static func hex(_ text: String) throws -> MaskedPattern {
        var symbols: [Character] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            var rest = Substring(token)
            if rest.lowercased().hasPrefix("0x") { rest = rest.dropFirst(2) }
            guard !rest.isEmpty,
                  rest.allSatisfy({ $0.isHexDigit || $0 == "?" }) else { throw SearchError.invalidHexPattern }
            symbols.append(contentsOf: rest)
        }
        // No digits at all is not a hex pattern, as the find bar has always said.
        guard !symbols.isEmpty else { throw SearchError.invalidHexPattern }
        guard symbols.count % 2 == 0 else {
            throw symbols.contains("?") ? SearchError.partialByteMask : SearchError.invalidHexPattern
        }
        var bytes: [UInt8] = []
        var wild: [Bool] = []
        bytes.reserveCapacity(symbols.count / 2)
        wild.reserveCapacity(symbols.count / 2)
        var index = 0
        while index < symbols.count {
            let high = symbols[index], low = symbols[index + 1]
            index += 2
            switch (high == "?", low == "?") {
            case (true, true):
                bytes.append(0)
                wild.append(true)
            case (false, false):
                guard let byte = UInt8(String([high, low]), radix: 16) else { throw SearchError.invalidHexPattern }
                bytes.append(byte)
                wild.append(false)
            default:
                throw SearchError.partialByteMask
            }
        }
        guard wild.contains(false) else { throw SearchError.holesOnly }
        return MaskedPattern(bytes: bytes, isWild: wild, folding: .exact)
    }

    /// Whether any byte of the pattern is a hole.
    public var hasHoles: Bool { isWild.contains(true) }

    /// The pattern as a hex dump writes it: uppercase pairs, one space
    /// between them, `??` for a hole — the one form a search shows back.
    public var hexText: String {
        zip(bytes, isWild).map { $1 ? "??" : String(format: "%02X", $0) }.joined(separator: " ")
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
