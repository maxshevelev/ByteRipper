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

    /// A scattered thing opens as its stretches one after another, in the
    /// owner's order, and goes back to the same places: the bytes between them
    /// stay what they were.
    func testAGatheredPartOpensInTheOwnersOrderAndGoesBackToTheSamePlaces() throws {
        let scattered = PartParent(content: Bytes(bytes: Array(0..<32)), source: 4..<16, name: "dump.bin")
        let codec = GatherPartCodec(stretches: [12..<16, 4..<6])

        XCTAssertEqual(try codec.decode(scattered), [12, 13, 14, 15, 4, 5])
        XCTAssertEqual(try codec.encode([0xA, 0xB, 0xC, 0xD, 0xE, 0xF], into: scattered),
                       .overwriting(4..<16, with: [0xE, 0xF, 6, 7, 8, 9, 10, 11, 0xA, 0xB, 0xC, 0xD]))
        XCTAssertFalse(codec.keepsOffsets)
        XCTAssertThrowsError(try codec.encode([1, 2, 3], into: scattered)) {
            XCTAssertEqual(($0 as? PartRefusal)?.title.text(in: .english), "The length changed")
        }
    }
}
