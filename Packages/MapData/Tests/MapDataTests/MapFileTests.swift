import XCTest
@testable import MapData

final class MapFileTests: XCTestCase {
    /// A header with no sections, a given version and kind, and a correct
    /// checksum. The record readers are exercised by the two packages that
    /// own them; this pins the envelope's refusals.
    private func header(version: UInt32 = 1, kind: UInt16 = 1,
                        format: UInt16 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = UInt8(ascii: "B")
        bytes[1] = UInt8(ascii: "R")
        bytes[2] = UInt8(ascii: "M")
        bytes[3] = UInt8(ascii: "1")
        func put16(_ value: UInt16, _ at: Int) {
            bytes[at] = UInt8(truncatingIfNeeded: value)
            bytes[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func put32(_ value: UInt32, _ at: Int) {
            bytes[at] = UInt8(truncatingIfNeeded: value)
            bytes[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[at + 2] = UInt8(truncatingIfNeeded: value >> 16)
            bytes[at + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
        put16(format, 4)
        put16(32, 6)
        put32(version, 8)
        put16(kind, 12)
        put32(0, 16)
        let checksum = MapFile.fnv1a32(bytes)
        put32(checksum, 20)
        return Data(bytes)
    }

    func testAWellFormedHeaderLoads() throws {
        let file = try MapFile(data: header(version: 7), expectedVersion: 7)
        XCTAssertEqual(file.kind, .strap)
        XCTAssertEqual(file.version, 7)
        XCTAssertNil(file.section(.strings))
    }

    func testAVersionTheCodeDoesNotReadIsRefused() {
        XCTAssertThrowsError(try MapFile(data: header(version: 2),
                                         expectedVersion: 1)) { error in
            XCTAssertEqual(error as? MapDataError,
                           .versionMismatch(file: 2, code: 1))
        }
    }

    func testAnotherFormatIsRefused() {
        XCTAssertThrowsError(try MapFile(data: header(format: 2),
                                         expectedVersion: 1)) { error in
            XCTAssertEqual(error as? MapDataError, .unsupportedFormat(2))
        }
    }

    func testBadMagicAndUnknownKindAreRefused() {
        var bytes = [UInt8](header(version: 1))
        bytes[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try MapFile(data: Data(bytes), expectedVersion: 1))
        XCTAssertThrowsError(try MapFile(data: header(kind: 99),
                                         expectedVersion: 1)) { error in
            XCTAssertEqual(error as? MapDataError, .wrongKind(99))
        }
    }

    func testAnEditedByteFailsTheChecksum() {
        var bytes = [UInt8](header(version: 1))
        bytes[31] ^= 0xFF
        XCTAssertThrowsError(try MapFile(data: Data(bytes), expectedVersion: 1))
    }

    func testATruncatedHeaderIsRefused() {
        XCTAssertThrowsError(try MapFile(data: Data([0, 1, 2]), expectedVersion: 1))
    }
}
