import UEFIImage
import XCTest
@testable import UEFITool

/// The dependency expression is not in the details of a module or of its
/// dependency section: the Code panel's Interfaces tab is where it is read.
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

    func testNeitherTheFileNorItsSectionShowsTheExpression() {
        let built = built(chain)
        for node in [built.file, built.section] {
            let (detail, fields) = fields(built, node: node, names: [first: "First PPI", second: "Second PPI"])
            XCTAssertNil(fields["Dependencies"], node.name)
            XCTAssertNil(fields["Dependency problem"], node.name)
            XCTAssertFalse(detail.tables.contains { $0.title == "Dependency expression" }, node.name)
        }
    }
}
