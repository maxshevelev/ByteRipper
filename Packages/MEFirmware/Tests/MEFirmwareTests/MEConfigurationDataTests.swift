import XCTest
@testable import MEFirmware

/// The binary configuration maps (`Design/MAP_DATA.md`): what the JSON
/// sources state, and what the reader refuses before it interprets a byte.
final class MEConfigurationDataTests: XCTestCase {
    func testTheResourceLoadsWithTheVersionTheCodeWasMarkedWith() {
        XCTAssertNil(MEConfigurationData.failure)
        let expected: [(String, Int, Int)] = [
            ("csme11", 43, 82), ("csme12", 25, 52),
            ("csme12Desktop", 31, 70), ("csme13", 31, 67),
            ("csme13Desktop", 27, 61), ("csme14", 31, 71),
            ("csme14Desktop", 27, 65), ("csme15", 38, 85),
            ("csme15Desktop", 35, 77), ("csme16", 40, 88),
            ("csme18", 32, 67),
        ]
        for (id, files, settings) in expected {
            let map = MEConfigurationData.map(id: id)
            XCTAssertEqual(map?.files.count, files, id)
            XCTAssertEqual(map?.files.flatMap(\.settings).count, settings, id)
        }
    }

    /// The parts a setting has beyond its place: the tool's label and help,
    /// its options, the bit range, `Auto`, `hex`, `text` and the two
    /// conditional marks.
    func testTheSettingsKeepTheirMarks() throws {
        let map = try XCTUnwrap(MEConfigurationData.map(id: "csme11"))
        let settings = map.files.flatMap(\.settings)
        let withBits = try XCTUnwrap(settings.first { $0.bits != nil })
        XCTAssertNotNil(withBits.length)
        let withOptions = try XCTUnwrap(settings.first { $0.options != nil })
        XCTAssertFalse(try XCTUnwrap(withOptions.options).isEmpty)
        XCTAssertNotNil(settings.first { $0.help != nil }?.label)
        let everyMap = ["csme11", "csme12", "csme12Desktop", "csme13",
                        "csme13Desktop", "csme14", "csme14Desktop", "csme15",
                        "csme15Desktop", "csme18"]
            .compactMap { MEConfigurationData.map(id: $0) }
            .flatMap { $0.files.flatMap(\.settings) }
        XCTAssertNotNil(everyMap.first { $0.condition != nil })
        XCTAssertNotNil(everyMap.first { $0.disabledBy != nil })

        let hex = try XCTUnwrap(MEConfigurationData.map(id: "csme18"))
            .files.flatMap(\.settings).first { $0.hex }
        XCTAssertNotNil(hex, "the 18 map's addresses are hex")
        let auto = try XCTUnwrap(MEConfigurationMap.csme16)
            .files.flatMap(\.settings).first { $0.auto }
        XCTAssertNotNil(auto, "MFIT marks the settings it works out")
    }

    func testAStaleVersionIsRefusedBeforeAnySectionIsRead() throws {
        var data = try XCTUnwrap(MEConfigurationData.bundledData)
        let wrong = MEConfigurationData.expectedVersion + 1
        data[8] = UInt8(truncatingIfNeeded: wrong)
        data[9] = UInt8(truncatingIfNeeded: wrong >> 8)
        data[10] = UInt8(truncatingIfNeeded: wrong >> 16)
        data[11] = UInt8(truncatingIfNeeded: wrong >> 24)
        XCTAssertThrowsError(try MEConfigurationData.decode(data)) { error in
            guard case .versionMismatch(let file, let code)? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(file, wrong)
            XCTAssertEqual(code, MEConfigurationData.expectedVersion)
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
        var data = try XCTUnwrap(MEConfigurationData.bundledData)
        data[4] = 2
        XCTAssertThrowsError(try MEConfigurationData.decode(data)) { error in
            XCTAssertEqual(error as? MapDataError, .unsupportedFormat(2))
        }
        var kind = try XCTUnwrap(MEConfigurationData.bundledData)
        kind[12] = 1
        XCTAssertThrowsError(try MEConfigurationData.decode(resigned(kind))) { error in
            XCTAssertEqual(error as? MapDataError, .wrongKind(1))
        }
    }

    func testAnEditedFileFailsItsChecksum() throws {
        var data = try XCTUnwrap(MEConfigurationData.bundledData)
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try MEConfigurationData.decode(data)) { error in
            guard case .corrupt? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
        }
    }
}
