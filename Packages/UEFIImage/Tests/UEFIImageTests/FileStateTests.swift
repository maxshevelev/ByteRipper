import XCTest
@testable import UEFIImage

/// What a file's state byte says about its header (§5.5), read under the
/// volume's erase polarity and under the file's own polarity bit.
final class FileStateTests: XCTestCase {
    func testAnOrdinaryFileIsNotMarked() {
        // Header and data valid, stored inverted under polarity 1.
        XCTAssertFalse(FileState.marksHeaderInvalid(0xF8, volumeErasePolarity: true))
        // Marked for update, then deleted: still a header, not an invalid one.
        XCTAssertFalse(FileState.marksHeaderInvalid(0xF0, volumeErasePolarity: true))
        XCTAssertFalse(FileState.marksHeaderInvalid(0xE0, volumeErasePolarity: true))
        // Under polarity 0 the same states are written straight.
        XCTAssertFalse(FileState.marksHeaderInvalid(0x07, volumeErasePolarity: false))
    }

    /// Every bit written under polarity 1 is header invalid; under its own
    /// polarity bit, 0 — nothing is marked valid. Invalid both ways.
    func testEveryBitWrittenMarksTheHeaderInvalid() {
        XCTAssertTrue(FileState.marksHeaderInvalid(0x00, volumeErasePolarity: true))
        XCTAssertTrue(FileState.marksHeaderInvalid(0x00, volumeErasePolarity: nil))
        // HEADER_INVALID set on top of a valid header, polarity 1.
        XCTAssertTrue(FileState.marksHeaderInvalid(0xD8, volumeErasePolarity: true))
    }

    /// Invalid under the volume's polarity and valid under the file's own:
    /// a file written the other way round, which is checked as a file.
    func testValidUnderEitherReadingIsNotMarked() {
        XCTAssertFalse(FileState.marksHeaderInvalid(0x07, volumeErasePolarity: true))
        XCTAssertFalse(FileState.marksHeaderInvalid(0x07, volumeErasePolarity: nil))
    }

    /// A file that owes no checksum has nothing to repair.
    func testAFileMarkedInvalidHasNoRepairs() {
        let bytes = TestImage.file(state: 0x00, body: [1, 2], headerChecksum: 0x11, bodyChecksum: 0x22)
        let file = UEFINode(kind: .file, name: "", header: 0..<0x18, body: 0x18..<0x1A)
        XCTAssertEqual(UEFIChecksums.repairs(for: file, volumeRevision: 2, volumeErasePolarity: true,
                                             in: ImageReader(bytes)), [])

        let marked = TestImage.file(state: 0xF8, body: [1, 2], headerChecksum: 0x11, bodyChecksum: 0x22)
        XCTAssertEqual(UEFIChecksums.repairs(for: file, volumeRevision: 2, volumeErasePolarity: true,
                                             in: ImageReader(marked)).count, 2, "an ordinary file with both sums stale")
    }
}
