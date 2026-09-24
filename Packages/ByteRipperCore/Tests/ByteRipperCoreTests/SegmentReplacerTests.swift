import Foundation
import XCTest
@testable import ByteRipperCore

/// §21.6 the segment replacer: a piece's bytes replaced by the contents of a
/// donor — the same length, or, when the caller asks for it by name, the
/// donor's (§21.7). The donor is streamed in bounded chunks and the whole
/// swap is one undo transaction, so the tests drive it directly against an
/// in-memory document and check the bytes, the transaction count, and the
/// length-mismatch refusal.
final class SegmentReplacerTests: XCTestCase {
    /// An in-memory document over `bytes` — the untitled "New File" shape, so no
    /// file on disk is involved.
    private func makeDocument(_ bytes: [UInt8]) -> BinaryDocument {
        BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: bytes)),
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("replacer-\(UUID().uuidString).bin"),
            readOnly: false
        )
    }

    // MARK: - The bytes of a swap

    /// The donor's bytes land in the range; the rest of the document is
    /// untouched, and a same-length swap changes no size.
    func testTheDonorsBytesLandInTheRange() throws {
        let doc = makeDocument([UInt8](0..<16))  // 00 01 … 0F
        let donor = ArrayStorage([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])

        try SegmentReplacer.replace(range: 8..<16, in: doc, withContentsOf: donor)

        XCTAssertEqual(try doc.read(at: 8, length: 8),
                       [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7],
                       "the range holds the donor's bytes")
        XCTAssertEqual(try doc.read(at: 0, length: 8), [UInt8](0..<8),
                       "the other half is untouched")
        XCTAssertEqual(doc.size, 16, "a same-length swap changes no size")
    }

    // MARK: - One transaction

    /// A swap bigger than one chunk is still one undo transaction: the whole
    /// swap coalesces into a single commit, so undo takes it back as one step.
    /// Without the edit group, each chunk's `overwrite` would commit on its own.
    func testAMultiChunkSwapIsOneTransaction() throws {
        let size = 1536 * 1024  // 1.5 MiB: two 1 MiB chunks
        let doc = makeDocument((0..<size).map { UInt8($0 % 251) })
        let donor = ArrayStorage((0..<size).map { UInt8(($0 + 7) % 251) })
        var commits = 0
        doc.onTransactionCommitted = { commits += 1 }

        try SegmentReplacer.replace(range: 0..<UInt64(size), in: doc, withContentsOf: donor)

        XCTAssertEqual(commits, 1, "the whole multi-chunk swap is one transaction")
        XCTAssertEqual(try doc.read(at: 0, length: size),
                       (0..<size).map { UInt8(($0 + 7) % 251) },
                       "every byte lands at its own offset")
    }

    // MARK: - The length-mismatch refusal

    /// A donor whose length differs from the piece's is refused with both sizes
    /// named, and the document is left exactly as it was.
    func testALengthMismatchIsRefusedWithBothSizes() throws {
        let doc = makeDocument([UInt8](0..<16))
        let original = try doc.read(at: 0, length: 16)
        let donor = ArrayStorage([0xB0, 0xB1, 0xB2])  // 3 bytes, not 8

        XCTAssertThrowsError(
            try SegmentReplacer.replace(range: 8..<16, in: doc, withContentsOf: donor)
        ) { error in
            XCTAssertEqual(error as? SegmentReplaceError,
                           .lengthMismatch(pieceLength: 8, donorLength: 3),
                           "the refusal names both sizes")
        }
        XCTAssertEqual(try doc.read(at: 0, length: 16), original,
                       "a refused swap changes nothing")
        XCTAssertEqual(doc.size, 16)
    }

    // MARK: - A swap that changes the length (§21.7)

    /// A longer donor writes the stretch both sides have in place and adds the
    /// rest at the piece's tail, so the bytes after the piece move by exactly
    /// the difference and nothing inside it is disturbed.
    func testALongerDonorAddsItsTailAtThePiecesEnd() throws {
        let doc = makeDocument([UInt8](0..<16))
        let donor = ArrayStorage([0xA0, 0xA1, 0xA2, 0xA3])

        let outcome = try SegmentReplacer.replace(range: 4..<6, in: doc,
                                                  withContentsOf: donor,
                                                  allowingLengthChange: true)

        XCTAssertEqual(outcome, .inserted(at: 6, length: 2))
        XCTAssertEqual(doc.size, 18)
        XCTAssertEqual(try doc.read(at: 4, length: 4), [0xA0, 0xA1, 0xA2, 0xA3])
        XCTAssertEqual(try doc.read(at: 8, length: 2), [0x06, 0x07],
                       "the bytes after the piece moved right by the difference")
        XCTAssertEqual(try doc.read(at: 0, length: 4), [UInt8](0..<4),
                       "and the bytes before it did not move at all")
    }

    /// A shorter donor removes the leftover from the piece's tail, and the
    /// bytes after it move left by the difference.
    func testAShorterDonorCutsThePiecesTail() throws {
        let doc = makeDocument([UInt8](0..<16))
        let donor = ArrayStorage([0xA0, 0xA1])

        let outcome = try SegmentReplacer.replace(range: 4..<8, in: doc,
                                                  withContentsOf: donor,
                                                  allowingLengthChange: true)

        XCTAssertEqual(outcome, .deleted(range: 6..<8))
        XCTAssertEqual(doc.size, 14)
        XCTAssertEqual(try doc.read(at: 4, length: 2), [0xA0, 0xA1])
        XCTAssertEqual(try doc.read(at: 6, length: 2), [0x08, 0x09])
    }

    /// The whole of a length-changing swap — the overwrite and the tail — is
    /// one transaction, so undo takes it back in one step.
    func testALengthChangingSwapIsOneTransaction() throws {
        let doc = makeDocument([UInt8](0..<16))
        let donor = ArrayStorage([0xA0, 0xA1, 0xA2, 0xA3])
        try SegmentReplacer.replace(range: 4..<6, in: doc, withContentsOf: donor,
                                    allowingLengthChange: true)

        XCTAssertNotNil(try doc.undo())

        XCTAssertEqual(doc.size, 16)
        XCTAssertEqual(try doc.read(at: 0, length: 16), [UInt8](0..<16))
        XCTAssertFalse(doc.undoHistory.canUndo, "one step took the whole swap back")
    }

    /// Without being asked for by name, a mismatch is still refused before a
    /// byte is written: making it an insert-and-shift is a decision (§21.6).
    func testAMismatchIsStillRefusedByDefault() throws {
        let doc = makeDocument([UInt8](0..<16))
        let donor = ArrayStorage([0xA0, 0xA1])

        XCTAssertThrowsError(
            try SegmentReplacer.replace(range: 4..<8, in: doc, withContentsOf: donor)
        ) { error in
            XCTAssertEqual(error as? SegmentReplaceError,
                           .lengthMismatch(pieceLength: 4, donorLength: 2))
        }
        XCTAssertEqual(doc.size, 16)
    }

    // MARK: - The donor shrinking under the swap (§21.6)

    /// A donor read that comes back short means the donor shrank under the swap.
    /// Breaking out of the loop there committed HALF a replacement as one
    /// transaction and called it a success: the piece held the donor's first
    /// chunks and the document's own bytes after them. The swap must fail and
    /// leave the document exactly as it was.
    func testAShortDonorReadLeavesTheDocumentUnchanged() throws {
        let size = UInt64(3 * SegmentReplacer.chunkSize)
        let original = [UInt8](repeating: 0x11, count: Int(size))
        let document = BinaryDocument(
            storage: EditOverlayStorage(base: MemoryBackedStorage(bytes: original)),
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("replace-\(UUID().uuidString).bin"),
            readOnly: false
        )
        let donor = ShrinkingStorage(size: size, shrinksOnRead: 2)

        XCTAssertThrowsError(
            try SegmentReplacer.replace(range: 0..<size, in: document, withContentsOf: donor)
        ) { error in
            XCTAssertEqual(error as? StorageError, .readFailed)
        }

        XCTAssertEqual(try document.read(at: 0, length: Int(size)), original,
                       "not one byte of a failed swap survives")
        XCTAssertFalse(document.undoHistory.canUndo,
                       "and it records no transaction to undo")
    }
}
