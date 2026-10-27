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
        XCTAssertEqual(UEFITreeMarks.marks(for: node, in: image, in: .english), .none)
    }

    func testAWrongChecksumIsAnError() {
        let node = UEFINode(kind: .file, name: "File", header: 0..<0x18, body: 0x18..<0x40)
        let image = UEFIImage(size: 0x40, roots: [node])
        let marks = UEFITreeMarks.marks(for: node, in: image, badChecksums: [.fileHeader, .fileBody], in: .english)
        XCTAssertEqual(marks.problem, .error(["Invalid checksums: file body, file header"]))
    }

    /// A node inside a compressed section wears the rail, and its tooltip says
    /// which section the bytes came out of.
    func testANodeInsideWearsTheRailAndSaysWhereFrom() {
        let image = UEFIImage(size: 0x100, roots: [section(compression: lzma, children: [inner()])])
        let marks = UEFITreeMarks.marks(for: image.roots[0].children[0], in: image, in: .english)

        XCTAssertEqual(marks.decompressedFrom, "Decompressed from LZMA compressed section at 0x60")
        XCTAssertNil(marks.problem)
        XCTAssertTrue(marks.roles.isEmpty)
    }

    func testAnOpenedOrOpenableSectionWearsTheCompressedBadge() {
        let opened = UEFIImage(size: 0x100, roots: [section(compression: lzma, children: [inner()])])
        XCTAssertEqual(UEFITreeMarks.marks(for: opened.roots[0], in: opened, in: .english).roles,
                       [.compressed(algorithm: "LZMA", decoded: true)])

        let closed = UEFIImage(size: 0x100, roots: [section(compression: lzma, isExpandable: true)])
        let marks = UEFITreeMarks.marks(for: closed.roots[0], in: closed, in: .english)
        XCTAssertEqual(marks.roles, [.compressed(algorithm: "LZMA", decoded: true)])
        XCTAssertNil(marks.problem, "not opened yet is not a failure")
    }

    /// A section whose row is open on what came out of it starts the rail its
    /// subtree wears, so the two read as one bracket; its bytes are still the
    /// file's, so it says no "decompressed from". Shut, it has nothing to tie
    /// the rail to — even with the branch read.
    func testASectionStartsTheRailOnlyWhileItsRowIsOpen() {
        let opened = UEFIImage(size: 0x100, roots: [section(compression: lzma, children: [inner()])])
        let open = UEFITreeMarks.marks(for: opened.roots[0], in: opened, isOpen: true, in: .english)
        XCTAssertTrue(open.opensDecompressed)
        XCTAssertTrue(open.hasRail)
        XCTAssertNil(open.decompressedFrom)

        XCTAssertFalse(UEFITreeMarks.marks(for: opened.roots[0], in: opened, isOpen: false, in: .english).hasRail,
                       "read, but shut")

        let closed = UEFIImage(size: 0x100, roots: [section(compression: lzma, isExpandable: true)])
        XCTAssertFalse(UEFITreeMarks.marks(for: closed.roots[0], in: closed, isOpen: true, in: .english).hasRail,
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
        let marks = UEFITreeMarks.marks(for: image.roots[0], in: image, in: .english)

        XCTAssertEqual(marks.roles, [.compressed(algorithm: "LZMA", decoded: false)])
        XCTAssertEqual(marks.problem, .caution(["LZMA data does not decompress"]))
        XCTAssertFalse(marks.hasRail, "nothing came out of it to bracket")
    }

    /// An algorithm this project does not decode is marked as such, and is not
    /// a problem: nothing went wrong, it is just not opened.
    func testAnUndecodedAlgorithmIsGreyAndNotAProblem() {
        let brotli = section(compression: SectionCompression(algorithm: "Brotli", decodes: false))
        let image = UEFIImage(size: 0x100, roots: [brotli])
        let marks = UEFITreeMarks.marks(for: image.roots[0], in: image, in: .english)

        XCTAssertEqual(marks.roles, [.compressed(algorithm: "Brotli", decoded: false)])
        XCTAssertNil(marks.problem)
        XCTAssertFalse(marks.hasRail)
    }

    // MARK: - The code badge

    func testAnAnalyzedImageWearsTheCodeBadge() {
        let node = UEFINode(kind: .section, subtype: 0x10, name: "PE32 image",
                            header: 0..<4, body: 4..<0x100)
        let image = UEFIImage(size: 0x100, roots: [node])

        let marks = UEFITreeMarks.marks(for: node, in: image, hasCode: true, in: .english)
        XCTAssertEqual(marks.roles, [.codeAnalysis])
        XCTAssertNil(marks.problem)
        XCTAssertEqual(ToolRowMark.codeAnalysis.channel, .role)
        XCTAssertEqual(ToolRowMark.codeAnalysis.symbol, "ellipsis.curlybraces")
        XCTAssertTrue(UEFITreeMarks.legendMarks.contains(.codeAnalysis))
    }

    func testAnImageWithoutAnAnalysisWearsNoCodeBadge() {
        let node = UEFINode(kind: .section, subtype: 0x12, name: "TE image",
                            header: 0..<4, body: 4..<0x100)
        let image = UEFIImage(size: 0x100, roots: [node])

        XCTAssertTrue(UEFITreeMarks.marks(for: node, in: image, in: .english).roles.isEmpty)
    }

    /// A shut PEIM wears the badge of the image in it; open, it hands it on.
    func testAShutFileWearsTheBadgeOfTheModuleInIt() {
        let imageID = NodeID([0, 3, 1])
        let file = UEFINode(id: NodeID([0, 3]), kind: .file, name: "CpuPei",
                            header: 0..<0x18, body: 0x18..<0x100)
        let analyzed: Set<NodeID> = [imageID]

        XCTAssertTrue(UEFITreeMarks.hidesCode(file, isOpen: false, analyzed: analyzed))
        XCTAssertFalse(UEFITreeMarks.hidesCode(file, isOpen: true, analyzed: analyzed))
        XCTAssertFalse(UEFITreeMarks.hidesCode(file, isOpen: false, analyzed: [NodeID([0, 4, 1])]),
                       "an analysis in another file")

        let image = UEFIImage(size: 0x100, roots: [file])
        let shut = UEFITreeMarks.marks(for: file, in: image, hidesCode: true, in: .english)
        XCTAssertEqual(shut.roles, [.codeAnalysisInside])
    }

    /// A compressed section still shut inside an open file holds the badge
    /// until it opens on the image.
    func testAShutSectionInAFileHoldsTheBadgeToo() {
        let compressed = UEFINode(id: NodeID([0, 3, 0]), kind: .section, subtype: 0x01,
                                  name: "Compressed section", header: 0..<4, body: 4..<0x100)
        let analyzed: Set<NodeID> = [NodeID([0, 3, 0, 0, 2])]
        XCTAssertTrue(UEFITreeMarks.hidesCode(compressed, isOpen: false, analyzed: analyzed))
        XCTAssertFalse(UEFITreeMarks.hidesCode(compressed, isOpen: true, analyzed: analyzed))
    }

    /// A shut volume would wear it for nearly every module: it does not.
    func testAVolumeWearsNoBadgeForWhatItHolds() {
        let volume = UEFINode(id: NodeID([0]), kind: .volume, name: "FV",
                              header: 0..<0x48, body: 0x48..<0x100)
        XCTAssertFalse(UEFITreeMarks.hidesCode(volume, isOpen: false, analyzed: [NodeID([0, 3, 1])]))
    }

    /// The analyzed image itself wears its own badge, not the inside one.
    func testTheImageItselfKeepsItsOwnBadge() {
        let node = UEFINode(id: NodeID([0, 3, 1]), kind: .section, subtype: 0x12, name: "TE image",
                            header: 0..<4, body: 4..<0x100)
        let image = UEFIImage(size: 0x100, roots: [node])
        let marks = UEFITreeMarks.marks(for: node, in: image, hasCode: true, hidesCode: false, in: .english)
        XCTAssertEqual(marks.roles, [.codeAnalysis])
        XCTAssertFalse(UEFITreeMarks.hidesCode(node, isOpen: false, analyzed: [node.id]))
    }
}
