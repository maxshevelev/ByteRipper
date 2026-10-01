import XCTest
@testable import UEFIImage

/// A raw file's body, read the way UEFITool's `parseFileBody` reads it:
/// sections when it reads as sections, a raw area otherwise, and a leaf when
/// that area holds nothing; an AMI ROM hole stays whole and fixed.
final class RawFileBodyTests: XCTestCase {
    private func file(_ body: [UInt8], guid: EFIGUID = TestImage.driverGUID, type: UInt8 = FFS.rawType) -> (UEFINode, UEFIImage) {
        let parsed = UEFIParser.parse(TestImage.volume(length: 0x1000, files: [
            TestImage.file(guid: guid, type: type, body: body),
        ]))
        return (parsed.roots[0].children[0], parsed)
    }

    func testABodyThatIsSectionsReadsAsSections() {
        let body = TestImage.section(type: Section.raw, body: [1, 2, 3, 4])
            + TestImage.section(type: Section.raw, body: [5, 6, 7, 8])
        let (raw, parsed) = file(body)
        XCTAssertEqual(raw.children.map(\.kind), [.section, .section])
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// The `all` type is read the way a raw file is.
    func testAnAllTypeFileIsReadLikeARawOne() {
        let (all, _) = file(TestImage.section(type: Section.raw, body: [1, 2, 3, 4]), type: FFS.allType)
        XCTAssertEqual(all.children.map(\.kind), [.section])
    }

    /// Data that is not sections and holds nothing a raw area can find leaves
    /// the file a leaf, quietly.
    func testPlainDataLeavesTheFileALeaf() {
        let (raw, parsed) = file(Array("BM\u{1}\u{2} a logo, say".utf8))
        XCTAssertTrue(raw.children.isEmpty)
        XCTAssertTrue(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    }

    /// A body that is not sections is searched as a raw area: a volume inside
    /// one is found.
    func testAVolumeInsideARawFileIsFound() {
        let inner = TestImage.volume(length: 0x200)
        let (raw, _) = file([0xAB, 0xCD, 0xEF, 0x01] + [UInt8](repeating: 0xFF, count: 0x0C) + inner)
        XCTAssertTrue(raw.children.contains { $0.kind == .volume })
    }

    /// The store the FIT points into: a raw file of microcode reads as its
    /// images, as it did when that was the one raw file opened.
    func testMicrocodeInARawFileIsFound() {
        let (raw, _) = file(TestImage.microcode() + TestImage.microcode(signature: 0x806EA))
        XCTAssertEqual(raw.children.filter { $0.kind == .microcode }.count, 2)
    }

    /// A section whose size runs past the body, or a GUID-defined one whose
    /// data offset does, is not a run of sections.
    func testABrokenSectionRunIsNotReadAsSections() {
        let tooBig = TestImage.section(type: Section.raw, body: [1, 2, 3, 4], size: 0x40)
        XCTAssertFalse(file(tooBig).0.children.contains { $0.kind == .section })

        var guided = BinaryWriter()
        guided.guid(TestImage.driverGUID)
        guided.u16(0x400)                              // DataOffset, past the section
        guided.u16(0)
        let badOffset = TestImage.section(type: Section.guidDefined, body: [1, 2, 3, 4], extra: guided.bytes)
        XCTAssertFalse(file(badOffset).0.children.contains { $0.kind == .section })
    }

    /// An AMI ROM hole is the vendor's: kept whole, and fixed in place.
    func testAnAmiRomHoleStaysWholeAndFixed() {
        let hole = EFIGUID("05CA0203-0FC1-11DC-9011-00173153EBA8")!
        let (raw, _) = file(TestImage.section(type: Section.raw, body: [1, 2, 3, 4]), guid: hole)
        XCTAssertTrue(raw.children.isEmpty)
        XCTAssertTrue(raw.isFixed)
        XCTAssertFalse(FFS.isRomHole(EFIGUID("05CA020C-0FC1-11DC-9011-00173153EBA8")!))
    }
}
