import XCTest
import ToolModuleKit
import UEFIImage
@testable import UEFITool

/// The UEFI tree's row marks (`Design/ROW_MARKS.md` §5.1), decided without a
/// window.
final class UEFITreeMarksTests: XCTestCase {
    private let lzma = SectionCompression(algorithm: "LZMA", decodes: true)

    private func section(
        compression: SectionCompression?,
        isExpandable: Bool = false,
        children: [UEFINode] = []
    ) -> UEFINode {
        UEFINode(
            kind: .section, subtype: 0x01, name: "LZMA compressed section",
            header: 0x60..<0x69, body: 0x69..<0x100,
            compression: compression, isExpandable: isExpandable,
            children: children
        )
    }

    private func inner() -> UEFINode {
        UEFINode(kind: .file, name: "Driver", header: 0..<0x18, body: 0x18..<0x40,
                 space: .decompressed(chain: [0x60]))
    }

    func testAPlainNodeWearsNothing() {
        let node = UEFINode(kind: .padding, name: "Padding", range: 0..<0x10)
        let image = UEFIImage(size: 0x10, roots: [node])
        XCTAssertEqual(UEFITreeMarks.marks(for: node, in: image), .none)
    }

    func testAWrongChecksumIsAnError() {
        let node = UEFINode(kind: .file, name: "File", header: 0..<0x18, body: 0x18..<0x40)
        let image = UEFIImage(size: 0x40, roots: [node])
        let marks = UEFITreeMarks.marks(for: node, in: image, badChecksums: [.fileHeader, .fileBody])
        XCTAssertEqual(marks.problem, .error(["Invalid checksums: file body, file header"]))
    }

    /// A node inside a compressed section wears the rail, and its tooltip says
    /// which section the bytes came out of.
    func testANodeInsideWearsTheRailAndSaysWhereFrom() {
        let image = UEFIImage(size: 0x100, roots: [section(compression: lzma, children: [inner()])])
        let marks = UEFITreeMarks.marks(for: image.roots[0].children[0], in: image)

        XCTAssertEqual(marks.decompressedFrom, "Decompressed from LZMA compressed section at 0x60")
        XCTAssertNil(marks.problem)
        XCTAssertTrue(marks.roles.isEmpty)
    }

    func testAnOpenedOrOpenableSectionWearsTheCompressedBadge() {
        let opened = UEFIImage(size: 0x100, roots: [section(compression: lzma, children: [inner()])])
        XCTAssertEqual(UEFITreeMarks.marks(for: opened.roots[0], in: opened).roles,
                       [.compressed(algorithm: "LZMA", decoded: true)])

        let closed = UEFIImage(size: 0x100, roots: [section(compression: lzma, isExpandable: true)])
        let marks = UEFITreeMarks.marks(for: closed.roots[0], in: closed)
        XCTAssertEqual(marks.roles, [.compressed(algorithm: "LZMA", decoded: true)])
        XCTAssertNil(marks.problem, "not opened yet is not a failure")
    }

    /// A section whose row is open on what came out of it starts the rail its
    /// subtree wears, so the two read as one bracket; its bytes are still the
    /// file's, so it says no "decompressed from". Shut, it has nothing to tie
    /// the rail to — even with the branch read.
    func testASectionStartsTheRailOnlyWhileItsRowIsOpen() {
        let opened = UEFIImage(size: 0x100, roots: [section(compression: lzma, children: [inner()])])
        let open = UEFITreeMarks.marks(for: opened.roots[0], in: opened, isOpen: true)
        XCTAssertTrue(open.opensDecompressed)
        XCTAssertTrue(open.hasRail)
        XCTAssertNil(open.decompressedFrom)

        XCTAssertFalse(UEFITreeMarks.marks(for: opened.roots[0], in: opened, isOpen: false).hasRail,
                       "read, but shut")

        let closed = UEFIImage(size: 0x100, roots: [section(compression: lzma, isExpandable: true)])
        XCTAssertFalse(UEFITreeMarks.marks(for: closed.roots[0], in: closed, isOpen: true).hasRail,
                       "nothing under it yet")
    }

    /// A section that decodes, was tried, and holds nothing did not decompress:
    /// the grey badge, and a caution saying what the parse said.
    func testASectionThatDidNotDecompressIsACaution() {
        let failed = section(compression: lzma)
        let image = UEFIImage(
            size: 0x100, roots: [failed],
            diagnostics: [UEFIDiagnostic(.decompressionFailed(algorithm: "LZMA", truncated: false),
                                         at: 0x60)]
        )
        let marks = UEFITreeMarks.marks(for: image.roots[0], in: image)

        XCTAssertEqual(marks.roles, [.compressed(algorithm: "LZMA", decoded: false)])
        XCTAssertEqual(marks.problem, .caution(["LZMA data does not decompress"]))
        XCTAssertFalse(marks.hasRail, "nothing came out of it to bracket")
    }

    /// An algorithm this project does not decode is marked as such, and is not
    /// a problem: nothing went wrong, it is just not opened.
    func testAnUndecodedAlgorithmIsGreyAndNotAProblem() {
        let brotli = section(compression: SectionCompression(algorithm: "Brotli", decodes: false))
        let image = UEFIImage(size: 0x100, roots: [brotli])
        let marks = UEFITreeMarks.marks(for: image.roots[0], in: image)

        XCTAssertEqual(marks.roles, [.compressed(algorithm: "Brotli", decoded: false)])
        XCTAssertNil(marks.problem)
        XCTAssertFalse(marks.hasRail)
    }
}
