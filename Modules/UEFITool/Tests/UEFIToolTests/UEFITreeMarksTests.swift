import XCTest
import CodeAnalysis
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

        let marks = UEFITreeMarks.marks(for: node, in: image, code: .partial, in: .english)
        XCTAssertEqual(marks.roles, [.codeAnalysis(.partial)])
        XCTAssertNil(marks.problem)
        XCTAssertEqual(ToolRowMark.codeAnalysis.channel, .role)
        XCTAssertTrue(UEFITreeMarks.legendMarks.contains(.codeAnalysis))
    }

    /// The badge is a circle filled as far as the review has got.
    func testTheBadgeIsFilledAsFarAsTheReviewHasGot() {
        XCTAssertEqual(ToolRowMarks.CodeReadiness.mechanical.symbol, "circle")
        XCTAssertEqual(ToolRowMarks.CodeReadiness.partial.symbol, "circle.lefthalf.filled")
        XCTAssertEqual(ToolRowMarks.CodeReadiness.complete.symbol, "circle.fill")
        XCTAssertEqual(ToolRowMark.codeAnalysis.symbol, "circle.lefthalf.filled", "the legend shows the middle one")
    }

    func testAnImageWithoutAnAnalysisWearsNoCodeBadge() {
        let node = UEFINode(kind: .section, subtype: 0x12, name: "TE image",
                            header: 0..<4, body: 4..<0x100)
        let image = UEFIImage(size: 0x100, roots: [node])

        XCTAssertTrue(UEFITreeMarks.marks(for: node, in: image, in: .english).roles.isEmpty)
    }

    /// A tree of one volume `[0]` holding a PEIM file `[0, 0]` with its
    /// image `[0, 0, 1]`, and a file `[0, 1]` holding a compressed section
    /// `[0, 1, 0]` with a volume whose file `[0, 1, 0, 0, 0]` holds the image
    /// `[0, 1, 0, 0, 0, 0]`.
    private func tree() -> UEFIImage {
        func section(_ path: [Int], _ subtype: UInt8, _ name: String, children: [UEFINode] = []) -> UEFINode {
            UEFINode(id: NodeID(path), kind: .section, subtype: subtype, name: name,
                     header: 0..<4, body: 4..<0x100, children: children)
        }
        func file(_ path: [Int], _ name: String, children: [UEFINode]) -> UEFINode {
            UEFINode(id: NodeID(path), kind: .file, name: name, header: 0..<0x18, body: 0x18..<0x100,
                     children: children)
        }
        let peim = file([0, 0], "CpuPei", children: [section([0, 0, 0], 0x1B, "PEI dependency"),
                                                     section([0, 0, 1], 0x10, "PE32 image")])
        let inner = file([0, 1, 0, 0, 0], "Dxe", children: [section([0, 1, 0, 0, 0, 0], 0x10, "PE32 image")])
        let innerVolume = UEFINode(id: NodeID([0, 1, 0, 0]), kind: .volume, name: "FV",
                                   header: 0..<0x48, body: 0x48..<0x100, children: [inner])
        let container = file([0, 1], "Volume image",
                             children: [section([0, 1, 0], 0x01, "Compressed section", children: [innerVolume])])
        let volume = UEFINode(id: NodeID([0]), kind: .volume, name: "FV", header: 0..<0x48, body: 0x48..<0x100,
                              children: [peim, container])
        return UEFIImage(size: 0x100, roots: [volume])
    }

    /// A PEIM's file is the module: it wears the module's badge open and shut,
    /// and the image in it keeps its own.
    func testAModuleFileKeepsItsBadgeOpenOrShut() throws {
        let image = tree()
        let file = try XCTUnwrap(image.node(NodeID([0, 0])))
        let analyzed: [NodeID: ToolRowMarks.CodeReadiness] = [NodeID([0, 0, 1]): .complete]

        XCTAssertEqual(UEFITreeMarks.moduleFile(of: NodeID([0, 0, 1]), in: image), file.id)
        XCTAssertEqual(UEFITreeMarks.codeModule(file, analyzed: analyzed, in: image), .complete)
        XCTAssertNil(UEFITreeMarks.codeInside(file, isOpen: false, analyzed: analyzed, in: image),
                     "its own module is not inside it")
        XCTAssertNil(UEFITreeMarks.codeModule(file, analyzed: [NodeID([0, 1, 0, 0, 0, 0]): .complete], in: image),
                     "an analysis in another file")

        let marks = UEFITreeMarks.marks(for: file, in: image, codeModule: .complete, in: .english)
        XCTAssertEqual(marks.roles, [.codeAnalysisModule(.complete)])
    }

    /// A section inside a module's file wears nothing: the file says it.
    func testASectionInAModuleFileWearsNothing() throws {
        let image = tree()
        let dependency = try XCTUnwrap(image.node(NodeID([0, 0, 0])))
        let analyzed: [NodeID: ToolRowMarks.CodeReadiness] = [NodeID([0, 0, 1]): .partial]
        XCTAssertNil(UEFITreeMarks.codeInside(dependency, isOpen: false, analyzed: analyzed, in: image))
        XCTAssertNil(UEFITreeMarks.codeModule(dependency, analyzed: analyzed, in: image))
    }

    /// A file or a compressed section that holds modules' files further in
    /// wears the inside badge while shut, and hands it on when opened.
    func testAShutContainerWearsTheBadgeOfTheModulesInIt() throws {
        let image = tree()
        let container = try XCTUnwrap(image.node(NodeID([0, 1])))
        let compressed = try XCTUnwrap(image.node(NodeID([0, 1, 0])))
        let analyzed: [NodeID: ToolRowMarks.CodeReadiness] = [NodeID([0, 1, 0, 0, 0, 0]): .partial]

        XCTAssertEqual(UEFITreeMarks.codeInside(container, isOpen: false, analyzed: analyzed, in: image), .partial)
        XCTAssertNil(UEFITreeMarks.codeInside(container, isOpen: true, analyzed: analyzed, in: image))
        XCTAssertNil(UEFITreeMarks.codeModule(container, analyzed: analyzed, in: image),
                     "the module's file is deeper")
        XCTAssertEqual(UEFITreeMarks.codeInside(compressed, isOpen: false, analyzed: analyzed, in: image), .partial)
        XCTAssertNil(UEFITreeMarks.codeInside(compressed, isOpen: true, analyzed: analyzed, in: image))

        let marks = UEFITreeMarks.marks(for: container, in: image, codeInside: .partial, in: .english)
        XCTAssertEqual(marks.roles, [.codeAnalysisInside(.partial)])
    }

    /// Two modules' images in one file: the file wears the less reviewed one.
    func testAModuleFileShowsItsLeastReviewedImage() throws {
        let image = tree()
        let file = try XCTUnwrap(image.node(NodeID([0, 0])))
        let analyzed: [NodeID: ToolRowMarks.CodeReadiness] = [NodeID([0, 0, 1]): .complete,
                                                              NodeID([0, 0, 0]): .mechanical]
        XCTAssertEqual(UEFITreeMarks.codeModule(file, analyzed: analyzed, in: image), .mechanical)
    }

    /// The origin stands only on the module's own file, open or shut; the
    /// image and the containers above the file show none.
    func testTheOriginStandsOnlyOnTheModuleFile() throws {
        let image = tree()
        let file = try XCTUnwrap(image.node(NodeID([0, 0])))
        let module = try XCTUnwrap(image.node(NodeID([0, 0, 1])))
        let container = try XCTUnwrap(image.node(NodeID([0, 1])))
        let edk2 = ModuleOrigin(category: .edk2, confidence: .established)
        let origins = [module.id: edk2, NodeID([0, 1, 0, 0, 0, 0]): edk2]
        let analyzed = Set(origins.keys)

        XCTAssertEqual(UEFITreeMarks.origin(of: file, origins: origins, analyzed: analyzed, in: image), edk2)
        XCTAssertNil(UEFITreeMarks.origin(of: module, origins: origins, analyzed: analyzed, in: image),
                     "the image keeps only its circle")
        XCTAssertNil(UEFITreeMarks.origin(of: container, origins: origins, analyzed: analyzed, in: image),
                     "a container is not the module")

        XCTAssertEqual(UEFITreeMarks.marks(for: file, in: image, codeModule: .complete, origin: edk2,
                                           in: .english).origin, edk2)
        XCTAssertNil(UEFITreeMarks.marks(for: module, in: image, code: .complete, origin: edk2, in: .english).origin,
                     "no origin on the image row")
        XCTAssertNil(UEFITreeMarks.marks(for: file, in: image, origin: edk2, in: .english).origin,
                     "no analysis, no origin")
    }

    /// A shut volume would wear it for nearly every module: it does not.
    func testAVolumeWearsNoBadgeForWhatItHolds() {
        let volume = UEFINode(id: NodeID([0]), kind: .volume, name: "FV",
                              header: 0..<0x48, body: 0x48..<0x100)
        let image = UEFIImage(size: 0x100, roots: [volume])
        XCTAssertNil(UEFITreeMarks.codeInside(volume, isOpen: false, analyzed: [NodeID([0, 3, 1]): .partial],
                                              in: image))
    }

    /// The analyzed image itself wears its own badge, not the inside one.
    func testTheImageItselfKeepsItsOwnBadge() {
        let node = UEFINode(id: NodeID([0, 3, 1]), kind: .section, subtype: 0x12, name: "TE image",
                            header: 0..<4, body: 4..<0x100)
        let image = UEFIImage(size: 0x100, roots: [node])
        let marks = UEFITreeMarks.marks(for: node, in: image, code: .mechanical, in: .english)
        XCTAssertEqual(marks.roles, [.codeAnalysis(.mechanical)])
        XCTAssertNil(UEFITreeMarks.codeInside(node, isOpen: false, analyzed: [node.id: .mechanical], in: image))
    }
}
