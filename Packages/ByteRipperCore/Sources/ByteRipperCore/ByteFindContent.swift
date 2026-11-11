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
/// offsets, and the scans are `SearchEngine`'s.
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
        try SearchEngine.find(pattern: query.pattern.bytes, in: storage, from: anchor,
                              direction: direction, folding: query.folding,
                              chunkSize: chunkSize, shouldCancel: shouldCancel,
                              progress: progress)
    }

    public func matchStarts(of query: ByteQuery,
                            shouldCancel: @escaping @Sendable () -> Bool,
                            progress: @escaping @Sendable (Double) -> Void)
        -> AsyncThrowingStream<MatchBatch, any Error> {
        SearchEngine.matchStartsStream(pattern: query.pattern.bytes, in: storage,
                                       folding: query.folding, chunkSize: chunkSize,
                                       shouldCancel: shouldCancel, progress: progress)
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
