import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// An EC image row: named by what it carries, a copy saying so, and the
/// details reading the image again from the block it is in.
final class ECImageDisplayTests: XCTestCase {
    /// A 16 KiB EC region: a Microchip image at its start and its copy at
    /// `0x2000`.
    private func built() -> (UEFIImage, ImageReader) {
        var bytes = [UInt8](repeating: 0xFF, count: 0x4000)
        let image = Array("PHCM".utf8) + [UInt8](repeating: 0x5A, count: 0x7FC)
        bytes.replaceSubrange(0..<0x800, with: image)
        bytes.replaceSubrange(0x2000..<0x2800, with: image)
        let rows = [
            UEFINode(kind: .ecImage, name: "Microchip MEC image", header: 0..<0, body: 0..<0x1000, isFixed: true),
            UEFINode(kind: .padding, name: "Empty padding", range: 0x1000..<0x2000, isErased: true),
            UEFINode(kind: .ecImage, subtype: ECImage.copySubtype, name: "Microchip MEC image",
                     header: 0x2000..<0x2000, body: 0x2000..<0x3000, isFixed: true),
            UEFINode(kind: .padding, name: "Empty padding", range: 0x3000..<0x4000, isErased: true),
        ]
        let region = UEFINode(kind: .region, subtype: UInt8(FlashRegionType.ec.rawValue),
                              name: "EC region", header: 0..<0, body: 0..<0x4000,
                              isFixed: true, children: rows)
        return (UEFIImage(size: 0x4000, roots: [region]), ImageReader(bytes))
    }

    func testACopySaysSo() {
        let (image, _) = built()
        let names = image.roots[0].children.filter { $0.kind == .ecImage }
            .map { UEFITreeDisplay.name(for: $0, catalogue: GuidsCatalogue(names: [:]), in: image) }
        XCTAssertEqual(names, ["Microchip MEC image, 4 KB", "Microchip MEC image, 4 KB (copy)"])
    }

    func testTheDetailsSayWhatTheImageIsAndWhatItCopies() {
        let (image, reader) = built()
        func fields(_ index: Int) -> [String: String] {
            let node = image.roots[0].children[index]
            let detail = UEFIDetail.build(for: node, image: image, reader: reader)
            return Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        XCTAssertEqual(fields(0)["Kind"], "EC firmware image")
        XCTAssertEqual(fields(0)["Vendor"], "Microchip")
        XCTAssertEqual(fields(0)["Signature"], "PHCM")
        XCTAssertEqual(fields(0)["Written"], "0x800 (2048)")
        XCTAssertNil(fields(0)["Copy of"])
        XCTAssertEqual(fields(2)["Copy of"], "0x0")
    }

    func testAnImageOpensTheECPage() {
        let (image, _) = built()
        XCTAssertEqual(UEFIHelpTerms.term(for: image.roots[0].children[0]), HelpTermID("ec-firmware"))
    }
}
