import Foundation

extension MaskedPattern {
    /// The pattern a search looks for: its bytes and its holes, its letters
    /// compared by `folding`.
    public init(_ pattern: SearchPattern, folding: CaseFolding = .exact) {
        self.init(bytes: pattern.bytes, isWild: pattern.isWild, folding: folding)
    }
}

extension SearchEngine {
    /// Every match of any of `patterns` in `range` of `storage`, in order of
    /// where it starts, handed to `visit` with the pattern's index — `visit`
    /// returns false to stop.
    ///
    /// A pattern may have holes (`MaskedPattern`), and with `overlapping` a
    /// match is looked for again one byte after the last one's start rather
    /// than after its end. The scan is `PatternScan`'s, which the UEFI
    /// Structure's search through a firmware's volumes runs as well.
    public static func matches(
        of patterns: [MaskedPattern],
        in storage: ByteStorage,
        range: Range<UInt64>? = nil,
        overlapping: Bool = false,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in },
        windowFinished: (_ scannedUpTo: UInt64) -> Void = { _ in },
        visit: (_ match: Range<UInt64>, _ pattern: Int) -> Bool
    ) throws {
        try PatternScan.matches(of: patterns, size: storage.size, range: range, overlapping: overlapping,
                                chunkSize: chunkSize, read: { try storage.read(at: $0, length: $1) },
                                shouldCancel: shouldCancel, progress: progress,
                                windowFinished: windowFinished, visit: visit)
    }

    /// The last match of `pattern` starting below `anchor`: Find Previous
    /// (`PatternScan.lastMatch`).
    public static func lastMatch(
        of pattern: MaskedPattern,
        in storage: ByteStorage,
        before anchor: UInt64,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Range<UInt64>? {
        try PatternScan.lastMatch(of: pattern, size: storage.size, before: anchor, chunkSize: chunkSize,
                                  read: { try storage.read(at: $0, length: $1) },
                                  shouldCancel: shouldCancel, progress: progress)
    }
}
