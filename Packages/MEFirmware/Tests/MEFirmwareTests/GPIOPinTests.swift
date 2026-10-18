import XCTest
@testable import MEFirmware

/// The GPIO feature pin map and the reader of `/home/gpio/csme_pins`.
///
/// The map is emitted from Flash Image Tool's own value classes
/// (`gpio_map.py`), so it is not pinned here name by name; what is worth
/// pinning is the shape of each generation's record and the refusal to read a
/// file that is not one — the two things a wrong guess would silently turn
/// into pins. Both shapes are settled on the images at hand: CSME 11's
/// records match FIT 11's defaults (`NFC_RST` = GPP_E_4, `FWUPDATE` = GPP_B_15)
/// and CSME 12's the field set of its `GpioCsmeFeature` class.
final class GPIOPinTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    func testTheMapsCarryTheToolsValues() throws {
        let eleven = try XCTUnwrap(GPIOPinMap.forME(major: 11))
        XCTAssertTrue(eleven.features.isEmpty, "CSME 11's file carries no feature id")
        XCTAssertEqual(eleven.usages[0], "NFC_RST")
        XCTAssertEqual(eleven.usages[8], "FWUPDATE")
        XCTAssertEqual(eleven.ownerships[1], "CSME_MODE")
        XCTAssertEqual(eleven.padModes[4], "DEFAULT_MODE")
        XCTAssertEqual(eleven.groups[4], "GPP_E")
        XCTAssertEqual(eleven.groups[0xFF], "NONE")

        let twelve = try XCTUnwrap(GPIOPinMap.forME(major: 12))
        XCTAssertEqual(twelve.features[1], "GPIO_TOUCH_FEATURE_ID")
        XCTAssertEqual(twelve.features[3], "GPIO_SMT_FEATURE_ID")
        XCTAssertEqual(twelve.usages[5], "CPU_DETECTION")
        XCTAssertEqual(twelve.usages[12], "SMT_SMLINK1_CLK")
        XCTAssertNotNil(GPIOPinMap.forME(major: 15))
        // MFIT's generations carry no `GpioCsme*` classes, so there is no map.
        XCTAssertNil(GPIOPinMap.forME(major: 16))
        XCTAssertNil(GPIOPinMap.forME(major: 18))
    }

    /// CSME 11 writes five dwords per record, and the values are the ones FIT
    /// 11 itself gives the same usages in its documents.
    func testAnElevenRecordIsFiveDwords() throws {
        let map = try XCTUnwrap(GPIOPinMap.forME(major: 11))
        let bytes = Data(
            u32(0) + u32(4) + u32(4) + u32(0) + u32(4)      // NFC_RST at GPP_E_4
            + u32(8) + u32(1) + u32(15) + u32(1) + u32(0))  // FWUPDATE at GPP_B_15
        let pins = try XCTUnwrap(GPIOPinReader.pins(in: bytes, map: map, major: 11))
        XCTAssertEqual(pins.count, 2)
        XCTAssertEqual(pins[0].usage, "NFC_RST")
        XCTAssertEqual(pins[0].pinName, "GPP_E_4")
        XCTAssertEqual(pins[0].ownership, "HOST_MODE")
        XCTAssertEqual(pins[0].padMode, "DEFAULT_MODE")
        XCTAssertNil(pins[0].feature)
        XCTAssertEqual(pins[1].usage, "FWUPDATE")
        XCTAssertEqual(pins[1].pinName, "GPP_B_15")
        XCTAssertEqual(pins[1].ownershipID, 1)
        XCTAssertEqual(pins[1].padModeID, 0)
    }

    /// CSME 12 and later write packed bytes: feature id, group, pad, reserved,
    /// usage, reserved, ownership, pad mode, then four reserved bytes.
    func testATwelveRecordIsPackedBytes() throws {
        let map = try XCTUnwrap(GPIOPinMap.forME(major: 12))
        let touch: [UInt8] = [1, 1, 14, 0, 0, 0, 0, 4, 0, 0, 0, 0]
        let smt: [UInt8] = [3, 2, 6, 0, 12, 0, 1, 1, 0, 0, 0, 0]
        let pins = try XCTUnwrap(GPIOPinReader.pins(in: Data(touch + smt),
                                                    map: map, major: 12))
        XCTAssertEqual(pins.count, 2)
        XCTAssertEqual(pins[0].feature, "GPIO_TOUCH_FEATURE_ID")
        XCTAssertEqual(pins[0].usage, "INTEGRATED_TOUCH_1")
        XCTAssertEqual(pins[0].pinName, "GPP_B_14")
        XCTAssertEqual(pins[0].ownership, "HOST_MODE")
        XCTAssertEqual(pins[0].padMode, "DEFAULT_MODE")
        XCTAssertEqual(pins[1].feature, "GPIO_SMT_FEATURE_ID")
        XCTAssertEqual(pins[1].usage, "SMT_SMLINK1_CLK")
        XCTAssertEqual(pins[1].pinName, "GPP_C_6")
        XCTAssertEqual(pins[1].ownership, "CSME_MODE")
        XCTAssertEqual(pins[1].padMode, "NATIVE_FUNCTION_1")
    }

    /// A number the tool has no name for is shown as the number, not guessed
    /// at, and an ambiguous group keeps its number.
    func testANumberWithoutANameIsShownAsTheNumber() throws {
        let map = try XCTUnwrap(GPIOPinMap.forME(major: 12))
        let bytes = Data([1, 9, 4, 0, 200, 0, 0, 0, 0, 0, 0, 0])
        let pins = try XCTUnwrap(GPIOPinReader.pins(in: bytes, map: map, major: 12))
        XCTAssertNil(pins[0].usage)
        XCTAssertEqual(pins[0].usageID, 200)
        // The documents disagree about 9 (GPP_J in one family, GPD in the
        // other), so the map carries no name and the pin keeps its number.
        XCTAssertNil(pins[0].group)
        XCTAssertEqual(pins[0].pinName, "9:4")
    }

    /// An empty file is what a platform with no feature pins carries; a length
    /// that is not whole records is not one of these files; and a record whose
    /// owner or pad mode cannot be true of any pin is not read at all rather
    /// than named.
    func testAFileThatIsNotAPinFileIsNotRead() throws {
        let eleven = try XCTUnwrap(GPIOPinMap.forME(major: 11))
        let twelve = try XCTUnwrap(GPIOPinMap.forME(major: 12))
        XCTAssertNil(GPIOPinReader.pins(in: Data(), map: eleven, major: 11))
        XCTAssertNil(GPIOPinReader.pins(in: Data(repeating: 0, count: 19),
                                        map: eleven, major: 11))
        XCTAssertNil(GPIOPinReader.pins(in: Data(repeating: 0, count: 13),
                                        map: twelve, major: 12))

        var ownerOutOfRange = Data(repeating: 0, count: 12)
        ownerOutOfRange[4] = 0
        ownerOutOfRange[6] = 9
        XCTAssertNil(GPIOPinReader.pins(in: ownerOutOfRange, map: twelve, major: 12))

        var padModeOutOfRange = Data(repeating: 0, count: 12)
        padModeOutOfRange[7] = 9
        XCTAssertNil(GPIOPinReader.pins(in: padModeOutOfRange, map: twelve, major: 12))
    }
}
