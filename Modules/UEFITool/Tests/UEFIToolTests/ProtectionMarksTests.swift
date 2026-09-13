import ToolModuleKit
import UEFIImage
import UEFITool
import XCTest

/// The Boot Guard marks of the UEFI tree, its detail and its summary
/// (`Design/ROW_MARKS.md` §5.1, `UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §9.3).
final class ProtectionMarksTests: XCTestCase {
    /// A volume holding a file and the AMI hash file, with the ranges given.
    private func image(_ ranges: [ProtectedRange]?) -> UEFIImage {
        let file = UEFINode(kind: .file, name: "Driver", header: 0x48..<0x60, body: 0x60..<0x200)
        let hashFile = UEFINode(kind: .file, name: "Hashes", guid: KnownGUIDs.amiHashFile,
                                header: 0x200..<0x218, body: 0x218..<0x280)
        let volume = UEFINode(kind: .volume, name: "FFSv2", header: 0..<0x48, body: 0x48..<0x1000,
                              children: [file, hashFile])
        return UEFIImage(size: 0x1000, roots: [volume], protectedRanges: ranges.map { ProtectedRanges(ranges: $0) })
    }

    private func node(_ image: UEFIImage, _ name: String) -> UEFINode {
        image.allNodes.first { $0.name == name }!
    }

    private func marks(_ image: UEFIImage, _ name: String) -> ToolRowMarks {
        UEFITreeMarks.marks(for: node(image, name), in: image)
    }

    func testANodeInsideTheIBBIsTintedAndAVolumePartlyInsideWearsTheBadge() {
        let image = image([.init(kind: .ibb, range: 0x48..<0x200, source: 0x900..<0x940, verdict: .matches)])

        XCTAssertEqual(marks(image, "Driver").protection, .ibb)
        XCTAssertNil(marks(image, "FFSv2").protection, "a volume is not tinted for bytes it mostly is not")
        XCTAssertEqual(marks(image, "FFSv2").roles, [.partlyProtected])
    }

    func testAFirmwareCheckedRangeIsTheOtherTint() {
        let image = image([.init(kind: .amiV2, range: 0x48..<0x200, source: 0x218..<0x240, verdict: .matches)])

        XCTAssertEqual(marks(image, "Driver").protection, .firmware)
    }

    /// The hash file wears the badge of what it holds, and the mismatch of a
    /// range it names — as does the node the range starts at.
    func testTheHashFileHoldsChecksAndAMismatchIsAnError() {
        let image = image([.init(kind: .amiV2, range: 0x48..<0x200, source: 0x218..<0x240, verdict: .mismatch)])

        let hashFile = marks(image, "Hashes")
        XCTAssertTrue(hashFile.roles.contains { if case .holdsChecks = $0 { return true } else { return false } })
        XCTAssertEqual(hashFile.problem?.isError, true)
        XCTAssertEqual(marks(image, "Driver").problem?.isError, true)
    }

    /// The reference never compares the IBB digest, so a port's mismatch is a
    /// caution until boards known to boot confirm it (§6.1).
    func testAnIBBThatDoesNotMatchIsACaution() {
        let image = image([.init(kind: .ibb, range: 0x48..<0x200, source: 0x900..<0x940, verdict: .mismatch)])

        XCTAssertEqual(marks(image, "Driver").problem?.isError, false)
    }

    func testRangesNotReadYetMarkNothing() {
        let image = image(nil)

        XCTAssertNil(marks(image, "Driver").protection)
        XCTAssertEqual(marks(image, "FFSv2").roles, [])
    }

    func testTheDetailSaysWhatProtectsANode() throws {
        let image = image([.init(
            kind: .ibb, range: 0x48..<0x200,
            digests: [.init(algorithm: TCGHash.sha256, bytes: [1, 2, 3])],
            source: 0x900..<0x940, verdict: .matches
        )])

        let detail = UEFIDetail.build(for: node(image, "Driver"), image: image,
                                      reader: ImageReader([UInt8](repeating: 0, count: 0x1000)))
        let table = try XCTUnwrap(detail.tables.first { $0.title == "Protected by" })
        let row = try XCTUnwrap(table.rows.first).map(\.text)
        XCTAssertEqual(row[1], "Boot Guard IBB segment")
        XCTAssertEqual(row[3], "SHA-256 matches")
        XCTAssertTrue(detail.fields.contains { $0.label == "Protection" })

        let untouched = UEFIDetail.build(for: node(image, "Hashes"), image: image,
                                         reader: ImageReader([UInt8](repeating: 0, count: 0x1000)))
        XCTAssertFalse(untouched.tables.contains { $0.title == "Protected by" })
    }

    func testTheSummarySaysTheImageNamesProtectedRanges() {
        let image = image([.init(kind: .ibb, range: 0x48..<0x200, source: 0x900..<0x940)])

        XCTAssertTrue(UEFITreeDisplay.summary(of: image).hasSuffix(" · 1 protected range"),
                      UEFITreeDisplay.summary(of: image))
    }
}
