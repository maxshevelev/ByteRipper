import XCTest
@testable import UEFIImage

/// Which bytes a node's ranges are in, and the lookups by file offset that must
/// never reach into a decompressed buffer (`COMPRESSED_SECTIONS.md` §5).
final class ByteSpaceTests: XCTestCase {
    func testANodeIsInTheFileUnlessItSaysOtherwise() {
        let node = UEFINode(kind: .padding, name: "Padding", range: 0x10..<0x20)

        XCTAssertEqual(node.space, .file)
        XCTAssertEqual(node.fileRange, 0x10..<0x20)
        XCTAssertFalse(node.isCompressed)
    }

    func testANodeInsideACompressedSectionHasNoFileRange() {
        var node = UEFINode(kind: .padding, name: "Padding", range: 0x10..<0x20)
        node.space = .decompressed(chain: [0x400])

        XCTAssertNil(node.fileRange)
        XCTAssertTrue(node.isCompressed, "anything inside a compressed section is compressed")
        XCTAssertEqual(node.range, 0x10..<0x20, "its ranges stay, in its own space")
    }

    func testASpaceNamesEveryCompressedSectionOnTheWayIn() {
        let outer = ByteSpace.file.inside(sectionAt: 0x400)
        let inner = outer.inside(sectionAt: 0x88)

        XCTAssertEqual(outer, .decompressed(chain: [0x400]))
        XCTAssertEqual(inner, .decompressed(chain: [0x400, 0x88]))
        XCTAssertEqual(inner.outermostSection, 0x400)
        XCTAssertNil(ByteSpace.file.outermostSection)
    }

    /// The section's child starts at buffer offset 0 and runs far past the
    /// section — numbers that cover the asked offset. The chain still stops at
    /// the section, the last node whose bytes are the file's.
    func testALookupByFileOffsetStopsAtTheCompressedSection() {
        var child = UEFINode(kind: .file, name: "Driver", range: 0..<0x10000)
        child.space = .decompressed(chain: [0x100])
        let section = UEFINode(
            kind: .section, name: "LZMA section",
            header: 0x100..<0x118, body: 0x118..<0x200,
            children: [child]
        )
        let image = UEFIImage(size: 0x1000, roots: [section])

        XCTAssertEqual(image.nodes(containing: 0x150).map(\.name), ["LZMA section"])
        XCTAssertEqual(image.innermostNode(containing: 0x150)?.name, "LZMA section")
        XCTAssertTrue(image.nodes(containing: 0x500).isEmpty,
                      "outside the section, a buffer offset is no reason to match")
    }
}
