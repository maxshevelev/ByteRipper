import Foundation

/// Which way a search goes from where the reader is.
public enum SearchDirection: Sendable {
    case forward
    case backward
}

/// What one stretch of an index scan found: the starts of the matches in it,
/// in order, and how far the scan has now covered.
///
/// A scan reports as it goes, so the matches it has covered can be shown while
/// the rest of the content is still being scanned, and only what needs the
/// whole content — the total, the wrap, an ordinal — waits for the end (§11).
public struct MatchBatch: Sendable, Equatable {
    public let starts: [UInt64]
    /// Half-open: matches at or above this position are not known yet.
    public let scannedUpTo: UInt64

    public init(starts: [UInt64], scannedUpTo: UInt64) {
        self.starts = starts
        self.scannedUpTo = scannedUpTo
    }
}

/// Something a search can run over: the bytes of a dump, a text.
///
/// The content knows how to scan itself for a query; everything a search does
/// with the scans — the pass over several candidates, the index as it fills,
/// the steps and the wrap — is `FindIndexer`'s, the same for every content.
///
/// Positions are offsets in the content's own units: bytes for a dump, UTF-16
/// units for a text. Every match of one query is `matchLength(of:)` long.
///
/// A content is a value the scans can read from another thread. It need not
/// stay the same: when what it holds changes, the indexer's owner says so
/// (`FindIndexer.invalidate`), and the offsets found before are dropped.
public protocol FindContent: Sendable {
    associatedtype Query: Equatable & Sendable

    /// How long the content is: the end of the last position a match can
    /// cover.
    var extent: UInt64 { get }

    /// How long every match of `query` is.
    func matchLength(of query: Query) -> Int

    /// The first match of `query` from `anchor` in `direction`, not wrapping —
    /// forward, the first starting at or after `anchor`; backward, the last
    /// ending at or before it. Nil when there is none that way.
    ///
    /// Runs on whatever thread calls it. Throws `CancellationError` once
    /// `shouldCancel` says so, and may throw when the content cannot be read
    /// or the query is not one it can look for.
    func firstMatch(of query: Query, from anchor: UInt64, direction: SearchDirection,
                    shouldCancel: () -> Bool,
                    progress: (Double) -> Void) throws -> Range<UInt64>?

    /// Every match of `query`, from the start of the content to its end, in
    /// batches as the scan goes. The scan runs off the caller's thread, stops
    /// once `shouldCancel` says so, and reports how far it has got through
    /// `progress`, as a fraction.
    func matchStarts(of query: Query,
                     shouldCancel: @escaping @Sendable () -> Bool,
                     progress: @escaping @Sendable (Double) -> Void)
        -> AsyncThrowingStream<MatchBatch, any Error>
}

/// The search a press of Return runs before there is an index: the candidates
/// in order, until one of them finds something (§11).
///
/// Each candidate is two scans: one from the anchor in the direction asked,
/// and — failing that — one from the content's other end, which is the wrap.
/// So "this candidate finds nothing" means nothing anywhere, not merely
/// nothing ahead of the reader, and the pass moves on to the next candidate
/// only when it is sure. A plain search is a pass of one; the dump's Smart
/// Search is a pass of one candidate per encoding.
public enum FindPass {
    /// The candidate that found something, where, and whether the scan had to
    /// come round the end to find it.
    public struct Found<Query: Equatable & Sendable>: Equatable, Sendable {
        /// Its position among the candidates.
        public let index: Int
        public let query: Query
        public let range: Range<UInt64>
        public let wrapped: Bool

        public init(index: Int, query: Query, range: Range<UInt64>, wrapped: Bool) {
            self.index = index
            self.query = query
            self.range = range
            self.wrapped = wrapped
        }
    }

    /// Runs the candidates in order until one finds something; nil when none
    /// does. `progress` covers the whole pass: each candidate owns its share,
    /// and each of its two scans half of that share. Cancelling through
    /// `shouldCancel` throws `CancellationError` from the scan in flight.
    public static func firstMatch<Content: FindContent>(
        among candidates: [Content.Query],
        in content: Content,
        from anchor: UInt64,
        direction: SearchDirection,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Found<Content.Query>? {
        guard !candidates.isEmpty else { return nil }
        let total = Double(candidates.count)
        for (position, query) in candidates.enumerated() {
            let base = Double(position)
            func scan(from offset: UInt64, half: Double) throws -> Range<UInt64>? {
                try content.firstMatch(of: query, from: offset, direction: direction,
                                       shouldCancel: shouldCancel,
                                       progress: { progress((base + half + $0 / 2) / total) })
            }
            if let range = try scan(from: anchor, half: 0) {
                return Found(index: position, query: query, range: range, wrapped: false)
            }
            let edge: UInt64 = direction == .forward ? 0 : content.extent
            if let range = try scan(from: edge, half: 0.5) {
                return Found(index: position, query: query, range: range, wrapped: true)
            }
            progress((base + 1) / total)
        }
        return nil
    }
}
