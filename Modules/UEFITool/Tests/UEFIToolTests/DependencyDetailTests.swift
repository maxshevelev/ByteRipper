import UEFIImage
import XCTest
@testable import UEFITool

/// The dependency expression in the details: a file answers with the section
/// among its children, the section answers for itself, and a broken expression
/// says what is wrong rather than showing half of it as if it were whole.
final class DependencyDetailTests: XCTestCase {
    private let first = EFIGUID("11111111-1111-1111-1111-111111111111")!
    private let second = EFIGUID("22222222-2222-2222-2222-222222222222")!
    private struct Built {
        let image: UEFIImage
        let file: UEFINode
        let section: UEFINode
        let reader: ImageReader
    }

    private func built(_ depex: [UInt8], fileType: UInt8 = 0x06,
                       sectionType: UInt8 = 0x1B) -> Built {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        let sectionStart = 0x18
        let bodyStart = 0x1C
        let size = UInt32(4 + depex.count)
        bytes[sectionStart] = UInt8(size & 0xFF)
        bytes[sectionStart + 1] = UInt8((size >> 8) & 0xFF)
        bytes[sectionStart + 2] = UInt8((size >> 16) & 0xFF)
        bytes[sectionStart + 3] = sectionType
        bytes.replaceSubrange(bodyStart..<(bodyStart + depex.count), with: depex)

        let section = UEFINode(
            id: .root.child(0).child(0), kind: .section, subtype: sectionType,
            name: sectionType == 0x13 ? "DXE dependency" : "PEI dependency",
            header: UInt64(sectionStart)..<UInt64(bodyStart),
            body: UInt64(bodyStart)..<UInt64(bodyStart + depex.count))
        let file = UEFINode(
            id: .root.child(0), kind: .file, subtype: fileType,
            name: fileType == 0x07 ? "A DXE driver" : "A PEIM",
            header: 0..<0x18, body: 0x18..<0x60, children: [section])
        let image = UEFIImage(size: 0x100, roots: [file])
        return Built(image: image, file: file, section: section, reader: ImageReader(bytes))
    }

    private func fields(_ built: Built, node: UEFINode? = nil,
                        names: [EFIGUID: String] = [:]) -> (detail: UEFINodeDetail,
                                                              byLabel: [String: UEFIDetailField]) {
        let node = node ?? built.file
        let detail = UEFIDetail.build(
            for: node, image: built.image, reader: built.reader,
            catalogue: GuidsCatalogue(names: names), in: .english)
        return (detail, Dictionary(detail.fields.map { ($0.label, $0) },
                                   uniquingKeysWith: { first, _ in first }))
    }

    private var chain: [UInt8] {
        [0x02] + first.bytes + [0x02] + second.bytes + [0x03, 0x08]
    }

    func testAFileShowsTheExpressionItsSectionCarries() {
        let built = built(chain)
        let (detail, fields) = fields(built, names: [first: "First PPI", second: "Second PPI"])
        XCTAssertEqual(fields["Dependencies"]?.value, "First PPI AND Second PPI")
        XCTAssertEqual(fields["Dependencies"]?.tone, .standard)

        let table = detail.tables.first { $0.title == "Dependency expression" }
        XCTAssertEqual(table?.columns, ["Offset", "Operation", "Name", "PPI GUID"])
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [
            ["0x1C", "PUSH", "First PPI", first.description],
            ["0x2D", "PUSH", "Second PPI", second.description],
            ["0x3E", "AND", "", ""],
            ["0x3F", "END", "", ""],
        ])
    }

    func testTheSectionAnswersForItself() {
        let built = built(chain)
        let (_, fields) = fields(built, node: built.section,
                                 names: [first: "First PPI", second: "Second PPI"])
        XCTAssertEqual(fields["Dependencies"]?.value, "First PPI AND Second PPI")
    }

    func testADXEDriverShowsItsDependencies() {
        let depex: [UInt8] = [0x00, 0x02] + first.bytes + [0x08]
        let built = built(depex, fileType: 0x07, sectionType: 0x13)
        let (detail, fields) = fields(built, names: [first: "EfiSomeProtocolGuid"])
        XCTAssertEqual(fields["Dependencies"]?.value, "BEFORE EfiSomeProtocolGuid")

        let table = detail.tables.first { $0.title == "Dependency expression" }
        XCTAssertEqual(table?.columns, ["Offset", "Operation", "Name", "Protocol GUID"])
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [
            ["0x1C", "BEFORE", "", ""],
            ["0x1D", "PUSH", "EfiSomeProtocolGuid", first.description],
            ["0x2E", "END", "", ""],
        ])
    }

    func testAFilesWithoutADependencyHasNoDependencyRow() {
        let built = built(chain)
        let plain = UEFINode(
            id: .root.child(1), kind: .file, subtype: 0x07, name: "A driver",
            header: 0..<0x18, body: 0x18..<0x40)
        let (detail, fields) = fields(built, node: plain)
        XCTAssertNil(fields["Dependencies"])
        XCTAssertTrue(detail.tables.isEmpty)
    }

    func testABrokenExpressionSaysWhatIsWrong() {
        let built = built([0x03, 0x08])
        let (_, fields) = fields(built)
        XCTAssertEqual(fields["Dependencies"]?.value,
                       "The dependency expression needs more operands at 0x1C.")
        XCTAssertEqual(fields["Dependencies"]?.tone, .bad)
    }

    func testBytesAfterEndAreAWarningNotAVerdict() {
        let built = built([0x02] + first.bytes + [0x08, 0xAA])
        let (_, fields) = fields(built, names: [first: "First PPI"])
        XCTAssertEqual(fields["Dependencies"]?.value, "First PPI")
        XCTAssertEqual(fields["Dependency problem"]?.value,
                       "The dependency expression has bytes after END (1).")
        XCTAssertEqual(fields["Dependency problem"]?.tone, .caution)
    }

    func testAnEmptySectionIsAlways() {
        let built = built([])
        let (detail, fields) = fields(built)
        XCTAssertEqual(fields["Dependencies"]?.value, "TRUE")
        XCTAssertTrue(detail.tables.isEmpty)
    }
}
