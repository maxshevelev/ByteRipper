import XCTest
@testable import UEFIImage

/// A part of an image opened on its own, read as what the parent's tree knew it
/// to be (`Design/UEFI/UPDATE_IN_PARENT.md` §2.1).
final class RootLayoutTests: XCTestCase {
    /// What a Tiano or LZMA section decompresses to: two sections, back to back —
    /// twelve bytes each, so no alignment gap stands between them.
    private let sections = TestImage.nameSection("Drv") + TestImage.nameSection("Set")

    /// The report this exists for: a decompressed body read as an image is a
    /// scan that finds nothing, and read as sections it is its sections.
    func testADecompressedBodyReadsAsItsSections() {
        let scanned = UEFIParser.parse(sections)
        XCTAssertFalse(scanned.allNodes.contains { $0.kind == .section },
                       "a signature scan does not see sections")

        let read = UEFIParser.parse(sections, layout: .decompressedBody)
        XCTAssertEqual(read.roots.map(\.kind), [.section, .section])
    }

    func testAFileReadsAsAFileWithItsSections() throws {
        let file = TestImage.sectionedFile(sections: [TestImage.nameSection("Driver")])
        let image = UEFIParser.parse(file, layout: .file(ffsVersion: 2, volumeRevision: 2))

        let root = try XCTUnwrap(image.roots.first)
        XCTAssertEqual(root.kind, .file)
        XCTAssertEqual(root.children.map(\.kind), [.section])
    }

    func testAVolumeReadsAsAVolume() throws {
        let volume = TestImage.volume(files: [TestImage.file(body: [1, 2, 3])])
        let image = UEFIParser.parse(volume, layout: .volume)

        let root = try XCTUnwrap(image.roots.first)
        XCTAssertEqual(root.kind, .volume)
        XCTAssertEqual(root.children.first?.kind, .file)
    }

    /// A layout the bytes do not bear out is not forced on them: they are read
    /// as an image, and the failed attempt says nothing.
    func testALayoutThatDoesNotFitFallsBackToTheImage() {
        let asImage = UEFIParser.parse(sections)
        let asVolume = UEFIParser.parse(sections, layout: .volume)

        XCTAssertEqual(asVolume.roots, asImage.roots)
        XCTAssertEqual(asVolume.diagnostics, asImage.diagnostics)
    }

    // MARK: - What the parent's tree says a part is

    private func parent() -> UEFIImage {
        let file = TestImage.sectionedFile(sections: [TestImage.nameSection("Driver")])
        return UEFIParser.parse(TestImage.image(TestImage.volume(files: [file])))
    }

    func testANodeSaysWhatItIsAsARoot() throws {
        let image = parent()
        let volume = try XCTUnwrap(image.allNodes.first { $0.kind == .volume })
        let file = try XCTUnwrap(image.allNodes.first { $0.kind == .file })
        let section = try XCTUnwrap(image.allNodes.first { $0.kind == .section })

        XCTAssertEqual(UEFIRootLayout.of(volume, in: image), .volume)
        XCTAssertEqual(UEFIRootLayout.of(file, in: image), .file(ffsVersion: 2, volumeRevision: 2))
        XCTAssertEqual(UEFIRootLayout.of(section, in: image), .sections(ffsVersion: 2))
        XCTAssertEqual(UEFIRootLayout.ofBody(of: file, in: image), .sections(ffsVersion: 2))
        XCTAssertEqual(UEFIRootLayout.ofBody(of: volume, in: image), .image,
                       "a volume's body is files with no header to say so")
    }

    /// A zone is a range of the file; the innermost node covering it — or
    /// whose body it is — says what it is.
    func testAFileRangeSaysWhatItIsFromTheNodeThatCoversIt() throws {
        let image = parent()
        let file = try XCTUnwrap(image.allNodes.first { $0.kind == .file })

        XCTAssertEqual(UEFIRootLayout.forFileRange(file.range, in: image),
                       .file(ffsVersion: 2, volumeRevision: 2))
        XCTAssertEqual(UEFIRootLayout.forFileRange(file.body, in: image), .sections(ffsVersion: 2))
        XCTAssertEqual(UEFIRootLayout.forFileRange(3..<9, in: image), .image)
    }

    @MainActor
    func testALazyTreeReadsItsRootByItsLayout() async {
        let tree = LazyUEFITree(sections, layout: .decompressedBody)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            tree.whenReady { done.resume() }
        }
        XCTAssertEqual(tree.rootNodes.map(\.kind), [.section, .section])
        XCTAssertEqual(tree.layout, .decompressedBody)
    }
}
