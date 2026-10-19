import XCTest
@testable import UEFIImage

/// Apple's identity (`AppleDMIArea`): the `ssn`, `hwc` and `son` variables of
/// the SysF store, and the board's serial in the names of the calibration
/// variables beside them. The layout is read off the dumps it was surveyed
/// from, so the tests carry synthetic variables in it.
final class AppleDMIAreaTests: XCTestCase {
    static let serial = "C02TEST00G94"
    static let board = "C02542600KXG91TAN"

    static func variable(_ name: String, _ text: String, invalid: Bool = false) -> [UInt8] {
        TestNVRAM.sysfVariable(name: name, data: Array(text.utf8), invalid: invalid)
    }

    /// The variables of a Mac that keeps its identity: two calibration
    /// variables named by the board's serial, then the three of the identity.
    static func variables(serial: String = serial, code: String = "0G94") -> [[UInt8]] {
        [
            TestNVRAM.sysfVariable(name: board + "TCFMAC-1", data: [1, 2, 3, 4]),
            TestNVRAM.sysfVariable(name: board + "MAC-1", data: [5, 6, 7, 8]),
            variable("ssn", serial),
            variable("hwc", code),
            variable("son", "MJVE2D/")
        ]
    }

    static func image(_ variables: [[UInt8]] = variables()) -> [UInt8] {
        TestNVRAM.nvramVolume(stores: [TestNVRAM.sysfStore(variables: variables)])
    }

    private func store(_ bytes: [UInt8]) throws -> UEFINode {
        try XCTUnwrap(UEFIParser.parse(bytes).allNodes.first { $0.kind == .sysFStore })
    }

    private func area(_ bytes: [UInt8]) throws -> AppleDMIArea {
        try XCTUnwrap(AppleDMIArea.read(store: store(bytes), reader: ImageReader(bytes)))
    }

    /// The store says whose the Mac is: the serial, the configuration code,
    /// the order number and the board's serial.
    func testTheStoreSaysWhoseTheMacIs() throws {
        let area = try area(Self.image(Self.variables(serial: "C02TEST00G94", code: "0G94")))
        XCTAssertEqual(area.serialNumber, "C02TEST00G94")
        XCTAssertEqual(area.configCode, "0G94")
        XCTAssertEqual(area.orderNumber, "MJVE2D/")
        XCTAssertEqual(area.boardSerial, Self.board)
        XCTAssertFalse(area.isDeleted)
        XCTAssertEqual(area.findings, [])
    }

    /// The bench's "show the DMI area" goes to the store, and only with the
    /// bytes: a SysF store is told for Apple's identity by what it holds.
    func testTheDMIStoresSeeTheStore() throws {
        let bytes = Self.image()
        let parsed = UEFIParser.parse(bytes)
        let store = try XCTUnwrap(parsed.allNodes.first { $0.kind == .sysFStore })
        XCTAssertEqual(DMIStore.all(in: parsed.roots, reader: ImageReader(bytes)),
                       [DMIStore(kind: .sysFStore, range: store.range)])
        XCTAssertEqual(DMIStore.all(in: parsed.roots), [])
    }

    /// A store of the overrides only — the 2010 and 2011 boards — holds no
    /// identity, and is no DMI area.
    func testAStoreWithoutTheIdentityIsNoArea() throws {
        let bytes = Self.image([TestNVRAM.sysfVariable(name: "overrides", data: [0x42, 0x5A, 0x68])])
        XCTAssertNil(AppleDMIArea.read(store: try store(bytes), reader: ImageReader(bytes)))
        XCTAssertEqual(DMIStore.all(in: UEFIParser.parse(bytes).roots, reader: ImageReader(bytes)), [])
    }

    /// The Diag store shares the format but is not the identity.
    func testTheDiagStoreIsNotRead() throws {
        let bytes = TestNVRAM.nvramVolume(stores: [
            TestNVRAM.sysfStore(variables: Self.variables(), signature: NVRAM.appleDiagSignature)
        ])
        let store = try store(bytes)
        XCTAssertNil(AppleDMIArea.read(store: store, reader: ImageReader(bytes)))
    }

    /// A placeholder serial does not end in the configuration code, nor begin
    /// as the board's serial does.
    func testAPlaceholderSerialIsNoted() throws {
        let area = try area(Self.image(Self.variables(serial: "123456789012", code: "HV2H")))
        XCTAssertEqual(area.findings, [.configCodeIsNotTheSerialsEnd, .serialIsNotTheBoardsLocation])
    }

    /// A copy marked invalid is read, and says so; a current one wins over it.
    func testAnInvalidCopyIsReadAndSaysSo() throws {
        var variables = Self.variables()
        variables[2] = Self.variable("ssn", Self.serial, invalid: true)
        let marked = try area(Self.image(variables))
        XCTAssertEqual(marked.serialNumber, Self.serial)
        XCTAssertEqual(marked.findings, [.deletedCopy])
        variables.append(Self.variable("ssn", "C02NEW00G940"))
        XCTAssertEqual(try area(Self.image(variables)).serialNumber, "C02NEW00G940")
    }

    /// The 2010 boards: an 11-character serial with a three-character code,
    /// and no calibration variables, so no board's serial.
    func testAnOlderMacHasAThreeCharacterCodeAndNoBoardSerial() throws {
        let area = try area(Self.image([
            Self.variable("overrides", "BZh"),
            Self.variable("ssn", "W8037597AGU"),
            Self.variable("hwc", "AGU"),
            Self.variable("son", "MC371D/A")
        ]))
        XCTAssertEqual(area.serialNumber, "W8037597AGU")
        XCTAssertEqual(area.configCode, "AGU")
        XCTAssertNil(area.boardSerial)
        XCTAssertEqual(area.findings, [])
    }

    /// The board's serial needs two variables that share it: a single long
    /// name is no proof.
    func testTheBoardSerialNeedsTwoNames() throws {
        let one = Self.image([TestNVRAM.sysfVariable(name: Self.board + "MAC-1", data: [1, 2, 3, 4]),
                              Self.variable("ssn", Self.serial)])
        XCTAssertNil(try area(one).boardSerial)
    }
}
