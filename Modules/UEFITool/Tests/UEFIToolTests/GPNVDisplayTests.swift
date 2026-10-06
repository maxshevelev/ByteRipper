import HelpBook
import UEFIImage
import XCTest
@testable import UEFITool

/// A GPNV store's rows: a record says what it holds, its details list its
/// text and its earlier copies, the store lists what is in force, and `?`
/// opens the entry.
final class GPNVDisplayTests: XCTestCase {
    private static func record(_ name: String, current: Bool, data: [UInt8]) -> [UInt8] {
        var bytes = Array("GPNV".utf8) + [0x0C, 0x01, current ? 1 : 0] + Array(name.utf8) + [0] + data
        bytes += [UInt8](repeating: 0xFF, count: 0x10C - bytes.count)
        return bytes
    }

    private static let key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"

    /// Padding opening with a store, as the Intel board keeps one.
    private static let bytes: [UInt8] = {
        var manufacturing: [UInt8] = Array("M8NRKD00311031C".utf8)
        manufacturing += [UInt8](repeating: 0xFF, count: 10)
        manufacturing += Array("90NR0551-M04320".utf8)
        manufacturing += [0xFF, 0xFF]
        manufacturing += Array("LR17MC00WI".utf8)
        manufacturing += [0xFF]
        manufacturing += Array("G533QS".utf8)
        let msdm: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0x1D, 0, 0, 0] + Array(key.utf8)
        let store = record("MFG0", current: false, data: Array("M8NRKD00311031C".utf8))
            + record("OA30", current: true, data: msdm)
            + record("MFG0", current: true, data: manufacturing)
        return store + [UInt8](repeating: 0xFF, count: 0x4000 - store.count)
    }()

    private func parsed() throws -> (UEFIImage, UEFINode) {
        let image = UEFIParser.parse(Self.bytes)
        let store = try XCTUnwrap(image.allNodes.first { $0.kind == .gpnvStore })
        return (image, store)
    }

    func testARecordsRowSaysWhatItHolds() throws {
        let (_, store) = try parsed()
        let reader = ImageReader(Self.bytes)
        let names = store.children.map { UEFITreeDisplay.name(for: $0, catalogue: .empty, reader: reader) }
        XCTAssertEqual(names, ["MFG0 = M8NRKD00311031C", "OA30 = \(Self.key)",
                               "MFG0 = M8NRKD00311031C, 90NR0551-M04320, LR17MC00WI, …"])
        XCTAssertEqual(store.children.map(UEFITreeDisplay.subtypeText), ["Superseded", "Current", "Current"])
        XCTAssertEqual(UEFITreeDisplay.typeText(for: store), "Padding", "padding to UEFITool")
        XCTAssertEqual(UEFIHelpTerms.term(for: store.children[0]), HelpTermID("gpnv"))
    }

    func testARecordsDetailsListItsTextAndItsCopies() throws {
        let (image, store) = try parsed()
        let reader = ImageReader(Self.bytes)
        let detail = UEFIDetail.build(for: store.children[2], image: image, reader: reader)
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["Kind"], "GPNV record")
        XCTAssertEqual(fields["State"], "Current")
        let text = try XCTUnwrap(detail.tables.first { $0.title == "Text in the record" })
        XCTAssertEqual(text.rows.map { $0[0].text }, ["+0x0", "+0x19", "+0x2A", "+0x35"])
        XCTAssertEqual(text.rows.map { $0[1].text }.last, "G533QS")
        XCTAssertEqual(detail.tables.last?.title, "Variable history", "the history is the card's last table, after the text")
        let history = try XCTUnwrap(detail.tables.first { $0.title == "Variable history" })
        XCTAssertEqual(history.rows.count, 2, "the record it replaced, and itself")

        let key = UEFIDetail.build(for: store.children[1], image: image, reader: reader)
        XCTAssertTrue(key.fields.contains { $0.label == "Windows product key" && $0.value == Self.key })
    }

    func testTheStoreListsTheRecordsInForce() throws {
        let (image, store) = try parsed()
        let detail = UEFIDetail.build(for: store, image: image, reader: ImageReader(Self.bytes))
        let fields = Dictionary(detail.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["Current entries"], "2")
        XCTAssertEqual(fields["Superseded entries"], "1")
        let table = try XCTUnwrap(detail.tables.first { $0.title == "Current entries" })
        XCTAssertEqual(table.rows.map { $0[0].text }, ["OA30", "MFG0"])
        XCTAssertEqual(table.rows.map { $0[1].text }, ["0x10C", "0x218"])
        XCTAssertEqual(table.rowTargets, [.node(store.children[1].id), .node(store.children[2].id)])
    }

    func testASupersededRecordIsACopyTheTreeCanLeaveOut() throws {
        let (_, store) = try parsed()
        XCTAssertEqual(NvramVariableHistory.supersededCopies(in: store, reader: ImageReader(Self.bytes)),
                       [store.children[0].id: store.children[2].id])
    }
}
