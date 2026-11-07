import XCTest
import MEFirmware
import PartCodec
@testable import MEPresentation

/// What a row of the ME tree opens as in a fragment panel (`MEAParts`), and
/// which file rows are drawn as empty.
final class MEAPartsTests: XCTestCase {
    /// A row with one range opens as a copy of it, named by its title.
    func testARowWithARangeOpensAsACopy() throws {
        let row = MEANode(path: [1, 0], title: "FTPR", range: 0x1000..<0x2000)

        let open = try XCTUnwrap(MEAParts.open(row))

        XCTAssertEqual(open.name, "FTPR")
        XCTAssertEqual(open.source, 0x1000..<0x2000)
        XCTAssertTrue(open.codec is CopyPartCodec)
    }

    /// A file opens as its chunks gathered in the file's order, linked to their
    /// span, and is named as it would be saved: the last path component.
    func testAFileOpensAsItsChunksGathered() throws {
        let file = MEANode(path: [2, 0, 5], title: "/home/mctp/smt2_devices",
                           extents: [0x9000..<0x9040, 0x8000..<0x8040])

        let open = try XCTUnwrap(MEAParts.open(file))

        XCTAssertEqual(open.name, "smt2_devices")
        XCTAssertEqual(open.source, 0x8000..<0x9040)
        let gather = try XCTUnwrap(open.codec as? GatherPartCodec)
        XCTAssertEqual(gather.stretches, [0x9000..<0x9040, 0x8000..<0x8040])
    }

    /// A row without bytes of its own, and an empty file, open nothing.
    func testARowWithoutBytesOpensNothing() {
        XCTAssertNil(MEAParts.open(MEANode(path: [0], title: "Manifest")))
        XCTAssertNil(MEAParts.open(MEANode(path: [2, 0, 6], title: "empty", extents: [])))
    }

    /// A file whose chain carries only its Integrity table holds no data: its
    /// row reads empty, as its subtitle does. One with data does not.
    func testAFileWithNoContentIsDrawnEmpty() throws {
        func file(_ index: Int, size: Int, contentSize: Int?) -> [String: Any] {
            var file: [String: Any] = ["index": index, "size": size,
                                       "extents": [[0x100 * index, 0x100 * index + size]]]
            if let contentSize { file["contentSize"] = contentSize }
            return file
        }
        let json: [String: Any] = [
            "family": "csme", "variant": "CSME",
            "version": ["major": 15, "minor": 0, "hotfix": 30, "build": 1716],
            "release": "production", "type": "region", "sku": "", "platform": "",
            "sizeBytes": 0x2000, "regions": [], "issues": [],
            "mfsVolume": [
                "offset": 0, "pageSize": 0x2000, "pageCount": 1,
                "systemPageCount": 1, "dataPageCount": 0, "signatureValid": true,
                "volumeSize": 0, "computedVolumeSize": 0, "fileRecordCount": 1024,
                "usedFileCount": 3, "ftblDictionary": 0x0A, "ftblPlatform": 4,
                "ftblReserved": 0, "usesFTBL": true, "presentFileCount": 3,
                "fileBytes": 0, "configurations": [], "reservedIntegrity": [],
                "files": [file(1, size: 0x34, contentSize: 0),
                          file(2, size: 0x40, contentSize: 0x0C),
                          file(3, size: 0x20, contentSize: nil)],
            ] as [String: Any],
        ]
        let analysis = try JSONDecoder().decode(
            FirmwareAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        let roots = MEACurator.present(analysis, in: .english)
        func find(_ title: String, in nodes: [MEANode]) -> MEANode? {
            for node in nodes {
                if node.title == title { return node }
                if let found = find(title, in: node.children) { return found }
            }
            return nil
        }

        XCTAssertEqual(try XCTUnwrap(find("File 1", in: roots)).isEmptySection, true,
                       "a chain of nothing but its Integrity table is an empty file")
        XCTAssertEqual(try XCTUnwrap(find("File 2", in: roots)).isEmptySection, false)
        XCTAssertEqual(try XCTUnwrap(find("File 3", in: roots)).isEmptySection, false)
    }
}
