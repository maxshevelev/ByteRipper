import XCTest
@testable import UEFIImage

/// A pad file's body, read the way UEFITool's `parsePadFileBody` reads it:
/// nothing when it is erased; otherwise the leading erased bytes, rounded down
/// to eight, as free space, and the rest as the Startup AP data or as data
/// that has no business there.
final class PadFileBodyTests: XCTestCase {
    private func padFile(in body: [UInt8]) -> (UEFINode, UEFIImage) {
        let file = TestImage.file(guid: .zero, type: FFS.padType, body: body)
        let parsed = UEFIParser.parse(TestImage.volume(length: 0x400, files: [file]))
        return (parsed.roots[0].children[0], parsed)
    }

    private let erased = { (count: Int) in [UInt8](repeating: 0xFF, count: count) }

    func testAnErasedPadFileHoldsNothing() {
        let (file, parsed) = padFile(in: erased(0x40))
        XCTAssertTrue(file.children.isEmpty)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    func testTheStartupApDataIsRecognisedAfterTheFreeSpace() {
        let (file, parsed) = padFile(in: erased(0x30) + FFS.startupApDataX86_128K + [0x11, 0x22])
        let start = file.body.lowerBound

        XCTAssertEqual(file.children.map(\.kind), [.freeSpace, .startupApData])
        XCTAssertEqual(file.children[0].range, start..<(start + 0x30))
        XCTAssertEqual(file.children[1].range, (start + 0x30)..<file.body.upperBound)
        XCTAssertTrue(file.children[1].isFixed)
        XCTAssertEqual(file.children[1].uefiItemSubtype, UEFITypes.Sub.x86128kStartupApDataEntry)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// The free space is rounded down to eight, so the data starts on an
    /// eight-byte boundary with a few erased bytes in front of it.
    func testTheFreeSpaceIsRoundedDownToEight() {
        let (file, _) = padFile(in: erased(0x2B) + [0x12, 0x34])
        let start = file.body.lowerBound
        XCTAssertEqual(file.children[0].range, start..<(start + 0x28))
        XCTAssertEqual(file.children[1].range.lowerBound, start + 0x28)
    }

    /// Fewer than eight erased bytes are not free space: the data is the
    /// whole body.
    func testFewerThanEightErasedBytesAreNotFreeSpace() {
        let (file, _) = padFile(in: erased(4) + [0x12, 0x34])
        XCTAssertEqual(file.children.map(\.kind), [.padding])
        XCTAssertEqual(file.children[0].range, file.body)
    }

    /// Anything else is data, kept and reported.
    func testOtherDataIsReported() {
        let (file, parsed) = padFile(in: erased(0x10) + Array("__KEYM__".utf8))
        XCTAssertEqual(file.children.map(\.kind), [.freeSpace, .padding])
        XCTAssertFalse(file.children[1].isErased)
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.nonUEFIDataInPadFile])
        XCTAssertEqual(parsed.diagnostics.first?.offset, file.children[1].range.lowerBound)
    }
}
