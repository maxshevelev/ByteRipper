import XCTest
@testable import UEFIImage

/// HP's identity (`HPDMIArea`): the `HP_MUD` variable and the three beside it
/// in the main VSS2 store. The layout is read off the dumps it was surveyed
/// from, so the tests carry synthetic variables in it.
final class HPDMIAreaTests: XCTestCase {
    static let serial = "5CDTEST001"
    /// The UUID as SMBIOS stores it: 78563412-AB90-4788-89CD-EF0102030405.
    static let uuid: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0x88, 0x47, 0x89, 0xCD,
                                0xEF, 0x01, 0x02, 0x03, 0x04, 0x05]

    static func utf16(_ text: String, in bytes: inout [UInt8], at offset: Int) {
        for (index, unit) in text.utf16.enumerated() {
            bytes[offset + 2 * index] = UInt8(truncatingIfNeeded: unit)
            bytes[offset + 2 * index + 1] = UInt8(truncatingIfNeeded: unit >> 8)
        }
    }

    /// An `HP_MUD` value with every field written.
    static func mud(serial: String = serial) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: HPDMIArea.mudSize)
        utf16(serial, in: &bytes, at: 0x000)
        utf16("TEST123#ABD", in: &bytes, at: 0x042)
        utf16("103C_5336AN HP EliteBook", in: &bytes, at: 0x0A4)
        utf16("PTXTEST01JK100B", in: &bytes, at: 0x106)
        utf16("HP EliteBook 645 14 inch G11 Notebook PC", in: &bytes, at: 0x124)
        bytes.replaceSubrange(0x19E..<0x1AE, with: uuid)
        return bytes
    }

    static func text(_ text: String, size: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        utf16(text, in: &bytes, at: 0)
        return bytes
    }

    /// An HP variable as the firmware writes one: the authenticated header,
    /// attributes 07.
    static func variable(_ name: String, _ data: [UInt8], guid: EFIGUID = HPDMIArea.factoryGuid,
                         state: UInt8 = NVRAM.vssVariableAdded) -> [UInt8] {
        TestNVRAM.authVssVariable(name: name, data: data, vendorGuid: guid, state: state, attributes: 0x07)
    }

    /// `HP_MUD` and the variables beside it, the asset tag the serial.
    static func variables(mudState: UInt8 = NVRAM.vssVariableAdded, assetTag: String = serial) -> [[UInt8]] {
        [
            variable("Timeout", [5, 0], guid: HPDMIArea.settingsGuid),
            variable("BuildId", text("24WWTEST602#SABD#DABD", size: 112)),
            variable("FactoryConfig", text("476J6S6b7B7H.TR", size: 500)),
            variable(HPDMIArea.mudName, mud(), state: mudState),
            variable("HP_TAGS", text(assetTag, size: 324), guid: HPDMIArea.settingsGuid)
        ]
    }

    static func image(_ variables: [[UInt8]] = variables()) -> [UInt8] {
        TestNVRAM.nvramVolume(stores: [TestNVRAM.vss2Store(variables: variables)])
    }

    private func store(_ bytes: [UInt8]) throws -> UEFINode {
        try XCTUnwrap(UEFIParser.parse(bytes).allNodes.first { $0.kind == .vss2Store })
    }

    private func area(_ bytes: [UInt8]) throws -> HPDMIArea {
        try XCTUnwrap(HPDMIArea.read(store: store(bytes), reader: ImageReader(bytes)))
    }

    /// The store says who the machine is: what BCU reports as the serial, the
    /// SKU, the family, the CT number, the product name, the UUID, the build
    /// ID, the feature byte and the asset tracking number.
    func testTheStoreSaysWhoTheMachineIs() throws {
        let area = try area(Self.image())
        XCTAssertEqual(area.serialNumber, Self.serial)
        XCTAssertEqual(area.sku, "TEST123#ABD")
        XCTAssertEqual(area.productFamily, "103C_5336AN HP EliteBook")
        XCTAssertEqual(area.ctNumber, "PTXTEST01JK100B")
        XCTAssertEqual(area.productName, "HP EliteBook 645 14 inch G11 Notebook PC")
        XCTAssertEqual(area.uuidText, "78563412-AB90-4788-89CD-EF0102030405")
        XCTAssertEqual(area.buildID, "24WWTEST602#SABD#DABD")
        XCTAssertEqual(area.featureByte, "476J6S6b7B7H.TR")
        XCTAssertEqual(area.assetTag, Self.serial)
        XCTAssertFalse(area.isDeleted)
        XCTAssertEqual(area.findings, [])
    }

    /// The bench's "show the DMI area" goes to the `HP_MUD` entry — and only
    /// with the bytes, since a marked entry's name is in them.
    func testTheDMIStoresSeeTheEntry() throws {
        let bytes = Self.image()
        let parsed = UEFIParser.parse(bytes)
        let entry = try XCTUnwrap(parsed.allNodes.first { $0.kind == .vssEntry && $0.name == HPDMIArea.mudName })
        XCTAssertEqual(DMIStore.all(in: parsed.roots, reader: ImageReader(bytes)),
                       [DMIStore(kind: .vssEntry, range: entry.range)])
        XCTAssertEqual(DMIStore.all(in: parsed.roots), [])
        let store = try store(bytes)
        XCTAssertTrue(HPDMIArea.isAreaEntry(entry, in: store, reader: ImageReader(bytes)))
        let tags = try XCTUnwrap(parsed.allNodes.first { $0.kind == .vssEntry && $0.name == "HP_TAGS" })
        XCTAssertFalse(HPDMIArea.isAreaEntry(tags, in: store, reader: ImageReader(bytes)))
    }

    /// The tree finds the entry without the panel opening the way to it.
    @MainActor
    func testTheTreeFindsTheEntry() async throws {
        let bytes = Self.image()
        let tree = LazyUEFITree(bytes)
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await withCheckedContinuation { continuation in tree.resolveDMIStores { continuation.resume() } }
        let area = try area(bytes)
        XCTAssertEqual(tree.dmiStores, [DMIStore(kind: .vssEntry, range: area.entry)])
    }

    /// On most boards read from the store marks `HP_MUD` deleted and keeps no
    /// current copy; the copy is whole, is read, and says so.
    func testADeletedCopyIsReadAndSaysSo() throws {
        let area = try area(Self.image(Self.variables(mudState: 0x3C)))
        XCTAssertEqual(area.serialNumber, Self.serial)
        XCTAssertTrue(area.isDeleted)
        XCTAssertEqual(area.findings, [.deletedCopy])
    }

    /// Where the store keeps a current copy, it wins over an earlier one.
    func testTheCurrentCopyWinsOverAnEarlierOne() throws {
        let earlier = Self.variable(HPDMIArea.mudName, Self.mud(serial: "5CDOLD0001"), state: 0x3C)
        let bytes = Self.image([earlier] + Self.variables())
        let area = try area(bytes)
        XCTAssertEqual(area.serialNumber, Self.serial)
        XCTAssertFalse(area.isDeleted)
        let parsed = UEFIParser.parse(bytes)
        let old = try XCTUnwrap(parsed.allNodes.first { $0.kind == .vssEntry && $0.name == "Invalid" })
        XCTAssertFalse(HPDMIArea.isAreaEntry(old, in: try store(bytes), reader: ImageReader(bytes)))
    }

    /// The asset tag is the serial by default; another value is worth knowing.
    func testAnAssetTagOtherThanTheSerialIsANote() throws {
        let area = try area(Self.image(Self.variables(assetTag: "5CGOTHER01")))
        XCTAssertEqual(area.findings, [.assetTagIsNotTheSerial])
    }

    /// Only the layout read from: another size, another GUID, or a serial that
    /// is no text is not read.
    func testWhatIsNotTheLayoutIsNotRead() throws {
        let short = Self.variable(HPDMIArea.mudName, Array(Self.mud().prefix(0x100)))
        XCTAssertNil(HPDMIArea.read(store: try store(Self.image([short])), reader: ImageReader(Self.image([short]))))
        let foreign = Self.variable(HPDMIArea.mudName, Self.mud(), guid: HPDMIArea.settingsGuid)
        XCTAssertNil(HPDMIArea.read(store: try store(Self.image([foreign])), reader: ImageReader(Self.image([foreign]))))
        var garbled = Self.mud()
        garbled[2] = 0x01
        garbled[3] = 0xD8
        let broken = Self.variable(HPDMIArea.mudName, garbled)
        XCTAssertNil(HPDMIArea.read(store: try store(Self.image([broken])), reader: ImageReader(Self.image([broken]))))
    }
}
