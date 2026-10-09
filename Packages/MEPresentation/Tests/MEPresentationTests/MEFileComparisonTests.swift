import CryptoKit
import XCTest
import MEFirmware
@testable import MEPresentation

/// Two dumps' ME files compared by what they hold, wherever each volume put
/// them (`MEFileComparison`, `Design/AGENT_PLAN.md` stage 9).
final class MEFileComparisonTests: XCTestCase {
    // MARK: - Fixtures

    /// A dump of `size` bytes with `bytes` written at each offset.
    private func image(_ writes: [Int: [UInt8]], size: Int = 0x200) -> Data {
        var data = Data(repeating: 0xFF, count: size)
        for (offset, bytes) in writes {
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        return data
    }

    private func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02X", $0) }.joined()
    }

    private func integrity(counter: Int) -> [String: Any] {
        ["size": 0x28, "hmacHex": "AABB", "flagsRaw": 2,
         "antiReplayProtection": true, "encryptionProtection": false,
         "antiReplayIndex": 3, "securityVersion": 0,
         "arRandom": 0x99, "arCounter": counter, "nonceHex": "CCDD"]
    }

    /// One MFS file stored at `extents`, whose content is `content`.
    private func mfsFile(_ index: Int, _ extents: [Range<Int>], _ content: [UInt8],
                         contentSize: Int? = nil, counter: Int? = nil,
                         intact: Bool = true) -> [String: Any] {
        var file: [String: Any] = [
            "index": index, "size": extents.reduce(0) { $0 + $1.count },
            "extents": extents.map { [$0.lowerBound, $0.upperBound] },
            "contentDigest": digest(Array(content.prefix(contentSize ?? content.count))),
            "chainIntact": intact,
        ]
        if let contentSize { file["contentSize"] = contentSize }
        if let counter { file["integrity"] = integrity(counter: counter) }
        return file
    }

    private func analysis(mfs files: [[String: Any]]?, efs: [[String: Any]]?? = .none,
                          regions: [String] = []) throws -> FirmwareAnalysis {
        var base: [String: Any] = [
            "family": "csme", "variant": "CSME",
            "version": ["major": 15, "minor": 0, "hotfix": 30, "build": 1716],
            "release": "production", "type": "region", "sku": "", "platform": "",
            "sizeBytes": 0x200,
            "regions": regions.enumerated().map { ["id": $0.offset, "name": $0.element, "offset": 0, "size": 0x1000, "flags": 0,
                                      ] as [String: Any] },
            "issues": [],
        ]
        if let files {
            base["mfsVolume"] = [
                "offset": 0, "pageSize": 0x2000, "pageCount": 1,
                "systemPageCount": 1, "dataPageCount": 0, "signatureValid": true,
                "volumeSize": 0, "computedVolumeSize": 0, "fileRecordCount": 1024,
                "usedFileCount": files.count, "ftblDictionary": 0x0A, "ftblPlatform": 4,
                "ftblReserved": 0, "usesFTBL": true, "presentFileCount": files.count,
                "fileBytes": 0, "files": files, "configurations": [], "reservedIntegrity": [],
            ] as [String: Any]
        }
        if case .some(let efsFiles) = efs {
            var volume: [String: Any] = [
                "offset": 0x100, "pageSize": 0x1000, "systemPageCount": 1,
                "dataPageCount": 1, "scratchPageCount": 0, "scratchPagesEmpty": true,
                "dataPageCountMatchesSystem": true, "dictionary": 0x0A,
                "revision": 1, "unknown1": 2, "dictionaryRevision": 1,
                "dataPagesCommitted": 1, "dataPagesReserved": 0,
                "systemHeaderCRCValid": true, "indexesCRCValid": true,
                "firstIndexPaddingEmpty": true, "dataPageOrder": [0],
                "dataPageHeaderCRCsValid": true, "dataPageFooterCRCsValid": true,
            ]
            if let efsFiles { volume["files"] = efsFiles }
            base["efsVolume"] = volume
        }
        let data = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(FirmwareAnalysis.self, from: data)
    }

    private func reader(_ data: Data) -> (Range<Int>) -> Data? {
        { range in range.upperBound <= data.count ? data.subdata(in: range) : nil }
    }

    // MARK: - Matching by content

    /// The volume moved the file: other addresses, another order of its
    /// stretches, the same bytes. It is the same file, and it says it moved.
    func testAFileStoredElsewhereIsTheSameAndMoved() throws {
        let content: [UInt8] = Array(0..<0x20)
        let a = image([0x10: Array(content[0..<0x10]), 0x40: Array(content[0x10..<0x20])])
        let b = image([0x80: Array(content[0..<0x10]), 0x08: Array(content[0x10..<0x20])])
        let result = MEFileComparison.compare(
            try analysis(mfs: [mfsFile(7, [0x10..<0x20, 0x40..<0x50], content)]),
            try analysis(mfs: [mfsFile(7, [0x80..<0x90, 0x08..<0x18], content)]),
            readA: reader(a), readB: reader(b))
        XCTAssertEqual(result.gaps, [])
        let row = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(row.status, .same)
        XCTAssertTrue(row.moved)
        XCTAssertNil(row.differingBytes)
    }

    /// Bytes that differ are counted over the content; the Integrity table is
    /// compared apart, and a table that changed alone leaves the file the same.
    func testContentAndIntegrityAreComparedApart() throws {
        let left: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let right: [UInt8] = [1, 2, 9, 4, 5, 6, 9, 8]
        let a = image([0x10: left + [0xAA, 0xAA], 0x30: left + [0xAA, 0xAA]])
        let b = image([0x10: right + [0xBB, 0xBB], 0x30: left + [0xBB, 0xBB]])
        let result = MEFileComparison.compare(
            try analysis(mfs: [mfsFile(1, [0x10..<0x1A], left + [0xAA, 0xAA], contentSize: 8, counter: 1),
                               mfsFile(2, [0x30..<0x3A], left + [0xAA, 0xAA], contentSize: 8, counter: 1)]),
            try analysis(mfs: [mfsFile(1, [0x10..<0x1A], right + [0xBB, 0xBB], contentSize: 8, counter: 2),
                               mfsFile(2, [0x30..<0x3A], left + [0xBB, 0xBB], contentSize: 8, counter: 2)]),
            readA: reader(a), readB: reader(b))
        XCTAssertEqual(result.rows.map(\.status), [.different, .same])
        XCTAssertEqual(result.rows[0].differingBytes, 2, "the table's bytes are not counted")
        XCTAssertEqual(result.rows[0].integrityDiffers, true)
        XCTAssertEqual(result.rows[1].integrityDiffers, true, "rewritten, holding the same")
        XCTAssertFalse(result.rows[1].moved)
    }

    /// Without the bytes the digests decide; a file of another length differs
    /// and no count is given.
    func testWithoutTheBytesTheDigestsDecide() throws {
        let result = MEFileComparison.compare(
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4]), mfsFile(2, [8..<12], [1, 1, 1, 1]),
                               mfsFile(3, [16..<20], [5, 5, 5, 5])]),
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4]), mfsFile(2, [8..<12], [1, 1, 1, 2]),
                               mfsFile(3, [16..<22], [5, 5, 5, 5, 5, 5])]))
        XCTAssertEqual(result.rows.map(\.status), [.same, .different, .different])
        XCTAssertEqual(result.rows.map(\.differingBytes), [nil, nil, nil])
    }

    /// Bytes that are no longer what the analysis read there — the dump was
    /// edited since — are not trusted over the digest the analysis made.
    func testBytesChangedSinceTheAnalysisLeaveItToTheDigests() throws {
        let result = MEFileComparison.compare(
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4])]),
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4])]),
            readA: reader(image([0: [9, 9, 9, 9]])), readB: reader(image([0: [1, 2, 3, 4]])))
        XCTAssertEqual(result.rows.first?.status, .same)
        XCTAssertNil(result.rows.first?.differingBytes)
    }

    func testAFileInOneDumpOnlyIsSaidToBe() throws {
        let result = MEFileComparison.compare(
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4]), mfsFile(5, [8..<12], [0, 0, 0, 0])]),
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4]), mfsFile(9, [8..<12], [0, 0, 0, 0])]))
        XCTAssertEqual(result.rows.map(\.key), [1, 5, 9])
        XCTAssertEqual(result.rows.map(\.status), [.same, .onlyInA, .onlyInB])
    }

    /// A chain that broke off holds only part of the file: no verdict.
    func testABrokenChainGivesNoVerdict() throws {
        let result = MEFileComparison.compare(
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4], intact: false)]),
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4])]))
        XCTAssertEqual(result.rows.first?.status, .incomplete)
    }

    // MARK: - Volumes that cannot be compared

    /// The EFS of one dump cannot be read — its System page erased, as on
    /// `2.rom`. Its files are not listed as missing from that dump; the volume
    /// is named as not compared, and the MFS still is.
    func testAnUnreadableVolumeIsAGapAndNotFilesOnlyInOneDump() throws {
        let efsFiles: [[String: Any]] = [[
            "fileID": 4, "dataOffset": 0, "storedSize": 4, "metadataUnknown": 0,
            "contentSize": 4, "extents": [[0x110, 0x114]], "contentDigest": digest([1, 2, 3, 4]),
        ]]
        let result = MEFileComparison.compare(
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4])], efs: .some(efsFiles), regions: ["MFS", "EFS"]),
            try analysis(mfs: [mfsFile(1, [0..<4], [1, 2, 3, 4])], regions: ["MFS", "EFS"]))
        XCTAssertEqual(result.gaps, [MEFileComparison.Gap(volume: .efs, inA: false, reason: .unreadable)])
        XCTAssertEqual(result.rows.map(\.volume), [.mfs])
    }

    func testAVolumeNeitherDumpHasIsNoGap() throws {
        let result = MEFileComparison.compare(try analysis(mfs: []), try analysis(mfs: []))
        XCTAssertEqual(result.gaps, [])
        XCTAssertEqual(result.rows, [])
    }

    func testAnEFSNotCutIntoFilesIsAGap() throws {
        let result = MEFileComparison.compare(
            try analysis(mfs: [], efs: .some(nil)), try analysis(mfs: [], efs: .some([])))
        XCTAssertEqual(result.gaps, [MEFileComparison.Gap(volume: .efs, inA: true, reason: .filesNotNamed)])
    }

    // MARK: - Names

    func testTheRowsAreNamedByTheFileTableOfEitherDump() throws {
        let table = try FileTable.parse("""
        {"04": {"0A": {"FTBL": {"10003500": "/home/mca/manuf_ver,1,0,0,40,0,70,7,448"}}}}
        """)
        let a = try analysis(mfs: [mfsFile(7, [0..<4], [1, 2, 3, 4])])
        let b = try analysis(mfs: [mfsFile(7, [0..<4], [1, 2, 3, 4])])
        let names = MEFileComparison.Names(mfs: MFSFileNames(table: table, volume: try XCTUnwrap(b.mfsVolume)),
                                           efs: .none)
        let result = MEFileComparison.compare(a, b, names: (.none, names))
        XCTAssertEqual(result.rows.first?.name, "/home/mca/manuf_ver")
        XCTAssertEqual(result.rows.first?.encrypted, false, "the table's flag, read as it is")
    }
}
