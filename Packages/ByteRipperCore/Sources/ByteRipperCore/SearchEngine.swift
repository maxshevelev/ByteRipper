import Foundation

@_exported import BytePattern
@_exported import Find

extension CaseFolding {
    /// The rule for an encoding and the user's choice.
    public init(encoding: SearchEncoding, caseSensitive: Bool) {
        guard !caseSensitive else { self = .exact; return }
        switch encoding {
        // Hex input is bytes; bytes have no case to fold. (The *parser* accepts
        // `de ad` and `DE AD` alike — that is the input, not the comparison.)
        case .hex: self = .exact
        case .ascii, .utf8: self = .asciiBytes
        case .utf16LE: self = .utf16(littleEndian: true)
        case .utf16BE: self = .utf16(littleEndian: false)
        }
    }
}

/// The byte encoding of a search pattern (§11).
public enum SearchEncoding: String, CaseIterable, Sendable {
    /// Input is a hexadecimal byte sequence: `DEADBEEF`, `DE AD BE EF`, or
    /// `0xDE 0xAD`, case-insensitive.
    case hex
    case ascii
    case utf8
    case utf16LE
    case utf16BE
}

/// A resolved search pattern: the byte sequence to find, the bytes of it
/// that match anything (`??` in hex), and the encoding it came from (for
/// display).
public struct SearchPattern: Equatable, Sendable {
    public let bytes: [UInt8]
    /// Where true, the byte is a hole: it matches any byte, and the value in
    /// `bytes` is not looked at. All false for every pattern but a hex one
    /// with `??` in it.
    public let isWild: [Bool]
    public let encoding: SearchEncoding

    public init(bytes: [UInt8], isWild: [Bool]? = nil, encoding: SearchEncoding) {
        self.bytes = bytes
        self.isWild = isWild ?? [Bool](repeating: false, count: bytes.count)
        self.encoding = encoding
    }

    /// Whether any byte of the pattern is a hole.
    public var hasHoles: Bool { isWild.contains(true) }

    /// The bytes written the way a hex dump writes them: uppercase pairs, one
    /// space between them (§11).
    ///
    /// The parser accepts more forms than a dump prints — `deadbeef`,
    /// `DE AD BE EF`, `0xDE 0xAD` — so this is the one form to show back: the
    /// text a reader can compare, byte for byte, against the dump beside it.
    /// It is derived from the *bytes*, so whatever the user typed comes back
    /// meaning exactly what was searched for.
    public var hexText: String {
        MaskedPattern(bytes: bytes, isWild: isWild).hexText
    }
}

/// Reads a search pattern, and finds it in a `ByteStorage` (§11).
///
/// The scan itself is `PatternScan`'s (`Packages/BytePattern`), reached
/// through `matches` and `lastMatch` here (`MaskedSearch.swift`); the dump's
/// find bar runs it through `ByteFindContent`, where matches always overlap.
/// It is the one scan the agent's `find_bytes` and the UEFI Structure's search
/// run as well, so the three cannot disagree about what a match is (#33).
///
/// Search reads the current storage — including any unsaved edits layered over
/// the base — so results always reflect the latest content. The scan is
/// incremental (bounded chunks with overlap across boundaries) and accepts
/// `shouldCancel`/`progress`, so large files are searched in the background
/// without blocking the UI (§11, §13.7–8).
public enum SearchEngine {
    public static let defaultChunkSize = 1024 * 1024

    /// Resolves a pattern string to bytes for the given encoding.
    ///
    /// Hex is `MaskedPattern.hex`'s reading, the one the agent's search makes
    /// too. `??` in it is a hole only where the caller searches with one —
    /// `allowingHoles`: the find bar and the pattern library do; a fill, which
    /// has to write every byte it names, does not, and is refused a pattern
    /// with a hole as `invalidHexPattern`.
    public static func parsePattern(_ text: String, encoding: SearchEncoding,
                                    allowingHoles: Bool = false) throws -> SearchPattern {
        let bytes: [UInt8]
        switch encoding {
        case .hex:
            let masked = try MaskedPattern.hex(text)
            guard allowingHoles || !masked.hasHoles else { throw SearchError.invalidHexPattern }
            return SearchPattern(bytes: masked.bytes, isWild: masked.isWild, encoding: .hex)
        case .ascii: bytes = try encode(text, using: .ascii)
        case .utf8: bytes = try encode(text, using: .utf8)
        case .utf16LE: bytes = try encode(text, using: .utf16LittleEndian)
        case .utf16BE: bytes = try encode(text, using: .utf16BigEndian)
        }
        guard !bytes.isEmpty else { throw SearchError.emptyPattern }
        return SearchPattern(bytes: bytes, encoding: encoding)
    }

    /// The most matches a results list shows (§11): `FindLimits.listedMatches`.
    /// It limits *listing*, not counting — the scan that counts is uncapped, so
    /// a pattern found a thousand and one times and one found three million
    /// times do not look alike.
    public static let defaultMaxResults = FindLimits.listedMatches

    /// One instalment of an index being built: the matches found since the last
    /// one, and how far the scan has got.
    ///
    /// The offset is what makes a half-built index usable. Every match below it
    /// has been reported, so the dump can grey what is known while the rest of
    /// the file is still being scanned, and only the things that need the whole
    /// file — the total, the wrap, an ordinal — wait for the end (§11).
    public typealias MatchBatch = Find.MatchBatch

    /// How many matches the highlighting scan (`ByteFindContent.matchStarts`)
    /// delivers at a time. A batch is a delivery cost, not a limit: one match
    /// per hop onto the consumer is wrong for the million matches a single-byte
    /// pattern has.
    public static let defaultBatchSize = 4096

    // MARK: - Parsing

    private static func encode(_ text: String, using encoding: String.Encoding) throws -> [UInt8] {
        guard let data = text.data(using: encoding) else { throw SearchError.undecodableText }
        return Array(data)
    }
}
