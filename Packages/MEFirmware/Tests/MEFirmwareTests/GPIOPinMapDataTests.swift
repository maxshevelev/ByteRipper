import XCTest
@testable import MEFirmware

/// The binary GPIO pin dictionaries (`Design/MAP_DATA.md`): what the JSON
/// sources state, and what the reader refuses before it interprets a byte.
final class GPIOPinMapDataTests: XCTestCase {
    func testTheResourceLoadsWithTheVersionTheCodeWasMarkedWith() {
        XCTAssertNil(GPIOPinMapData.failure)
        let expected: [(String, Int, Int, Int, Int, Int)] = [
            ("csme11", 0, 14, 4, 5, 11),
            ("csme12", 5, 18, 4, 5, 12),
            ("csme13", 5, 18, 4, 5, 12),
            ("csme14", 5, 18, 4, 5, 12),
            ("csme15", 6, 44, 4, 5, 12),
        ]
        for (id, features, usages, ownerships, padModes, groups) in expected {
            let map = GPIOPinMapData.map(id: id)
            XCTAssertEqual(map?.features.count, features, id)
            XCTAssertEqual(map?.usages.count, usages, id)
            XCTAssertEqual(map?.ownerships.count, ownerships, id)
            XCTAssertEqual(map?.padModes.count, padModes, id)
            XCTAssertEqual(map?.groups.count, groups, id)
        }
    }

    /// The words the maps are asked for, and the numbers the tool's documents
    /// disagree about — kept absent rather than guessed at.
    func testTheDictionariesKeepTheToolsWords() throws {
        let eleven = try XCTUnwrap(GPIOPinMapData.map(id: "csme11"))
        XCTAssertEqual(eleven.usages[0], "NFC_RST")
        XCTAssertEqual(eleven.usages[8], "FWUPDATE")
        XCTAssertEqual(eleven.ownerships[1], "CSME_MODE")
        XCTAssertEqual(eleven.padModes[4], "DEFAULT_MODE")
        XCTAssertEqual(eleven.groups[4], "GPP_E")
        XCTAssertEqual(eleven.groups[0xFF], "NONE")

        let twelve = try XCTUnwrap(GPIOPinMapData.map(id: "csme12"))
        XCTAssertEqual(twelve.features[1], "GPIO_TOUCH_FEATURE_ID")
        XCTAssertEqual(twelve.usages[5], "CPU_DETECTION")
        XCTAssertEqual(twelve.usages[12], "SMT_SMLINK1_CLK")
        XCTAssertNil(twelve.groups[9], "GPP_J and GPD both take 9")
    }

    func testAStaleVersionIsRefusedBeforeAnySectionIsRead() throws {
        var data = try XCTUnwrap(GPIOPinMapData.bundledData)
        let wrong = GPIOPinMapData.expectedVersion + 1
        data[8] = UInt8(truncatingIfNeeded: wrong)
        data[9] = UInt8(truncatingIfNeeded: wrong >> 8)
        data[10] = UInt8(truncatingIfNeeded: wrong >> 16)
        data[11] = UInt8(truncatingIfNeeded: wrong >> 24)
        XCTAssertThrowsError(try GPIOPinMapData.decode(data)) { error in
            guard case .versionMismatch(let file, let code)? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(file, wrong)
            XCTAssertEqual(code, GPIOPinMapData.expectedVersion)
        }
    }

    /// FNV-1a with the checksum field zeroed, as the compiler writes it: a
    /// test that edits a header field must re-sign the copy.
    private func resigned(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        bytes[20] = 0
        bytes[21] = 0
        bytes[22] = 0
        bytes[23] = 0
        var value: UInt32 = 2_166_136_261
        for byte in bytes {
            value ^= UInt32(byte)
            value = value &* 16_777_619
        }
        bytes[20] = UInt8(truncatingIfNeeded: value)
        bytes[21] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[22] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[23] = UInt8(truncatingIfNeeded: value >> 24)
        return Data(bytes)
    }

    func testAnotherFormatAndKindAreRefused() throws {
        var data = try XCTUnwrap(GPIOPinMapData.bundledData)
        data[4] = 2
        XCTAssertThrowsError(try GPIOPinMapData.decode(data)) { error in
            XCTAssertEqual(error as? MapDataError, .unsupportedFormat(2))
        }
        var kind = try XCTUnwrap(GPIOPinMapData.bundledData)
        kind[12] = 1
        XCTAssertThrowsError(try GPIOPinMapData.decode(resigned(kind))) { error in
            XCTAssertEqual(error as? MapDataError, .wrongKind(1))
        }
    }

    func testAnEditedFileFailsItsChecksum() throws {
        var data = try XCTUnwrap(GPIOPinMapData.bundledData)
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try GPIOPinMapData.decode(data)) { error in
            guard case .corrupt? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
        }
    }
}
