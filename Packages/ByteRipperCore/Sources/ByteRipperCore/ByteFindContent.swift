import Foundation

/// What a search of a dump looks for: the bytes, and how letters compare.
///
/// The same bytes compared exactly and compared folded are two searches, so
/// both are the query; the encoding the bytes came from rides along in the
/// pattern, for the field to show.
public struct ByteQuery: Equatable, Sendable {
    public let pattern: SearchPattern
    public let folding: CaseFolding

    public init(pattern: SearchPattern, folding: CaseFolding) {
        self.pattern = pattern
        self.folding = folding
    }
}

/// A dump's bytes as something `FindIndexer` searches: positions are byte
/// offsets, and the scan is `PatternScan`'s — the one the agent's
/// `find_bytes` and the UEFI Structure's search run, so all three find the
/// same.
///
/// **Matches overlap, always.** After a match the scan looks again one byte
/// after its start, not after its end, so `FF FF` over a run of five 0xFF is
/// four matches. A non-overlapping set depends on where the scan started —
/// `FF FF` in `FF FF FF` is a match at 0 from offset 0 and at 1 from offset 1
/// — so Find Next from the caret could land on a match Find All's set does
/// not hold; an overlapping set is the file's alone. The two differ only for
/// a pattern that overlaps itself: a run, or a mask such as `24 ?? 24` (#33).
///
/// So the steps are by start: Find Next is the first match starting at or
/// after the anchor, Find Previous the last starting before it — a match the
/// reader stands on is passed by one byte, not by its length, and a run is
/// walked a byte at a time either way.
public struct ByteFindContent: FindContent {
    public let storage: ByteStorage
    public let chunkSize: Int

    public init(storage: ByteStorage, chunkSize: Int = SearchEngine.defaultChunkSize) {
        self.storage = storage
        self.chunkSize = chunkSize
    }

    public var extent: UInt64 { storage.size }

    public func matchLength(of query: ByteQuery) -> Int { max(query.pattern.bytes.count, 1) }

    public func firstMatch(of query: ByteQuery, from anchor: UInt64, direction: SearchDirection,
                           shouldCancel: () -> Bool,
                           progress: (Double) -> Void) throws -> Range<UInt64>? {
        let pattern = MaskedPattern(query.pattern, folding: query.folding)
        switch direction {
        case .forward:
            guard anchor < storage.size else { progress(1); return nil }
            var found: Range<UInt64>?
            try SearchEngine.matches(of: [pattern], in: storage, range: anchor..<storage.size,
                                     overlapping: true, chunkSize: chunkSize,
                                     shouldCancel: shouldCancel, progress: progress) { match, _ in
                found = match
                return false
            }
            return found
        case .backward:
            return try SearchEngine.lastMatch(of: pattern, in: storage, before: anchor,
                                              chunkSize: chunkSize, shouldCancel: shouldCancel,
                                              progress: progress)
        }
    }

    public func matchStarts(of query: ByteQuery,
                            shouldCancel: @escaping @Sendable () -> Bool,
                            progress: @escaping @Sendable (Double) -> Void)
        -> AsyncThrowingStream<MatchBatch, any Error> {
        let storage = storage
        let chunkSize = chunkSize
        let pattern = MaskedPattern(query.pattern, folding: query.folding)
        let batchSize = SearchEngine.defaultBatchSize
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    var batch: [UInt64] = []
                    batch.reserveCapacity(min(batchSize, 1024))
                    try SearchEngine.matches(
                        of: [pattern], in: storage, overlapping: true, chunkSize: chunkSize,
                        shouldCancel: shouldCancel, progress: progress,
                        // Every window is an instalment, even an empty one: a
                        // stretch with no match in it is still a stretch the
                        // index now knows about.
                        windowFinished: { covered in
                            continuation.yield(MatchBatch(starts: batch, scannedUpTo: covered))
                            batch.removeAll(keepingCapacity: true)
                        }
                    ) { match, _ in
                        batch.append(match.lowerBound)
                        if batch.count >= batchSize {
                            // Matches are visited in order of start, and they
                            // overlap: what is known complete mid-window is
                            // every start up to this one, not up to its end.
                            continuation.yield(MatchBatch(starts: batch,
                                                          scannedUpTo: match.lowerBound + 1))
                            batch.removeAll(keepingCapacity: true)
                        }
                        return true
                    }
                    if !batch.isEmpty {
                        continuation.yield(MatchBatch(starts: batch, scannedUpTo: storage.size))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A dump's search, held by a pane.
public typealias ByteFindIndexer = FindIndexer<ByteFindContent>
/// Where every occurrence of a dump's search is.
public typealias ByteMatchSet = MatchSet<ByteQuery>
public typealias ByteMatchSetBuilder = MatchSetBuilder<ByteQuery>

extension MatchSet where Query == ByteQuery {
    /// The bytes that were searched.
    public var pattern: SearchPattern { query.pattern }
    /// How their letters were compared.
    public var folding: CaseFolding { query.folding }

    public init(pattern: SearchPattern, folding: CaseFolding, extent: UInt64,
                total: Int, storage: Storage, indexedUpTo: UInt64? = nil) {
        self.init(query: ByteQuery(pattern: pattern, folding: folding),
                  matchLength: pattern.bytes.count, extent: extent, total: total,
                  storage: storage, indexedUpTo: indexedUpTo)
    }

    public init(pattern: SearchPattern, folding: CaseFolding, extent: UInt64,
                starts: [UInt64], indexedUpTo: UInt64? = nil) {
        self.init(query: ByteQuery(pattern: pattern, folding: folding),
                  matchLength: pattern.bytes.count, extent: extent, starts: starts,
                  indexedUpTo: indexedUpTo)
    }
}

extension MatchSetBuilder where Query == ByteQuery {
    public init(pattern: SearchPattern, folding: CaseFolding, extent: UInt64,
                maxIndexBytes: Int = FindLimits.maxIndexBytes) {
        self.init(query: ByteQuery(pattern: pattern, folding: folding),
                  matchLength: pattern.bytes.count, extent: extent,
                  maxIndexBytes: maxIndexBytes)
    }
}
