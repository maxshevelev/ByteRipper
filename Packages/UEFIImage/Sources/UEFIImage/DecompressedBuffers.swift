import Foundation
import FirmwareCompression

/// The buffers compressed sections decompress to, kept so that a branch
/// opened, closed and opened again is decoded once
/// (`Design/UEFI/COMPRESSED_SECTIONS.md` §6.2).
///
/// A decoded DXE volume is megabytes, so what is kept is bounded: past the
/// budget the least recently used buffer goes, and the next read that needs it
/// decodes it again from the file. That is always possible, because a
/// `ByteSpace` names every compressed section on the way in by its offset, and
/// the section headers at those offsets are all a decode needs.
///
/// Shared by every materialization of one tree, which run on whatever thread
/// `Task.detached` picks — so every access takes the lock. A decode itself runs
/// outside it: two expansions that need the same buffer at once may both
/// decode it, which costs time and never correctness.
final class DecompressedBuffers: @unchecked Sendable {
    /// Why a space could not be read: the compressed section that did not
    /// decode, in the space its header is in.
    struct Problem: Error, Equatable {
        var section: UInt64
        var space: ByteSpace
        /// Nil when there was no decodable section at that offset at all —
        /// the bytes changed under a space that named one.
        var algorithm: CompressedSection.Algorithm?
        var failure: FirmwareDecompression.Failure
    }

    private struct Entry {
        var bytes: [UInt8]
        /// The outermost compressed section's bytes in the file — what an edit
        /// has to touch for this buffer to be stale.
        var fileRange: Range<UInt64>
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private var entries: [[UInt64]: Entry] = [:]
    private var clock: UInt64 = 0
    private var held = 0
    private let budget: Int

    init(budget: Int = 256 * 1024 * 1024) {
        self.budget = budget
    }

    /// How many buffers are held, for the tests that pin the cache down.
    var count: Int {
        lock.withLock { entries.count }
    }

    /// A reader over the bytes of `space`: the file itself, or the buffer at
    /// the end of its chain, decoding whatever on the way is not held.
    func reader(
        for space: ByteSpace,
        file: ImageReader,
        limit: UInt64
    ) -> Result<ImageReader, Problem> {
        guard case .decompressed(let chain) = space, let outermost = chain.first else {
            return .success(file)
        }
        var parent = file
        var parentSpace = ByteSpace.file
        var outerRange: Range<UInt64>?

        for depth in chain.indices {
            let key = Array(chain[...depth])
            let offset = chain[depth]
            if let entry = use(key) {
                parent = ImageReader(entry.bytes)
                parentSpace = .decompressed(chain: key)
                outerRange = entry.fileRange
                continue
            }
            guard let located = CompressedSection.locate(at: offset, in: parent) else {
                return .failure(Problem(
                    section: offset, space: parentSpace, algorithm: nil, failure: .corrupt
                ))
            }
            let fileRange = outerRange ?? (outermost..<located.body.upperBound)
            switch CompressedSection.decode(located, in: parent, limit: limit) {
            case .failure(let failure):
                return .failure(Problem(
                    section: offset, space: parentSpace,
                    algorithm: located.algorithm, failure: failure
                ))
            case .success(let decoded):
                store(key, bytes: decoded.bytes, fileRange: fileRange)
                parent = ImageReader(decoded.bytes)
                parentSpace = .decompressed(chain: key)
                outerRange = fileRange
            }
        }
        return .success(parent)
    }

    /// Forgets every buffer whose section an overwrite of `range` touched.
    func drop(overlapping range: Range<UInt64>) {
        lock.withLock {
            removeEntries { $0.fileRange.overlaps(range) }
        }
    }

    /// Forgets every buffer whose section reaches `offset` or beyond — what an
    /// insert or a delete there may have moved.
    func drop(from offset: UInt64) {
        lock.withLock {
            removeEntries { $0.fileRange.upperBound > offset }
        }
    }

    // MARK: - Private

    private func use(_ key: [UInt64]) -> Entry? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock += 1
            entry.lastUse = clock
            entries[key] = entry
            return entry
        }
    }

    private func store(_ key: [UInt64], bytes: [UInt8], fileRange: Range<UInt64>) {
        lock.withLock {
            clock += 1
            if let old = entries[key] { held -= old.bytes.count }
            entries[key] = Entry(bytes: bytes, fileRange: fileRange, lastUse: clock)
            held += bytes.count
            // Never the one just stored: a buffer larger than the whole budget
            // is still the one the caller is about to read.
            while held > budget, entries.count > 1,
                  let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
                held -= oldest.value.bytes.count
                entries[oldest.key] = nil
            }
        }
    }

    private func removeEntries(where stale: (Entry) -> Bool) {
        for (key, entry) in entries where stale(entry) {
            held -= entry.bytes.count
            entries[key] = nil
        }
    }
}
