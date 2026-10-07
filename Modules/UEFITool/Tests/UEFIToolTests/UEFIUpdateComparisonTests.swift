import ToolModuleKit
import UEFIImage
import XCTest
@testable import UEFITool

/// A dump's BIOS region held against an update's (`UEFIUpdateComparison`):
/// each part's state, what is ticked before the user touches anything, and
/// the transaction that writes only what differs.
final class UEFIUpdateComparisonTests: XCTestCase {
    /// Where the BIOS region starts in the dump.
    private let base: UInt64 = 0xB0_0000

    /// Code, NVRAM, a vendor's per-board store the update leaves empty, and
    /// more code — the shape of an ASUS file.
    private var update: BIOSGuardUpdate {
        BIOSGuardUpdate(
            platform: "RAPTORLAKE",
            entries: [
                .init(name: "FV_BB", key: "/B", blockCount: 1, range: 0..<0x1000),
                .init(name: "NVRAM", key: "/N", blockCount: 1, range: 0x1000..<0x2000),
                .init(name: "PEGA_GPNV", key: "/PEGAGPNV", blockCount: 1, range: 0x2000..<0x2800),
                .init(name: "FV_MAIN_WRAPPER", key: "/P", blockCount: 3, range: 0x2800..<0x5000)
            ],
            region: [UInt8](repeating: 0x11, count: 0x1000)
                + [UInt8](repeating: 0x22, count: 0x1000)
                + [UInt8](repeating: 0xFF, count: 0x800)
                + [UInt8](repeating: 0x44, count: 0x2800)
        )
    }

    /// The update's region as a board's dump holds it: its own NVRAM and
    /// store, and — where asked — code that is not the vendor's.
    private func dump(changingCodeAt offsets: [Int] = []) -> [UInt8] {
        var bytes = update.region
        bytes.replaceSubrange(0x1000..<0x1010, with: [UInt8](repeating: 0x99, count: 0x10))
        bytes.replaceSubrange(0x2000..<0x2004, with: Array("GPNV".utf8))
        for offset in offsets { bytes[offset] ^= 0xFF }
        return bytes
    }

    private func compare(_ dump: [UInt8]) throws -> UEFIUpdateComparison {
        try UEFIUpdateComparison.compare(update, with: dump, at: base).get()
    }

    func testEachPartSaysWhetherItIsTheSameAndWhereItLiesInTheDump() throws {
        let comparison = try compare(dump(changingCodeAt: [0x3000]))
        XCTAssertEqual(comparison.platform, "RAPTORLAKE")
        XCTAssertEqual(comparison.region, base..<(base + 0x5000))
        XCTAssertEqual(comparison.rows.map(\.range), [
            base..<(base + 0x1000), (base + 0x1000)..<(base + 0x2000),
            (base + 0x2000)..<(base + 0x2800), (base + 0x2800)..<(base + 0x5000)
        ])
        XCTAssertEqual(comparison.rows.map(\.differingBytes), [0, 0x10, 4, 1])
        XCTAssertEqual(comparison.rows.map(\.isBoardData), [false, true, true, false])
        XCTAssertEqual(comparison.rows.map(\.isErasedInUpdate), [false, false, true, false])
    }

    func testOnlyCodeThatDiffersIsTickedAndBoardDataIsKept() throws {
        let comparison = try compare(dump(changingCodeAt: [0x3000]))
        XCTAssertEqual(comparison.rows.map(\.writesByDefault), [false, false, false, true])
    }

    func testTheStateColumnSaysWhatThePartIs() throws {
        let rows = try compare(dump(changingCodeAt: [0x3000])).rows
        XCTAssertEqual(rows.map(\.stateText), [
            "Identical", "Board data; 16 bytes differ", "Board data; empty in the update", "1 bytes differ"
        ])
        XCTAssertEqual(rows.map(\.nameText), ["FV_BB", "NVRAM", "PEGA_GPNV", "FV_MAIN_WRAPPER (3 blocks)"])
    }

    func testDifferencesCloseTogetherAreOneWriteAndFarApartAreTwo() throws {
        let rows = try compare(dump(changingCodeAt: [0x3000, 0x3008, 0x4000])).rows
        XCTAssertEqual(rows[3].differences, [(base + 0x3000)..<(base + 0x3009), (base + 0x4000)..<(base + 0x4001)])
        XCTAssertEqual(rows[3].differingBytes, 3)
    }

    func testTheTransactionWritesTheUpdatesBytesOnlyWhereTheDumpDiffers() throws {
        let comparison = try compare(dump(changingCodeAt: [0x3000, 0x3008]))
        let transaction = try XCTUnwrap(comparison.transaction(writing: [1, 3], from: update))
        XCTAssertEqual(transaction.name, "Write from Update File")
        XCTAssertEqual(transaction.writes, [
            .init(offset: base + 0x1000, bytes: [UInt8](repeating: 0x22, count: 0x10)),
            .init(offset: base + 0x3000, bytes: [UInt8](repeating: 0x44, count: 9))
        ])
        XCTAssertNoThrow(try transaction.validated())
    }

    func testWritingAPartThatIsTheSameWritesNothing() throws {
        let comparison = try compare(dump())
        XCTAssertNil(comparison.transaction(writing: [0, 3], from: update))
        XCTAssertNil(comparison.transaction(writing: [], from: update))
    }

    func testARegionOfAnotherSizeIsNotThisBoardsUpdate() {
        let result = UEFIUpdateComparison.compare(update, with: [UInt8](repeating: 0, count: 0x4000), at: base)
        XCTAssertEqual(result, .failure(.sizeMismatch(update: 0x5000, region: 0x4000)))
        if case .failure(let problem) = result {
            XCTAssertTrue(problem.message.contains("0x5000"))
            XCTAssertTrue(problem.message.contains("0x4000"))
        }
    }

    func testAFileThatIsNotAnUpdateIsSaidToBeNone() {
        let result = UEFIUpdateComparison.compare(file: [UInt8](repeating: 0xFF, count: 0x100),
                                                  with: dump(), at: base)
        guard case .failure(let problem) = result else { return XCTFail("compared a file that is not an update") }
        XCTAssertEqual(problem, .notAnUpdate)
        XCTAssertEqual(problem.message, "This is not an AMI BIOS Guard update file.")
    }

    func testBoardDataIsToldByTheFlashersSwitchOrByTheVendorsName() {
        for (name, key) in [("NVRAM", "/N"), ("NVRAM_BACKUP", "/NB"), ("OA_TABLE", "/OA"),
                            ("AsusNVRAM", "/AsusNVRAM"), ("PEGA_GPNV", "/PEGAGPNV"), ("SMBIOS", "")] {
            XCTAssertTrue(UEFIUpdateComparison.isBoardData(name: name, key: key), name)
        }
        for (name, key) in [("FV_MAIN_WRAPPER", "/P"), ("FV_BB", "/B"), ("PEGA_EC", "/PEGAEC"),
                            ("FV_DATA", "/DATA"), ("FV_NETWORK_WRAPPER", "/NETWORK")] {
            XCTAssertFalse(UEFIUpdateComparison.isBoardData(name: name, key: key), name)
        }
    }

    func testTheSummaryCountsThePartsAndTheBytes() throws {
        let comparison = try compare(dump(changingCodeAt: [0x3000]))
        XCTAssertEqual(comparison.summary(writing: [3]),
                       "1 of 4 parts identical. To write: 1 parts, 1 bytes. Kept as they are: 2.")
    }
}
