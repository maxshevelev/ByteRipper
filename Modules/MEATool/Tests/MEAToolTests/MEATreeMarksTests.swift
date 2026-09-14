import XCTest
import MEFirmware
import ToolModuleKit
@testable import MEATool

/// What the ME Full Tree's rows wear (`ROW_MARKS.md` §5.3), read off the tree
/// the curator presents — so the marks are tested where the panel takes them.
final class MEATreeMarksTests: XCTestCase {
    private func analysis(_ overrides: [String: Any]) throws -> FirmwareAnalysis {
        var base: [String: Any] = [
            "family": "csme", "variant": "CSME",
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121],
            "release": "production", "type": "region", "sku": "", "platform": "",
            "sizeBytes": 0x200000, "regions": [], "issues": [],
        ]
        for (key, value) in overrides { base[key] = value }
        let data = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(FirmwareAnalysis.self, from: data)
    }

    private func module(_ id: Int, _ name: String, huffman: Bool = false,
                        attributes: (compression: Int, encryption: Int)? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "name": name, "offset": 0x100 * id,
                                  "isHuffman": huffman, "size": 0x80]
        if let attributes {
            row["extensions"] = [[
                "id": 0, "tag": 0x0A, "size": 0x60, "offset": 0x2000,
                "moduleAttributes": [
                    "compression": attributes.compression, "encryption": attributes.encryption,
                    "uncompressedSize": 0x1000, "compressedSize": 0x80,
                    "deviceID": 0, "vendorID": 0x8086, "moduleHash": "AB",
                ],
            ]]
        }
        return row
    }

    private func cpd(_ modules: [[String: Any]], checksumValid: Bool = true) -> [String: Any] {
        ["name": "FTPR", "offset": 0x1000, "headerVersion": 2, "headerLength": 0x14,
         "entryCount": modules.count, "checksumValid": checksumValid, "modules": modules]
    }

    private let metadataRow: [String: Any] = [
        "id": 0, "variant": "r2", "unknown0": 0, "deviceID": 0, "vendorID": 0x8086,
        "sizeUncompressed": 0x1000, "sizeCompressed": 0x80, "hash": "CD",
    ]

    private let manifest: [String: Any] = [
        "offset": 0x1000, "tag": "$MN2", "format": "r2",
        "major": 15, "minor": 40, "hotfix": 37, "build": 3121, "svn": 3,
        "day": 24, "month": 3, "year": 2021, "keyHash": "", "signatureHash": "",
    ]

    private func root(_ title: String, in roots: [MEANode]) throws -> MEANode {
        try XCTUnwrap(roots.first { $0.title == title }, "a “\(title)” group")
    }

    private func modules(in roots: [MEANode]) throws -> [MEANode] {
        let partition = try root("Code Partition ($CPD)", in: roots)
        return try XCTUnwrap(partition.children.first { $0.title == "Modules" }).children
    }

    /// A module stored compressed wears the badge — indigo only for the one
    /// the metadata table is read out of, grey for the rest and for anything
    /// encrypted; a module stored as it is wears none.
    func testCompressedModulesWearTheBadge() throws {
        let roots = MEACurator.present(try analysis([
            "codePartition": cpd([
                module(0, "kernel"), module(1, "kernel.met", attributes: (2, 0)),
                module(2, "pm", huffman: true),
                module(3, "crypto"), module(4, "crypto.met", attributes: (2, 1)),
                module(5, "plain"),
            ]),
            "rbePmMetadata": [metadataRow],
        ]))
        let rows = try modules(in: roots)
        func roles(_ name: String) -> [ToolRowMarks.Role] {
            rows.first { $0.title == name }?.marks.roles ?? []
        }

        XCTAssertEqual(roles("kernel"), [.compressed(algorithm: "LZMA", decoded: false)])
        XCTAssertEqual(roles("pm"), [.compressed(algorithm: "Huffman", decoded: true)],
                       "the metadata table below is what came out of it")
        XCTAssertEqual(roles("crypto"), [.compressed(algorithm: "Encrypted LZMA", decoded: false)])
        XCTAssertEqual(roles("plain"), [])
    }

    /// A module check that failed is a caution on that module's row — beside
    /// its badge — and on no other row; an issue about the image stays off the
    /// module rows.
    func testAFailedModuleCheckIsACautionOnItsRow() throws {
        let roots = MEACurator.present(try analysis([
            "codePartition": cpd([
                module(0, "kernel"), module(1, "kernel.met", attributes: (2, 0)),
                module(2, "plain"),
            ]),
            "issues": [
                ["id": 19, "severity": "warning", "message": "LZMA module \"kernel\" does not decompress.",
                 "module": "kernel"],
                ["id": 3, "severity": "note", "message": "This firmware is not in the database."],
            ],
        ]))
        let rows = try modules(in: roots)
        let kernel = try XCTUnwrap(rows.first { $0.title == "kernel" })

        XCTAssertEqual(kernel.marks.problem, .caution(["LZMA module \"kernel\" does not decompress."]))
        XCTAssertEqual(kernel.marks.roles, [.compressed(algorithm: "LZMA", decoded: false)])
        XCTAssertNil(rows.first { $0.title == "plain" }?.marks.problem)
        XCTAssertNotNil(roots.first { $0.title == "Issues" }, "still listed with the rest")
        XCTAssertTrue(MEATreeMarks.legendMarks.contains(.caution))
    }

    /// The metadata rows wear the rail when their module is stored compressed,
    /// and not otherwise.
    func testTheMetadataRowsWearTheRailWhenTheirModuleIsCompressed() throws {
        let compressed = MEACurator.present(try analysis([
            "codePartition": cpd([module(0, "pm", huffman: true)]),
            "rbePmMetadata": [metadataRow],
        ]))
        let group = try root("RBE/PM Metadata", in: compressed)
        XCTAssertTrue(group.marks.hasRail)
        XCTAssertTrue(group.children.allSatisfy(\.marks.hasRail))
        XCTAssertEqual(group.marks.decompressedFrom, "Read out of the pm module, stored Huffman compressed")

        let plain = MEACurator.present(try analysis([
            "codePartition": cpd([module(0, "pm")]),
            "rbePmMetadata": [metadataRow],
        ]))
        XCTAssertFalse(try root("RBE/PM Metadata", in: plain).marks.hasRail)
    }

    /// The manifest holds the hashes the modules are checked against, and says
    /// so when its own signature does not check out.
    func testTheManifestHoldsChecksAndSaysWhenItsSignatureFails() throws {
        let good = MEACurator.present(try analysis(["manifest": manifest, "rsaSignatureValid": true]))
        let row = try root("Manifest", in: good)
        guard case .holdsChecks? = row.marks.roles.first else { return XCTFail("the badge") }
        XCTAssertNil(row.marks.problem)

        let bad = MEACurator.present(try analysis(["manifest": manifest, "rsaSignatureValid": false]))
        XCTAssertEqual(try root("Manifest", in: bad).marks.problem?.isError, true)
    }

    /// A checksum that does not add up is an error on the row it belongs to; one
    /// the version does not carry is not a problem.
    func testTablesWithAWrongChecksumAreErrors() throws {
        let roots = MEACurator.present(try analysis([
            "codePartition": cpd([module(0, "$MN2")], checksumValid: false),
            "cseLayoutTable": ["offset": 0, "version": 0x17, "redundancy": false,
                               "checksumValid": false, "partitions": []],
            "bootPartitions": [["offset": 0x100, "partitionName": "Boot 1", "version": 1,
                                "redundancy": false, "entries": []]],
        ]))
        XCTAssertEqual(try root("Code Partition ($CPD)", in: roots).marks.problem,
                       .error(["Invalid $CPD CRC-32 checksum"]))
        XCTAssertEqual(try root("CSE Layout Table", in: roots).marks.problem,
                       .error(["Invalid CSE Layout Table CRC-32"]))
        let boot = try XCTUnwrap(try root("Boot Partitions (BPDT)", in: roots).children.first)
        XCTAssertNil(boot.marks.problem, "a 1.6 table has no CRC to fail")
    }

    /// The legend lists what the tree draws, and nothing it does not: no
    /// background, no partly-protected badge, no verdicts.
    func testTheLegendListsNoBackground() {
        XCTAssertFalse(MEATreeMarks.legendMarks.contains { $0.channel == .background })
        XCTAssertFalse(MEATreeMarks.legendMarks.contains(.partlyProtected))
        XCTAssertFalse(MEATreeMarks.legendMarks.contains { $0.channel == .verdict })
    }
}
