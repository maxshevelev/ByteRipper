import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// An AMD microcode row: its details read the header, `?` opens the
/// microcode entry.
final class AMDMicrocodeDisplayTests: XCTestCase {
    /// A Cezanne patch, as `SPI_EF6018_128Mbit.*` carries it, at `0x1000`.
    private func parsed() -> (UEFIImage, ImageReader) {
        var bytes = [UInt8](repeating: 0x11, count: 0x4000)
        let header: [UInt8] = [0x23, 0x20, 0x07, 0x07, 0x0F, 0x00, 0x50, 0x0A, 0x05, 0x80, 0, 0]
            + [UInt8](repeating: 0, count: 12) + [0x00, 0xA5, 0, 0, 0, 0, 0, 0]
        bytes.replaceSubrange(0x1000..<0x1020, with: header)
        return (UEFIParser.parse(bytes), ImageReader(bytes))
    }

    func testTheDetailsSayWhatThePatchIs() throws {
        let (image, reader) = parsed()
        let patch = try XCTUnwrap(image.allNodes.first { $0.kind == .amdMicrocode })
        let detail = UEFIDetail.build(for: patch, image: image, reader: reader)
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(fields["Kind"], "AMD microcode")
        XCTAssertEqual(fields["Date"], "2023-07-07")
        XCTAssertEqual(fields["CPUID"], "00A50F00")
        XCTAssertEqual(fields["Revision"], "0xA50000F")
        XCTAssertEqual(fields["Loader ID"], "0x8005")
        XCTAssertNil(fields["North bridge"], "a patch tied to no chipset says none")
        XCTAssertEqual(UEFIHelpTerms.term(for: patch), HelpTermID("microcode"))
    }
}
