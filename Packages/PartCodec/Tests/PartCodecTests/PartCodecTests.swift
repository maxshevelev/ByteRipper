import XCTest
@testable import PartCodec

private struct Bytes: PartReader {
    var bytes: [UInt8]
    var size: UInt64 { UInt64(bytes.count) }
    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard Int(offset) + length <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        return Array(bytes[Int(offset)..<(Int(offset) + length)])
    }
}

final class PartCodecTests: XCTestCase {
    private let parent = PartParent(content: Bytes(bytes: Array(0..<32)), source: 8..<12, name: "dump.bin")

    func testACopyOpensAsTheSourceAndGoesBackOverIt() throws {
        let codec = CopyPartCodec()
        XCTAssertEqual(try codec.decode(parent), [8, 9, 10, 11])
        XCTAssertEqual(try codec.encode([1, 2, 3, 4], into: parent), .overwriting(8..<12, with: [1, 2, 3, 4]))
        XCTAssertTrue(codec.isImmediate)
        XCTAssertTrue(codec.keepsOffsets)
    }

    func testACopyGoesBackOnlyAtItsLength() {
        XCTAssertThrowsError(try CopyPartCodec().encode([1, 2, 3], into: parent)) {
            XCTAssertEqual(($0 as? PartRefusal)?.title.text(in: .english), "The length changed")
        }
    }

    func testAReadOnlyPartOpensAsGivenAndIsRefused() {
        let codec = ReadOnlyPartCodec([7, 7], title: .verbatim("No"), reason: .verbatim("Nothing compresses it again."))
        XCTAssertEqual(try codec.decode(parent), [7, 7])
        XCTAssertThrowsError(try codec.encode([7, 7], into: parent)) {
            XCTAssertEqual($0 as? PartRefusal, PartRefusal(title: .verbatim("No"), message: .verbatim("Nothing compresses it again.")))
        }
        XCTAssertFalse(codec.keepsOffsets)
    }
}
