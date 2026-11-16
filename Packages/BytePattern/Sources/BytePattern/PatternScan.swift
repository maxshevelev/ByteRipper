import Foundation

/// The scan for `MaskedPattern`s, over bytes the caller reads for it.
public enum PatternScan {
    public static let defaultChunkSize = 1024 * 1024

    /// Every match of any of `patterns` in `range` of `size` bytes `read`
    /// gives, in order of where it starts, handed to `visit` with the
    /// pattern's index — `visit` returns false to stop.
    ///
    /// A pattern may have holes (`MaskedPattern`). Matches overlap by
    /// default: a match is looked for again one byte after the last one's
    /// start rather than after its end, so `AA` in `AAAA` is three matches —
    /// the count the find bar, the UEFI Structure's search and `find_bytes`
    /// all give (#33); `overlapping: false` is two. Each window is
    /// read once, a chunk and the longest pattern's length less one, so a
    /// match across the boundary is found once and only once; letters are
    /// compared candidate by candidate, so a UTF-16 unit is folded counting
    /// from where the match starts, as `CaseFolding.utf16` asks.
    ///
    /// Two patterns matching at one place — the text in ASCII and in UTF-16 —
    /// are both reported, ASCII's first: they are different matches. Throws
    /// `CancellationError` when `shouldCancel` says so between windows.
    ///
    /// After each window, `windowFinished` is told how far the scan has got —
    /// every match starting below that offset has been visited — and
    /// `progress` the same as a fraction of `range`: what an index built while
    /// the scan runs needs to show what it already knows.
    public static func matches(
        of patterns: [MaskedPattern],
        size: UInt64,
        range: Range<UInt64>? = nil,
        overlapping: Bool = true,
        chunkSize: Int = defaultChunkSize,
        read: (_ offset: UInt64, _ length: Int) throws -> [UInt8],
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in },
        windowFinished: (_ scannedUpTo: UInt64) -> Void = { _ in },
        visit: (_ match: Range<UInt64>, _ pattern: Int) -> Bool
    ) throws {
        guard !patterns.isEmpty, patterns.allSatisfy({ !$0.bytes.isEmpty }) else { throw SearchError.emptyPattern }
        let bounds = range.map { $0.clamped(to: 0..<size) } ?? 0..<size
        let longest = patterns.map(\.count).max()!
        let shortest = patterns.map(\.count).min()!
        guard UInt64(shortest) <= UInt64(bounds.count) else {
            windowFinished(bounds.upperBound)
            progress(1)
            return
        }
        // One window is done: every start below its end has been looked for.
        func finished(_ upTo: UInt64) {
            windowFinished(upTo)
            let span = bounds.count
            progress(span == 0 ? 1 : Double(upTo - bounds.lowerBound) / Double(span))
        }

        // Where each pattern may next start, so the non-overlapping rule holds
        // across windows; the rule is per pattern, as each is its own search.
        var nextStart = [UInt64](repeating: bounds.lowerBound, count: patterns.count)
        // Which byte each pattern is found by, worked out once: a run of
        // matches asks for the next one millions of times.
        let anchors = patterns.map(Anchor.init)
        var cursor = bounds.lowerBound
        while cursor < bounds.upperBound {
            if shouldCancel() { throw CancellationError() }
            let fresh = min(UInt64(chunkSize), bounds.upperBound - cursor)
            let length = Int(min(fresh + UInt64(longest - 1), bounds.upperBound - cursor))
            let window = try read(cursor, length)
            guard !window.isEmpty else { break }

            // One pattern: its matches are in order as they are found, and go
            // straight to `visit` — a pattern that matches everywhere visits
            // millions, and gathering them first is most of the cost.
            if patterns.count == 1 {
                let pattern = patterns[0]
                var from = nextStart[0] > cursor ? Int(nextStart[0] - cursor) : 0
                let step = overlapping ? 1 : pattern.count
                while from < Int(fresh),
                      let at = firstMatch(of: pattern, anchor: anchors[0], in: window, from: from, below: Int(fresh)) {
                    let start = cursor + UInt64(at)
                    guard visit(start..<(start + UInt64(pattern.count)), 0) else { return }
                    nextStart[0] = cursor + UInt64(at + step)
                    from = at + step
                }
                cursor += fresh
                finished(cursor)
                continue
            }

            // The window's matches, every pattern's, in order of start.
            var found: [(start: Int, pattern: Int)] = []
            for (index, pattern) in patterns.enumerated() {
                var from = nextStart[index] > cursor ? Int(nextStart[index] - cursor) : 0
                while from < Int(fresh),
                      let at = firstMatch(of: pattern, anchor: anchors[index], in: window, from: from, below: Int(fresh)) {
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
            finished(cursor)
        }
        if cursor < bounds.upperBound { finished(bounds.upperBound) }
    }

    /// The last match of `pattern` that starts below `anchor` and at or above
    /// `lowerBound`, in `size` bytes `read` gives: Find Previous.
    ///
    /// A match that starts below the anchor and runs past it counts. That is
    /// what makes Find Previous step through matches that overlap — a run of
    /// `FF FF` is found one byte back at a time, as Find Next finds it one
    /// byte on — where "the last match that *ends* before the anchor" would
    /// skip the ones overlapping the match the reader stands on.
    ///
    /// Windows are read from the anchor back towards `lowerBound`, a chunk at
    /// a time with the pattern's length less one more, so a match across the
    /// edge of two windows is found, and each is looked through from its end
    /// back: the last match is the first one met, however many the window
    /// holds before it. `progress` is the fraction of
    /// `[lowerBound, anchor)` looked at.
    public static func lastMatch(
        of pattern: MaskedPattern,
        size: UInt64,
        before anchor: UInt64,
        lowerBound: UInt64 = 0,
        chunkSize: Int = defaultChunkSize,
        read: (_ offset: UInt64, _ length: Int) throws -> [UInt8],
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Range<UInt64>? {
        guard !pattern.bytes.isEmpty else { throw SearchError.emptyPattern }
        let count = UInt64(pattern.count)
        guard count <= size else { return nil }
        // No match can start after `size - count`.
        let limit = min(anchor, size - count + 1)
        guard limit > lowerBound else { progress(1); return nil }
        let span = Double(limit - lowerBound)
        let found = Anchor(pattern)
        var startsEnd = limit
        while startsEnd > lowerBound {
            if shouldCancel() { throw CancellationError() }
            let windowStart = max(lowerBound, startsEnd > UInt64(chunkSize) ? startsEnd - UInt64(chunkSize) : 0)
            let fresh = Int(startsEnd - windowStart)
            let length = Int(min(UInt64(fresh) + count - 1, size - windowStart))
            let window = try read(windowStart, length)
            if let last = lastMatch(of: pattern, anchor: found, in: window, below: fresh) {
                progress(1)
                let start = windowStart + UInt64(last)
                return start..<(start + count)
            }
            startsEnd = windowStart
            progress(Double(limit - startsEnd) / span)
        }
        return nil
    }

    /// The byte a pattern is found by, and that byte's other case where the
    /// folding lets it have one (the byte itself where it does not).
    ///
    /// Not a hole, so it is found fast and only there is the rest compared.
    /// Not 0x00 or 0xFF where the pattern has another byte — a dump is full
    /// of both, and an anchor on them stops at almost every byte: an address
    /// such as `00 80 66 FF` is found by its 0x80. None for a pattern of
    /// holes alone, which is found nowhere.
    struct Anchor {
        let index: Int
        let byte: UInt8
        let alternative: UInt8

        init?(_ pattern: MaskedPattern) {
            let isWild = pattern.isWild
            guard let index = isWild.indices.first(where: {
                !isWild[$0] && pattern.bytes[$0] != 0x00 && pattern.bytes[$0] != 0xFF
            }) ?? isWild.firstIndex(of: false) else { return nil }
            self.index = index
            byte = pattern.bytes[index]
            alternative = PatternScan.alternativeCase(of: byte, at: index, in: pattern)
        }
    }

    /// The first place at or after `from`, starting below `below`, where
    /// `pattern` matches whole inside `window`.
    static func firstMatch(of pattern: MaskedPattern, anchor: Anchor?, in window: [UInt8],
                           from: Int, below: Int) -> Int? {
        let lastStart = min(below - 1, window.count - pattern.count)
        guard let anchor, from <= lastStart else { return nil }
        let first = anchor.byte, alternative = anchor.alternative
        return window.withUnsafeBufferPointer { buffer -> Int? in
            var start = from
            while start <= lastStart {
                // The next place the anchor byte, or its other case, is.
                var at = start + anchor.index
                let end = lastStart + anchor.index
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
                let candidate = at - anchor.index
                if matchesAt(candidate, pattern, buffer) { return candidate }
                start = candidate + 1
            }
            return nil
        }
    }

    /// The last place starting below `below` where `pattern` matches whole
    /// inside `window`: the window looked through from its end back.
    static func lastMatch(of pattern: MaskedPattern, anchor: Anchor?, in window: [UInt8],
                          below: Int) -> Int? {
        let lastStart = min(below - 1, window.count - pattern.count)
        guard let anchor, lastStart >= 0 else { return nil }
        let first = anchor.byte, alternative = anchor.alternative
        return window.withUnsafeBufferPointer { buffer -> Int? in
            var at = lastStart + anchor.index
            while at >= anchor.index {
                let byte = buffer[at]
                if byte == first || byte == alternative, matchesAt(at - anchor.index, pattern, buffer) {
                    return at - anchor.index
                }
                at -= 1
            }
            return nil
        }
    }

    /// The anchor byte's other case where the folding lets it have one, or the
    /// byte itself.
    fileprivate static func alternativeCase(of byte: UInt8, at index: Int, in pattern: MaskedPattern) -> UInt8 {
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
