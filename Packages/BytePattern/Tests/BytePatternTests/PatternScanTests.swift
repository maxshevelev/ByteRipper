import XCTest
@testable import BytePattern

/// The scan over bytes the caller reads: holes, case, and a match across the
/// edge of a window.
final class PatternScanTests: XCTestCase {
    private func starts(_ patterns: [MaskedPattern], in bytes: [UInt8], chunk: Int = 4,
                        overlapping: Bool = false) throws -> [UInt64] {
        var found: [UInt64] = []
        try PatternScan.matches(of: patterns, size: UInt64(bytes.count), overlapping: overlapping, chunkSize: chunk,
                                read: { Array(bytes[Int($0)..<min(bytes.count, Int($0) + $1)]) }) { range, _ in
            found.append(range.lowerBound)
            return true
        }
        return found
    }

    func testAHoleMatchesAnyByteAndAMatchAcrossAWindowIsFoundOnce() throws {
        let bytes: [UInt8] = [0, 0, 0x24, 0x99, 0x4D, 0x49, 0, 0x24, 0x00, 0x4D, 0x49]
        XCTAssertEqual(try starts([try MaskedPattern.hex("24 ?? 4D 49")], in: bytes), [2, 7])
    }

    func testTextIsFoundInEitherCaseInASCIIAndInUTF16() throws {
        let bytes = Array("xx Setup ".utf8) + [0x53, 0, 0x45, 0, 0x54, 0, 0x55, 0, 0x50, 0]
        XCTAssertEqual(try starts([try MaskedPattern.ascii("SETUP", ignoringCase: true)], in: bytes), [3])
        XCTAssertEqual(try starts([try MaskedPattern.utf16LE("setup", ignoringCase: true)], in: bytes), [9])
        XCTAssertEqual(try starts([try MaskedPattern.ascii("SETUP", ignoringCase: false)], in: bytes), [])
    }

    func testOverlappingMatchesAreCountedOnlyWhenAsked() throws {
        let bytes = [UInt8](repeating: 0x41, count: 4)
        let pattern = try MaskedPattern.ascii("AA", ignoringCase: false)
        XCTAssertEqual(try starts([pattern], in: bytes), [0, 2])
        XCTAssertEqual(try starts([pattern], in: bytes, overlapping: true), [0, 1, 2])
    }

    func testAPatternThatIsNotOneIsRefused() {
        XCTAssertThrowsError(try MaskedPattern.hex("?? ??"))
        XCTAssertThrowsError(try MaskedPattern.hex("4G"))
        XCTAssertThrowsError(try MaskedPattern.ascii("Привет", ignoringCase: false))
        XCTAssertThrowsError(try MaskedPattern.ascii("", ignoringCase: false))
    }
}
