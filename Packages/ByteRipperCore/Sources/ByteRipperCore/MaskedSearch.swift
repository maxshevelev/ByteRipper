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

    /// A pattern that is these bytes and no holes.
    public init(_ pattern: SearchPattern, folding: CaseFolding = .exact) {
        self.init(bytes: pattern.bytes, folding: folding)
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
}

extension SearchEngine {
    /// Every match of any of `patterns` in `range` of `storage`, in order of
    /// where it starts, handed to `visit` with the pattern's index — `visit`
    /// returns false to stop.
    ///
    /// What `findAll` does, and the two things it does not: a pattern may have
    /// holes (`MaskedPattern`), and with `overlapping` a match is looked for
    /// again one byte after the last one's start rather than after its end, so
    /// `AA` in `AAAA` is three matches. Each window is read once, a chunk and
    /// the longest pattern's length less one, so a match across the boundary
    /// is found once and only once; letters are compared candidate by
    /// candidate, so a UTF-16 unit is folded counting from where the match
    /// starts, as `CaseFolding.utf16` asks.
    ///
    /// Two patterns matching at one place — the text in ASCII and in UTF-16 —
    /// are both reported, ASCII's first: they are different matches. Throws
    /// `CancellationError` when `shouldCancel` says so between windows.
    public static func matches(
        of patterns: [MaskedPattern],
        in storage: ByteStorage,
        range: Range<UInt64>? = nil,
        overlapping: Bool = false,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        visit: (_ match: Range<UInt64>, _ pattern: Int) -> Bool
    ) throws {
        guard !patterns.isEmpty, patterns.allSatisfy({ !$0.bytes.isEmpty }) else { throw SearchError.emptyPattern }
        let bounds = range.map { $0.clamped(to: 0..<storage.size) } ?? 0..<storage.size
        let longest = patterns.map(\.count).max()!
        let shortest = patterns.map(\.count).min()!
        guard UInt64(shortest) <= UInt64(bounds.count) else { return }

        // Where each pattern may next start, so the non-overlapping rule holds
        // across windows; the rule is per pattern, as each is its own search.
        var nextStart = [UInt64](repeating: bounds.lowerBound, count: patterns.count)
        var cursor = bounds.lowerBound
        while cursor < bounds.upperBound {
            if shouldCancel() { throw CancellationError() }
            let fresh = min(UInt64(chunkSize), bounds.upperBound - cursor)
            let length = Int(min(fresh + UInt64(longest - 1), bounds.upperBound - cursor))
            let window = try storage.read(at: cursor, length: length)
            guard !window.isEmpty else { break }

            // One pattern: its matches are in order as they are found, and go
            // straight to `visit` — a pattern that matches everywhere visits
            // millions, and gathering them first is most of the cost.
            if patterns.count == 1 {
                let pattern = patterns[0]
                var from = nextStart[0] > cursor ? Int(nextStart[0] - cursor) : 0
                let step = overlapping ? 1 : pattern.count
                while from < Int(fresh), let at = firstMatch(of: pattern, in: window, from: from, below: Int(fresh)) {
                    let start = cursor + UInt64(at)
                    guard visit(start..<(start + UInt64(pattern.count)), 0) else { return }
                    nextStart[0] = cursor + UInt64(at + step)
                    from = at + step
                }
                cursor += fresh
                continue
            }

            // The window's matches, every pattern's, in order of start.
            var found: [(start: Int, pattern: Int)] = []
            for (index, pattern) in patterns.enumerated() {
                var from = nextStart[index] > cursor ? Int(nextStart[index] - cursor) : 0
                while from < Int(fresh), let at = firstMatch(of: pattern, in: window, from: from, below: Int(fresh)) {
                    found.append((at, index))
                    let step = overlapping ? 1 : pattern.count
                    nextStart[index] = cursor + UInt64(at + step)
                    from = at + step
                }
            }
            found.sort { $0.start != $1.start ? $0.start < $1.start : $0.pattern < $1.pattern }
            for match in found {
                let start = cursor + UInt64(match.start)
                guard visit(start..<(start + UInt64(patterns[match.pattern].count)), match.pattern) else { return }
            }
            cursor += fresh
        }
    }

    /// The first place at or after `from`, starting below `below`, where
    /// `pattern` matches whole inside `window`.
    static func firstMatch(of pattern: MaskedPattern, in window: [UInt8], from: Int, below: Int) -> Int? {
        let count = pattern.count
        let lastStart = min(below - 1, window.count - count)
        guard from <= lastStart else { return nil }
        // Anchored on a byte that is not a hole: found fast, and only there is
        // the rest compared. Not on 0x00 or 0xFF where the pattern has another
        // byte — a dump is full of both, and an anchor on them stops at almost
        // every byte: an address such as `00 80 66 FF` is found by its 0x80.
        guard let anchor = pattern.isWild.indices.first(where: {
            !pattern.isWild[$0] && pattern.bytes[$0] != 0x00 && pattern.bytes[$0] != 0xFF
        }) ?? pattern.isWild.firstIndex(of: false) else { return nil }
        let first = pattern.bytes[anchor]
        let alternative = alternativeCase(of: first, at: anchor, in: pattern)
        return window.withUnsafeBufferPointer { buffer -> Int? in
            var start = from
            while start <= lastStart {
                // The next place the anchor byte, or its other case, is.
                var at = start + anchor
                let end = lastStart + anchor
                if alternative == first {
                    // One byte to look for: memchr, which is what makes a
                    // search of a whole dump take milliseconds.
                    guard let base = buffer.baseAddress,
                          let hit = memchr(base + at, Int32(first), end - at + 1) else { return nil }
                    at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                } else {
                    while at <= end, buffer[at] != first, buffer[at] != alternative { at += 1 }
                    guard at <= end else { return nil }
                }
                let candidate = at - anchor
                if matchesAt(candidate, pattern, buffer) { return candidate }
                start = candidate + 1
            }
            return nil
        }
    }

    /// The anchor byte's other case where the folding lets it have one, or the
    /// byte itself.
    private static func alternativeCase(of byte: UInt8, at index: Int, in pattern: MaskedPattern) -> UInt8 {
        guard isASCIILetter(byte) else { return byte }
        switch pattern.folding {
        case .exact:
            return byte
        case .asciiBytes:
            return byte ^ 0x20
        case .utf16(let littleEndian):
            // A letter only as the low byte of a unit whose other byte is zero,
            // counting units from the pattern's start.
            let isLetterByte = littleEndian ? index % 2 == 0 : index % 2 == 1
            let partner = littleEndian ? index + 1 : index - 1
            guard isLetterByte, partner >= 0, partner < pattern.count,
                  !pattern.isWild[partner], pattern.bytes[partner] == 0 else { return byte }
            return byte ^ 0x20
        }
    }

    private static func matchesAt(_ start: Int, _ pattern: MaskedPattern, _ buffer: UnsafeBufferPointer<UInt8>) -> Bool {
        for index in 0..<pattern.count where !pattern.isWild[index] {
            let want = pattern.bytes[index]
            let have = buffer[start + index]
            if want == have { continue }
            guard isASCIILetter(want), want ^ 0x20 == have else { return false }
            switch pattern.folding {
            case .exact:
                return false
            case .asciiBytes:
                continue
            case .utf16(let littleEndian):
                // The unit is a letter only when its other byte, in the data,
                // is zero.
                let isLetterByte = littleEndian ? index % 2 == 0 : index % 2 == 1
                let partner = start + (littleEndian ? index + 1 : index - 1)
                guard isLetterByte, partner >= 0, partner < buffer.count, buffer[partner] == 0 else { return false }
            }
        }
        return true
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        let lower = byte | 0x20
        return lower >= 0x61 && lower <= 0x7A
    }
}
