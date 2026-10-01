import XCTest
@testable import UEFIImage

/// A Mac's microcode volume: no file system inside, a run of microcode images
/// after a `0x100`-byte header, and padding after the last one — read the way
/// UEFITool's `parseMicrocodeVolumeBody` reads it.
final class AppleMicrocodeVolumeTests: XCTestCase {
    /// A volume with the Apple microcode GUID whose body, at `0x100`, is `body`.
    private func volume(_ body: [UInt8]) -> [UInt8] {
        // The standard header is 0x48 bytes; the reference takes 0x100 for
        // this volume whatever the header says, so the gap is filler.
        let filler = [UInt8](repeating: 0xFF, count: Int(FV.appleMicrocodeHeaderSize) - 0x48)
        return TestImage.volume(
            fileSystem: FV.appleMicrocodeFileSystem, length: 0x1000, trailing: filler + body
        )
    }

    func testTheBodyReadsAsItsMicrocodeAndTheErasedRest() {
        let first = TestImage.microcode(signature: 0x206A7, dataSize: 0x80)
        let second = TestImage.microcode(signature: 0x306A9, dataSize: 0x40)
        let parsed = UEFIParser.parse(volume(first + second))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.header, 0..<0x100)
        XCTAssertEqual(volume.children.map(\.kind), [.microcode, .microcode, .padding])
        XCTAssertEqual(volume.children[0].range, 0x100..<(0x100 + UInt64(first.count)))
        XCTAssertEqual(volume.children[1].range.lowerBound, 0x100 + UInt64(first.count))
        XCTAssertTrue(volume.children[2].isErased)
        XCTAssertEqual(volume.children[2].range.upperBound, 0x1000)
        XCTAssertEqual(volume.uefiItemSubtype, UEFITypes.Sub.appleMicrocodeVolume)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// The walk stops at the first bytes that are not a microcode and keeps
    /// the rest whole, as the reference does.
    func testBytesThatAreNotAMicrocodeEndTheWalkAsPadding() {
        let first = TestImage.microcode()
        let parsed = UEFIParser.parse(volume(first + [0x12, 0x34, 0x56, 0x78]))
        let children = parsed.roots[0].children

        XCTAssertEqual(children.map(\.kind), [.microcode, .padding])
        XCTAssertFalse(children[1].isErased)
        XCTAssertEqual(children[1].range, (0x100 + UInt64(first.count))..<0x1000)
    }

    /// An erased volume holds nothing but padding.
    func testAnErasedVolumeIsPadding() {
        let children = UEFIParser.parse(volume([])).roots[0].children
        XCTAssertEqual(children.map(\.kind), [.padding])
        XCTAssertEqual(children[0].range, 0x100..<0x1000)
    }
}
