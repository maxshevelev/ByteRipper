import ByteRipperCore
import Foundation
import PartCodec

/// A document's content frozen as it is now, unsaved edits included, for a
/// part's codec to decode from and encode into (`PartCodec`).
///
/// The same snapshot a tool-module's reader is (`PaneToolHost.snapshot()`):
/// it copies no bytes, cannot be disturbed by later edits, and is readable
/// from any thread — which is what lets a body be decompressed, or an image
/// laid out again, off the main actor.
struct DocumentPartReader: PartReader {
    private let storage: any ByteStorage

    /// Where a snapshot puts what it has to keep aside. One for every part:
    /// the snapshots are short-lived, and none of them owns the store.
    private static let scratch = TemporaryFileStore()

    @MainActor init(document: BinaryDocument) throws {
        guard let overlay = document.storage as? EditOverlayStorage else {
            throw CocoaError(.fileReadUnknown)
        }
        storage = try overlay.contentSnapshot(scratch: Self.scratch)
    }

    var size: UInt64 { storage.size }

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard length >= 0, offset &+ UInt64(length) <= size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try storage.read(at: offset, length: length)
    }
}
