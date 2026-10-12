import Foundation

extension MaskedPattern {
    /// A pattern that is these bytes and no holes.
    public init(_ pattern: SearchPattern, folding: CaseFolding = .exact) {
        self.init(bytes: pattern.bytes, folding: folding)
    }
}

extension SearchEngine {
    /// Every match of any of `patterns` in `range` of `storage`, in order of
    /// where it starts, handed to `visit` with the pattern's index — `visit`
    /// returns false to stop.
    ///
    /// What `findAll` does, and the two things it does not: a pattern may have
    /// holes (`MaskedPattern`), and with `overlapping` a match is looked for
    /// again one byte after the last one's start rather than after its end.
    /// The scan is `PatternScan`'s, which the UEFI Structure's search through
    /// a firmware's volumes runs as well.
    public static func matches(
        of patterns: [MaskedPattern],
        in storage: ByteStorage,
        range: Range<UInt64>? = nil,
        overlapping: Bool = false,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        visit: (_ match: Range<UInt64>, _ pattern: Int) -> Bool
    ) throws {
        try PatternScan.matches(of: patterns, size: storage.size, range: range, overlapping: overlapping,
                                chunkSize: chunkSize, read: { try storage.read(at: $0, length: $1) },
                                shouldCancel: shouldCancel, visit: visit)
    }
}
