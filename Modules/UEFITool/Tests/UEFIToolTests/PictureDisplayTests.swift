import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// A picture row: its details read it again, `?` opens the picture entry,
/// and saving it offers a file a viewer opens, by its format's extension.
final class PictureDisplayTests: XCTestCase {
    /// The smallest JPEG the reader takes: a 2×1 frame, an empty scan.
    private static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08] + Array("Exif".utf8) + [0, 0]
        + [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x02, 0x01, 0x01, 0x11, 0x00]
        + [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9]

    private func built() -> (UEFIImage, ImageReader) {
        var bytes = [UInt8](repeating: 0xFF, count: 0x1000)
        bytes.replaceSubrange(0x100..<(0x100 + Self.jpeg.count), with: Self.jpeg)
        let picture = UEFINode(kind: .picture, subtype: Picture.Format.jpeg.rawValue, name: "JPEG 2×1",
                               header: 0x100..<0x100,
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

    func testItOpensItsEntryAndSavesAsAJPEG() {
        let (image, _) = built()
        let node = image.roots[0].children[0]
        XCTAssertEqual(UEFIHelpTerms.term(for: node), HelpTermID("picture"))
        XCTAssertEqual(UEFIPresenter.nodeOpen(for: node, in: image, body: false)?.suggestedName, "JPEG 2×1.jpg")
    }

    /// An animated GIF says how many images it holds; a still one does not.
    func testAnAnimationSaysHowManyFramesItHas() {
        var gif = Array("GIF89a".utf8) + [2, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF]
        for _ in 0..<3 {
            gif += [0x21, 0xF9, 0x04, 0, 0x04, 0, 0, 0x00]
            gif += [0x2C, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0x02, 0x02, 0x44, 0x01, 0x00]
        }
        gif += [0x3B]
        let picture = UEFINode(kind: .picture, subtype: Picture.Format.gif.rawValue, name: "GIF 2×1",
                               header: 0..<0, body: 0..<UInt64(gif.count))
        let image = UEFIImage(size: UInt64(gif.count), roots: [picture])
        let detail = UEFIDetail.build(for: image.roots[0], image: image, reader: ImageReader(gif))
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["Frames"], "3")

        let (still, reader) = built()
        XCTAssertFalse(UEFIDetail.build(for: still.roots[0].children[0], image: still, reader: reader)
            .fields.contains { $0.label == "Frames" })
    }

    /// A BMP whose header asks for more than its section holds says so, and
    /// a BMP saves as one.
    func testABMPCutShortSaysSo() {
        var bmp: [UInt8] = [0x42, 0x4D, 0x4E, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 0x28, 0, 0, 0]
        bmp += [3, 0, 0, 0, 2, 0, 0, 0, 1, 0, 24, 0] + [UInt8](repeating: 0, count: 24)
        bmp += [UInt8](repeating: 0x7F, count: 20)              // 24 bytes of rows declared
        let picture = UEFINode(kind: .picture, subtype: Picture.Format.bmp.rawValue, name: "BMP 3×2",
                               header: 0..<0, body: 0..<UInt64(bmp.count))
        let section = UEFINode(kind: .section, subtype: 0x19, name: "Raw section", header: 0..<0,
                               body: 0..<UInt64(bmp.count), children: [picture])
        let image = UEFIImage(size: UInt64(bmp.count), roots: [section])
        let detail = UEFIDetail.build(for: image.roots[0].children[0], image: image, reader: ImageReader(bmp))
        let fields = Dictionary(detail.fields.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["Format"]?.value, "BMP (24-bit)")
        XCTAssertEqual(fields["Declared size"]?.value, "0x4E (78) — the section ends earlier")
        XCTAssertEqual(fields["Declared size"]?.tone, .bad)
        XCTAssertEqual(UEFIPresenter.nodeOpen(for: image.roots[0].children[0], in: image, body: false)?.suggestedName,
                       "BMP 3×2.bmp")
    }
}
