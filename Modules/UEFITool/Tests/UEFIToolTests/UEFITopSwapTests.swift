import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// What the panel says about a Top Swap copy: the copy's outermost rows say
/// they are one, both blocks' outermost rows say where the other copy is, and
/// the copy's `?` opens the page about Top Swap.
final class UEFITopSwapTests: XCTestCase {
    private static let copy = TopSwapCopy(top: 0x1_0000..<0x2_0000, backup: 0..<0x1_0000)

    private func image(match: Bool = true) -> UEFIImage {
        func volume(at base: UInt64) -> UEFINode {
            let file = UEFINode(kind: .file, subtype: 0x07, name: "Driver",
                                header: (base + 0x48)..<(base + 0x60), body: (base + 0x60)..<(base + 0x100))
            return UEFINode(kind: .volume, name: "Volume", header: base..<(base + 0x48),
                            body: (base + 0x48)..<(base + 0x1_0000), children: [file])
        }
        let region = UEFINode(kind: .region, subtype: 1, name: "BIOS region", header: 0..<0, body: 0..<0x2_0000,
                              children: [volume(at: 0), volume(at: 0x1_0000)])
        return UEFIImage(size: 0x2_0000, roots: [region],
                         protectedRanges: ProtectedRanges(topSwap: Self.copy, topSwapCopiesMatch: match))
    }

    private func node(_ image: UEFIImage, _ path: [Int]) -> UEFINode {
        image.node(NodeID(path))!
    }

    func testTheCopysOutermostRowsSayTheyAreOne() {
        let image = image()
        XCTAssertEqual(UEFITopSwap.role(of: node(image, [0, 0]), in: image), .copy(of: Self.copy.top))
        XCTAssertEqual(UEFITopSwap.role(of: node(image, [0, 1]), in: image), .original(copiedAt: Self.copy.backup))
        // Inside them, and around them, nothing changes.
        XCTAssertNil(UEFITopSwap.role(of: node(image, [0, 0, 0]), in: image))
        XCTAssertNil(UEFITopSwap.role(of: node(image, [0]), in: image))

        XCTAssertEqual(
            UEFITreeDisplay.name(for: node(image, [0, 0]), catalogue: GuidsCatalogue(names: [:]), in: image),
            "Volume (Top Swap copy)"
        )
        XCTAssertEqual(UEFITreeDisplay.name(for: node(image, [0, 1]), catalogue: GuidsCatalogue(names: [:]), in: image), "Volume")
    }

    func testTheDetailsSayWhereTheOtherCopyIsAndWhetherTheyAgree() {
        let image = image()
        let reader = ImageReader([UInt8](repeating: 0, count: 0x2_0000))
        func topSwap(_ path: [Int], in image: UEFIImage) -> String? {
            UEFIDetail.build(for: node(image, path), image: image, reader: reader)
                .fields.first { $0.label == "Top Swap" }?.value
        }
        XCTAssertEqual(topSwap([0, 0], in: image), "Copy of 0x10000–0x20000; the copies match")
        XCTAssertEqual(topSwap([0, 1], in: image), "Copied at 0x0–0x10000; the copies match")
        XCTAssertNil(topSwap([0, 0, 0], in: image))
        XCTAssertEqual(topSwap([0, 0], in: self.image(match: false)), "Copy of 0x10000–0x20000; the copies differ")
    }

    func testTheCopysHelpIsTheTopSwapPage() {
        let image = image()
        XCTAssertEqual(UEFIHelpTerms.term(for: node(image, [0, 0]), in: image), HelpTermID("top-swap"))
        XCTAssertEqual(UEFIHelpTerms.term(for: node(image, [0, 1]), in: image), HelpTermID("volume"))
    }

    /// Any node of either block has a twin one block away, of the same kind:
    /// down into the copy from the top block, up out of it.
    func testEveryNodeInEitherBlockHasATwin() {
        let image = image()
        let file = UEFITopSwap.counterpart(of: node(image, [0, 1, 0]), in: image)
        XCTAssertEqual(file?.range, 0x48..<0x100)
        XCTAssertEqual(file?.kind, .file)
        XCTAssertEqual(file?.isInCopy, true)
        XCTAssertEqual(file?.menuTitle, "Go to Top Swap Copy")

        let volume = UEFITopSwap.counterpart(of: node(image, [0, 0]), in: image)
        XCTAssertEqual(volume?.range, 0x1_0000..<0x2_0000)
        XCTAssertEqual(volume?.isInCopy, false)
        XCTAssertEqual(volume?.menuTitle, "Go to Original")

        // The region holds both blocks and is in neither.
        XCTAssertNil(UEFITopSwap.counterpart(of: node(image, [0]), in: image))
    }

    /// The twin is the node of that range and kind among those covering its
    /// first byte; where the copies drifted apart, the innermost node that
    /// still holds the range.
    func testTheTwinIsFoundAmongTheNodesCoveringIt() {
        let image = image()
        let counterpart = UEFITopSwap.counterpart(of: node(image, [0, 1, 0]), in: image)!
        let chain = image.nodes(containing: counterpart.range.lowerBound)
        XCTAssertEqual(UEFITopSwap.twin(of: counterpart, in: chain)?.id, NodeID([0, 0, 0]))

        var drifted = counterpart
        drifted.kind = .section
        XCTAssertEqual(UEFITopSwap.twin(of: drifted, in: chain)?.id, NodeID([0, 0, 0]),
                       "no section there: the file holding the range is as near as it gets")
    }

    /// Without the ranges read there is no copy to speak of.
    func testWithoutTheRangesReadNothingIsSaid() {
        let bare = UEFIImage(size: 0x2_0000, roots: image().roots)
        XCTAssertNil(UEFITopSwap.role(of: node(bare, [0, 0]), in: bare))
        XCTAssertNil(UEFITopSwap.counterpart(of: node(bare, [0, 0]), in: bare))
    }
}
