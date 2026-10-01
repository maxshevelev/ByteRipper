import XCTest
@testable import UEFIImage

/// How full a store is, and what its entries still count for
/// (`UEFI_IMAGE_FORMAT.md` §9).
final class NvramStoreFillTests: XCTestCase {
    /// A state no valid variable has: what a replaced or deleted one carries.
    private static let marked: UInt8 = 0x3C

    private func fill(_ volume: [UInt8]) -> NvramStoreFill? {
        let parsed = UEFIParser.parse(volume)
        return NvramStoreFill.of(parsed.roots[0].children[0], reader: ImageReader(volume))
    }

    /// A marked entry whose variable has a current entry was replaced; one
    /// whose variable is gone was deleted. The tree calls both `Invalid`, so
    /// the name is read from the bytes.
    func testAMarkedVSSEntryIsSupersededOrDeletedByWhetherItsVariableRemains() {
        let store = TestNVRAM.vssStore(variables: [
            TestNVRAM.vssVariable(name: "Setup", state: Self.marked),
            TestNVRAM.vssVariable(name: "Gone", state: Self.marked),
            TestNVRAM.vssVariable(name: "Setup"),
            TestNVRAM.vssVariable(name: "BootOrder"),
        ], freeSpace: 0x40)
        let result = fill(TestNVRAM.nvramVolume(stores: [store]))

        XCTAssertEqual(result?.current, 2)
        XCTAssertEqual(result?.superseded, 1)
        XCTAssertEqual(result?.deleted, 1)
    }

    /// The same name under another vendor GUID is another variable.
    func testTheVendorGUIDIsPartOfTheVariable() {
        let other = KnownGUIDs.guid("8BE4DF61-93CA-11D2-AA0D-00E098032B8C")
        let store = TestNVRAM.vssStore(variables: [
            TestNVRAM.vssVariable(name: "Setup", vendorGuid: other, state: Self.marked),
            TestNVRAM.vssVariable(name: "Setup"),
        ])
        XCTAssertEqual(fill(TestNVRAM.nvramVolume(stores: [store]))?.deleted, 1)
    }

    func testUsedAndFreeAreTheBodyAndItsErasedRest() {
        let variables = [TestNVRAM.vssVariable(name: "Setup")]
        let store = TestNVRAM.vssStore(variables: variables, freeSpace: 0x100)
        let result = fill(TestNVRAM.nvramVolume(stores: [store]))!
        let written = UInt64(variables[0].count)

        XCTAssertEqual(result.size, written + 0x100)
        XCTAssertEqual(result.free, 0x100)
        XCTAssertEqual(result.used, written)
        XCTAssertEqual(result.percentUsed, Int(written * 100 / (written + 0x100)))
    }

    /// A store with room left never reads as full.
    func testThePercentageRoundsDown() {
        let fill = NvramStoreFill(size: 1000, free: 1, current: 0, superseded: 0, deleted: 0)
        XCTAssertEqual(fill.percentUsed, 99)
    }

    /// A VSS2 variable keeps its name in its header, after the standard or the
    /// authenticated fields.
    func testAVSS2EntryIsMatchedByTheNameInItsHeader() {
        let store = TestNVRAM.vss2Store(variables: [
            TestNVRAM.vss2Variable(name: "Lang", state: Self.marked),
            TestNVRAM.authVssVariable(name: "PK", state: Self.marked),
            TestNVRAM.vss2Variable(name: "Lang"),
            TestNVRAM.authVssVariable(name: "PK"),
            TestNVRAM.vss2Variable(name: "Gone", state: Self.marked),
        ])
        let result = fill(TestNVRAM.nvramVolume(stores: [store]))

        XCTAssertEqual(result?.current, 2)
        XCTAssertEqual(result?.superseded, 2)
        XCTAssertEqual(result?.deleted, 1)
    }

    /// The earlier links of an NVAR chain are superseded; the data entry at
    /// its end is current.
    func testAnNVARChainsEarlierLinksAreSuperseded() {
        // `next` is the distance to the next link, which is the entry's own
        // length here; it changes no size, so the length is known up front.
        let head = TestNVAR.entry(next: UInt32(TestNVAR.entry(data: [0x01]).count), data: [0x01])
        let middle = TestNVAR.dataEntry(next: UInt32(TestNVAR.dataEntry(data: [0x02]).count), data: [0x02])
        let store = TestNVAR.store([
            head,
            middle,
            TestNVAR.dataEntry(data: [0x03]),
            TestNVAR.entry(name: "Lang"),
            TestNVAR.entry(attributes: NVAR.localGuid | NVAR.asciiName, name: "Gone"),
        ])
        let bytes = TestNVAR.volume(body: store)
        let file = UEFIParser.parse(bytes).roots[0].children[0]
        let result = NvramStoreFill.of(file, reader: ImageReader(bytes))

        XCTAssertEqual(result?.current, 2)
        XCTAssertEqual(result?.superseded, 2)
        XCTAssertEqual(result?.deleted, 1)
    }

    func testANodeWithoutEntriesHasNoFill() {
        let bytes = TestNVRAM.nvramVolume(stores: [TestNVRAM.vssStore()])
        XCTAssertNil(NvramStoreFill.of(UEFIParser.parse(bytes).roots[0], reader: ImageReader(bytes)))
    }
}
