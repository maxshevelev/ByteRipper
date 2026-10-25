import Foundation
import XCTest
import UEFIImage
@testable import UEFITool

/// Which nodes count as module images: the structural test, then the magic
/// bytes. The unit is the image body, not the FFS file and not the container
/// (`Design/CODE_PANEL_PLAN.md`).
final class UEFICodeCandidatesTests: XCTestCase {
    private func section(_ type: UInt8) -> UEFINode {
        UEFINode(kind: .section, subtype: type, name: "Section",
                 header: 0..<4, body: 4..<0x40)
    }

    func testOnlyImageSectionsAndFilesAreCandidates() {
        XCTAssertTrue(UEFICodeCandidates.isCandidate(section(0x10)))
        XCTAssertTrue(UEFICodeCandidates.isCandidate(section(0x12)))
        XCTAssertFalse(UEFICodeCandidates.isCandidate(section(0x19)))

        let file = UEFINode(kind: .file, subtype: 0x01, name: "Module",
                            header: 0..<0x18, body: 0x18..<0x40)
        XCTAssertTrue(UEFICodeCandidates.isCandidate(file))
        XCTAssertFalse(UEFICodeCandidates.isCandidate(
            UEFINode(kind: .padding, name: "Padding", range: 0..<0x10)))
    }

    func testTheMagicDecidesWhetherABodyIsAnImage() {
        XCTAssertTrue(UEFICodeCandidates.isImage(Data([0x4D, 0x5A, 0x90])))
        XCTAssertTrue(UEFICodeCandidates.isImage(Data([0x56, 0x5A, 0x00])))
        XCTAssertFalse(UEFICodeCandidates.isImage(Data([0x4D])))
        XCTAssertFalse(UEFICodeCandidates.isImage(Data([0x00, 0x00])))
        XCTAssertFalse(UEFICodeCandidates.isImage(Data()))

        let node = section(0x10)
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes[4] = 0x4D
        bytes[5] = 0x5A
        XCTAssertTrue(UEFICodeCandidates.isImage(node, reader: ImageReader(bytes)))
        bytes[4] = 0
        XCTAssertFalse(UEFICodeCandidates.isImage(node, reader: ImageReader(bytes)))
    }

    func testAMagicInAForeignSectionDoesNotMakeAnImage() {
        let raw = section(0x19)
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes[4] = 0x4D
        bytes[5] = 0x5A
        XCTAssertFalse(UEFICodeCandidates.isImage(raw, reader: ImageReader(bytes)))
    }
}
