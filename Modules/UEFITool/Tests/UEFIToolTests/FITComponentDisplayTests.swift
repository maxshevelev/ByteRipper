import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// A structure the FIT names, read out of padding: named by what it is, its
/// header's fields in the details, and the glossary entry for it on `?`.
final class FITComponentDisplayTests: XCTestCase {
    /// Padding holding a Startup ACM at `0x1000`, a v1 Key Manifest at
    /// `0x2000` and a two-row FIT at `0x3000`.
    private func built() -> (UEFIImage, ImageReader) {
        var bytes = [UInt8](repeating: 0xFF, count: 0x4000)
        // Type 2, subtype 3; header length, version 0; chipset; Intel; BCD
        // date; 0x400 dwords; SVN 2.
        let acm: [UInt8] = [
            0x02, 0x00, 0x03, 0x00, 0xA1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0xB0, 0x00, 0x00,
            0x86, 0x80, 0x00, 0x00, 0x24, 0x06, 0x15, 0x20, 0x00, 0x04, 0x00, 0x00, 0x02, 0x00,
        ]
        bytes.replaceSubrange(0x1000..<(0x1000 + acm.count), with: acm)
        let keyManifest = Array("__KEYM__".utf8) + [0x10, 0x10, 0x00, 0x01]
        bytes.replaceSubrange(0x2000..<(0x2000 + keyManifest.count), with: keyManifest)
        let table = Array("_FIT_   ".utf8) + [0x02, 0x00, 0x00]
        bytes.replaceSubrange(0x3000..<(0x3000 + table.count), with: table)

        func row(_ kind: FITComponent.Kind, _ range: Range<UInt64>) -> UEFINode {
            UEFINode(kind: .fitComponent, subtype: kind.rawValue, name: kind.name,
                     header: range.lowerBound..<range.lowerBound, body: range, isFixed: true)
        }
        let rows = [
            UEFINode(kind: .padding, name: "Empty padding", range: 0..<0x1000, isErased: true),
            row(.startupACM, 0x1000..<0x2000),
            row(.keyManifest, 0x2000..<0x2241),
            row(.table, 0x3000..<0x3020),
        ]
        let region = UEFINode(kind: .region, subtype: UInt8(FlashRegionType.bios.rawValue),
                              name: "BIOS region", header: 0..<0, body: 0..<0x4000,
                              isFixed: true, children: rows)
        return (UEFIImage(size: 0x4000, roots: [region]), ImageReader(bytes))
    }

    private func fields(_ index: Int) -> [String: String] {
        let (image, reader) = built()
        let node = image.roots[0].children[index]
        let detail = UEFIDetail.build(for: node, image: image, reader: reader)
        return Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    func testARowIsNamedByWhatItIs() {
        let (image, _) = built()
        let names = image.roots[0].children.dropFirst()
            .map { UEFITreeDisplay.name(for: $0, catalogue: GuidsCatalogue(names: [:]), in: image) }
        XCTAssertEqual(names, ["Startup ACM", "Boot Guard Key Manifest", "FIT"])
    }

    func testTheDetailsReadTheHeader() {
        XCTAssertEqual(fields(1)["Kind"], "FIT component")
        XCTAssertEqual(fields(1)["Module subtype"], "Boot Guard")
        XCTAssertEqual(fields(1)["Chipset ID"], "0xB00C")
        XCTAssertEqual(fields(1)["Date"], "2015-06-24")
        XCTAssertEqual(fields(1)["ACM SVN"], "2")
        XCTAssertEqual(fields(2)["Version"], "0x10")
        XCTAssertEqual(fields(2)["KM ID"], "0x1")
        XCTAssertEqual(fields(3)["Entries"], "2")
    }

    func testEachOpensItsOwnGlossaryEntry() {
        let (image, _) = built()
        XCTAssertEqual(image.roots[0].children.dropFirst().map { UEFIHelpTerms.term(for: $0) },
                       [HelpTermID("acm"), HelpTermID("key-manifest"), HelpTermID("fit")])
    }
}
