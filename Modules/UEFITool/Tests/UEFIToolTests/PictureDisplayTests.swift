import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// A picture in padding: its details read it again, `?` opens the padding
/// entry, and saving it offers a file a viewer opens.
final class PictureDisplayTests: XCTestCase {
    /// The smallest JPEG the reader takes: a 2×1 frame, an empty scan.
    private static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08] + Array("Exif".utf8) + [0, 0]
        + [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x02, 0x01, 0x01, 0x11, 0x00]
        + [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9]

    private func built() -> (UEFIImage, ImageReader) {
        var bytes = [UInt8](repeating: 0xFF, count: 0x1000)
        bytes.replaceSubrange(0x100..<(0x100 + Self.jpeg.count), with: Self.jpeg)
        let picture = UEFINode(kind: .picture, name: "JPEG 2×1", header: 0x100..<0x100,
                               body: 0x100..<(0x100 + UInt64(Self.jpeg.count)))
        let root = UEFINode(kind: .uefiImage, name: "UEFI image", header: 0..<0, body: 0..<0x1000,
                            children: [picture])
        return (UEFIImage(size: 0x1000, roots: [root]), ImageReader(bytes))
    }

    func testTheDetailsSayWhatThePictureIs() {
        let (image, reader) = built()
        let detail = UEFIDetail.build(for: image.roots[0].children[0], image: image, reader: reader)
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["Kind"], "Picture")
        XCTAssertEqual(fields["Format"], "JPEG (Exif)")
        XCTAssertEqual(fields["Picture size"], "2 × 1")
    }

    /// The panel is handed the picture's bytes to draw, and only a picture's.
    func testThePictureIsHandedToThePanel() {
        let (image, reader) = built()
        let picture = image.roots[0].children[0]
        XCTAssertEqual(UEFIDetail.build(for: picture, image: image, reader: reader).picture, Self.jpeg)
        XCTAssertNil(UEFIDetail.build(for: image.roots[0], image: image, reader: reader).picture)
    }

    func testItOpensThePaddingEntryAndSavesAsAJPEG() {
        let (image, _) = built()
        let node = image.roots[0].children[0]
        XCTAssertEqual(UEFIHelpTerms.term(for: node), HelpTermID("padding"))
        XCTAssertEqual(UEFIPresenter.nodeOpen(for: node, in: image, body: false)?.suggestedName, "JPEG 2×1.jpg")
    }
}
