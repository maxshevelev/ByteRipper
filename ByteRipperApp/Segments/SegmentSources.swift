import Foundation
import ByteRipperCore

/// What a `SegmentSourceID` stands for: a file a piece's bytes came from
/// (§21.7).
///
/// The id is in the partition (a value undo copies); the file is here, in a
/// table that lives as long as the pane does. That split is what makes a link
/// survive undo: a snapshot restored from before a join still names sources by
/// id, and the table still knows what each id is, even though nothing in the
/// partition points at them any more.
///
/// Entries are never removed while the pane is open. There are a handful of
/// them — one per file ever joined or swapped in — and dropping one the moment
/// no piece references it would break exactly the redo that brings the piece
/// back.
@MainActor
final class SegmentSources {
    /// One source file. The reader is opened lazily and dropped when the file
    /// changes underneath, so a source that is never read costs nothing and one
    /// that was rewritten is re-read rather than remembered.
    struct Source {
        let id: SegmentSourceID
        let url: URL

        /// What the form, the menus and the alerts call it.
        var name: String { url.lastPathComponent }
    }

    private var sources: [SegmentSourceID: Source] = [:]
    private var idsByPath: [String: SegmentSourceID] = [:]
    private var readers: [SegmentSourceID: any ByteStorage] = [:]
    private var nextRaw = 0

    /// The step a piece is compared to its source in, so a 16 MB segment is
    /// never read whole to answer "does it still match?" — the same 1 MiB the
    /// segment writer, the replacer and the join stream in.
    static let compareChunk = 1024 * 1024

    /// The id for `url`, minting one the first time the file is seen. The same
    /// file joined twice is one source: two pieces then point at one entry, and
    /// a change to it is announced once.
    func id(for url: URL) -> SegmentSourceID {
        let key = url.standardizedFileURL.path
        if let existing = idsByPath[key] { return existing }
        let id = SegmentSourceID(raw: nextRaw)
        nextRaw += 1
        idsByPath[key] = id
        sources[id] = Source(id: id, url: url)
        return id
    }

    func source(_ id: SegmentSourceID) -> Source? { sources[id] }

    /// The id already minted for `url`, if any — what the save path asks before
    /// it writes, to find out whether the file it is about to replace is some
    /// piece's source.
    func existingID(for url: URL) -> SegmentSourceID? {
        idsByPath[url.standardizedFileURL.path]
    }

    /// A reader for the source's current bytes on disk, or nil when the file
    /// cannot be opened (deleted, renamed, or no longer readable). Opened once
    /// and kept; `invalidate` drops it when the file changed.
    func reader(_ id: SegmentSourceID) -> (any ByteStorage)? {
        if let open = readers[id] { return open }
        guard let url = sources[id]?.url,
              let storage = try? FileBackedStorage(url: url) else { return nil }
        readers[id] = storage
        return storage
    }

    /// Drops the open reader for `id`, so the next read re-opens the file. What
    /// an external change to a source runs: the link is to the file, not to the
    /// bytes it held when it was linked, so the baseline is whatever is on disk
    /// now (§21.7).
    func invalidate(_ id: SegmentSourceID) {
        readers[id] = nil
    }

    /// Takes over another pane's table, ids and all — what a Duplicate does
    /// (§23): the copy holds the source's partition, so it has to hold the same
    /// links, and a link is only as good as the id it names.
    func adopt(_ other: SegmentSources) {
        sources = other.sources
        idsByPath = other.idsByPath
        nextRaw = other.nextRaw
        readers.removeAll()
    }

    /// Drops every open reader — what a close does, so no source file is held
    /// open by a pane that no longer shows anything from it.
    func closeReaders() {
        readers.removeAll()
    }
}

/// What a byte is painted *against* (§6, §21.7): the file the document was last
/// saved to, or — for a piece that came from somewhere else — that piece's own
/// source file.
///
/// A value, taken once and read many times: the hex view builds one per draw and
/// the minimap hands one to its background pass, so what a page is measured
/// against cannot change halfway through it.
///
/// Everything is a **span**: a stretch of the document, a reader, and the offset
/// in that reader the stretch opens at. A document with a file behind it is one
/// span over the whole of it; an image a join left is one span per linked piece.
/// Whatever no span covers has no reference, and is never painted modified —
/// except past `beyondFrom`, where the document has outgrown the file it is
/// measured against and every byte is new by definition.
struct ModifiedBaseline: Sendable {
    /// One stretch of the document measured against a reader.
    struct Span: Sendable {
        /// The document offsets this span answers for.
        let range: Range<UInt64>
        let storage: any ByteStorage
        /// The reader offset `range.lowerBound` stands for.
        let sourceOffset: UInt64
        /// The reader offset the span's own stretch ends at. Past it the span
        /// still answers — with "new" — because those document bytes are inside
        /// the piece and came from nowhere: an insert grew it beyond what it was
        /// taken from. Nil means "as far as the reader goes", which is what a
        /// whole saved file is.
        let sourceLimit: UInt64?

        init(range: Range<UInt64>, storage: any ByteStorage,
             sourceOffset: UInt64, sourceLimit: UInt64? = nil) {
            self.range = range
            self.storage = storage
            self.sourceOffset = sourceOffset
            self.sourceLimit = sourceLimit
        }
    }

    let spans: [Span]
    /// The offset past which every byte is modified whatever it holds — the
    /// saved file's end. Nil when there is no such edge: an image with no file
    /// of its own says nothing about bytes no piece came from.
    let beyondFrom: UInt64?

    static let none = ModifiedBaseline(spans: [], beyondFrom: nil)

    /// Whether anything is painted modified at all. A plain untitled document
    /// with no links has no reference — every byte would read as modified, and
    /// the dirty marker already says it is unsaved.
    var marksAnything: Bool { !spans.isEmpty || beyondFrom != nil }

    /// What one byte of the document is measured against.
    enum Reference: Equatable {
        /// Nothing is: the byte has no reference and is never painted modified.
        case unmarked
        /// The byte the reference holds at this offset.
        case byte(UInt8)
        /// The reference ends before this offset — the byte is new here, and
        /// counts as modified whatever it holds.
        case beyond
    }

    /// The references for a stretch of the document, read once.
    ///
    /// The bytes are kept as one flat buffer aligned to `range`, with the
    /// stretches it actually answers for listed beside it, so a consumer that
    /// compares whole slices (the minimap, §19.4) can `memcmp` a covered slice
    /// instead of walking it byte by byte — which is the difference between a
    /// few milliseconds and a few hundred over a 16 MB dump.
    struct Block {
        let range: Range<UInt64>
        /// Reference bytes aligned to `range`; meaningless outside `covered`.
        private(set) var bytes: [UInt8]
        /// Where `bytes` holds a real reference.
        private(set) var covered: [Range<UInt64>] = []
        /// Where the reference ends before the content does.
        private(set) var beyond: [Range<UInt64>] = []

        init(range: Range<UInt64>) {
            self.range = range
            bytes = [UInt8](repeating: 0, count: max(0, Int(range.upperBound - range.lowerBound)))
        }

        fileprivate mutating func put(_ read: [UInt8], at offset: UInt64) {
            guard !read.isEmpty else { return }
            let from = Int(offset - range.lowerBound)
            for i in 0..<read.count where bytes.indices.contains(from + i) {
                bytes[from + i] = read[i]
            }
            covered.append(offset..<(offset + UInt64(read.count)))
        }

        fileprivate mutating func markBeyond(_ r: Range<UInt64>) {
            guard r.lowerBound < r.upperBound else { return }
            beyond.append(r)
        }

        /// What the byte at `offset` is measured against.
        func reference(at offset: UInt64) -> Reference {
            if covered.contains(where: { $0.contains(offset) }) {
                let index = Int(offset - range.lowerBound)
                return bytes.indices.contains(index) ? .byte(bytes[index]) : .unmarked
            }
            if beyond.contains(where: { $0.contains(offset) }) { return .beyond }
            return .unmarked
        }

        /// Whether every byte of `slice` has a reference in `bytes` — the
        /// condition for comparing it with one `memcmp`.
        func isFullyCovered(_ slice: Range<UInt64>) -> Bool {
            covered.contains { $0.lowerBound <= slice.lowerBound && $0.upperBound >= slice.upperBound }
        }

        /// Whether any byte of `slice` is past its reference's end, which makes
        /// the slice modified without reading a byte of it.
        func touchesBeyond(_ slice: Range<UInt64>) -> Bool {
            beyond.contains { $0.lowerBound < slice.upperBound && $0.upperBound > slice.lowerBound }
        }

        /// Whether no byte of `slice` has a reference at all.
        func isUnreferenced(_ slice: Range<UInt64>) -> Bool {
            !covered.contains { $0.lowerBound < slice.upperBound && $0.upperBound > slice.lowerBound }
                && !touchesBeyond(slice)
        }
    }

    /// The block for `range`: one read per span it crosses.
    func block(in range: Range<UInt64>) -> Block {
        var block = Block(range: range)
        guard range.lowerBound < range.upperBound else { return block }
        for span in spans {
            let lower = max(span.range.lowerBound, range.lowerBound)
            let upper = min(span.range.upperBound, range.upperBound)
            guard lower < upper else { continue }
            let sourceStart = span.sourceOffset + (lower - span.range.lowerBound)
            let sourceEnd = min(span.storage.size, span.sourceLimit ?? .max)
            let wanted = upper - lower
            let available = sourceStart < sourceEnd ? min(wanted, sourceEnd - sourceStart) : 0
            if available > 0,
               let read = try? span.storage.read(at: sourceStart, length: Int(available)),
               !read.isEmpty {
                block.put(read, at: lower)
                // A source that has fewer bytes than the span claims leaves the
                // rest of it new: the piece has outgrown what it came from.
                block.markBeyond((lower + UInt64(read.count))..<upper)
            } else {
                block.markBeyond(lower..<upper)
            }
        }
        if let beyondFrom, beyondFrom < range.upperBound {
            block.markBeyond(max(beyondFrom, range.lowerBound)..<range.upperBound)
        }
        return block
    }

    /// The reference for every byte of `range`, in order — what the hex view
    /// paints a drawn page from.
    func references(in range: Range<UInt64>) -> [Reference] {
        let count = Int(range.upperBound - range.lowerBound)
        guard count > 0 else { return [] }
        let block = block(in: range)
        return (0..<count).map { block.reference(at: range.lowerBound + UInt64($0)) }
    }
}
