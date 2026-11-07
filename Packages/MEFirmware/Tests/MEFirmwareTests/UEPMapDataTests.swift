import XCTest
@testable import MEFirmware

/// The binary UEP layouts (`Design/MAP_DATA.md`): what the JSON sources state,
/// and what the reader refuses before it interprets a byte.
final class UEPMapDataTests: XCTestCase {
    func testTheResourceLoadsWithTheVersionTheCodeWasMarkedWith() {
        XCTAssertNil(UEPMapData.failure)
        let expected: [(String, Int, Int, Int)] = [
            ("csme12", 42, 8, 0x80), ("csme13", 43, 8, 0x80),
            ("csme14", 44, 8, 0x80), ("csme15", 56, 0x0C, 0),
            ("csme16", 76, 0x0C, 0), ("csme18", 41, 8, 0x80),
        ]
        for (id, settings, arrayStart, arraySize) in expected {
            let map = UEPMapData.map(id: id)
            XCTAssertEqual(map?.settings.count, settings, id)
            XCTAssertEqual(map?.arrayStart, arrayStart, id)
            XCTAssertEqual(map?.arraySize, arraySize, id)
        }
    }

    /// The parts a setting has beyond its place: the tool's label, section,
    /// help and option words, and its array when it is not the first.
    func testTheSettingsKeepTheirWordsAndPlaces() throws {
        let twelve = try XCTUnwrap(UEPMapData.map(id: "csme12"))
        let vendor = try XCTUnwrap(twelve.settings.first { $0.name == "OemVendorId" })
        XCTAssertEqual(vendor.label, "OEM Vendor ID")
        XCTAssertEqual(vendor.section, "OEMandPlatformIDs")
        XCTAssertEqual(vendor.placement,
                       .init(array: 0, offset: 0x3C, bit: 0, count: 16))
        let bsmm = try XCTUnwrap(twelve.settings.first { $0.name == "sb_bsmm_svn" })
        XCTAssertEqual(bsmm.placement,
                       .init(array: 1, offset: 0x40, bit: 30, count: 15))

        let eighteen = try XCTUnwrap(UEPMapData.map(id: "csme18"))
        let profile = try XCTUnwrap(eighteen.settings.first { $0.name == "BTG_PROFILE" })
        XCTAssertEqual(profile.label, "Boot Guard Profile")
        XCTAssertEqual(profile.options, [0: "Boot Guard Disabled", 3: "Debug Profile",
                                         4: "Verified Boot", 5: "Verified and Measured Boot"])
        XCTAssertNotNil(eighteen.settings.first { $0.help != nil })

        let sixteen = try XCTUnwrap(UEPMapData.map(id: "csme16"))
        let rpMc = try XCTUnwrap(sixteen.settings.first { $0.name == "RpmcSupported" })
        XCTAssertEqual(rpMc.label, "RPMC Supported")
        XCTAssertEqual(rpMc.section, "RpmcConfiguration")
        XCTAssertEqual(rpMc.placement,
                       .init(array: 0, offset: 0x74, bit: 4, count: 1))
    }

    func testAStaleVersionIsRefusedBeforeAnySectionIsRead() throws {
        var data = try XCTUnwrap(UEPMapData.bundledData)
        let wrong = UEPMapData.expectedVersion + 1
        data[8] = UInt8(truncatingIfNeeded: wrong)
        data[9] = UInt8(truncatingIfNeeded: wrong >> 8)
        data[10] = UInt8(truncatingIfNeeded: wrong >> 16)
        data[11] = UInt8(truncatingIfNeeded: wrong >> 24)
        XCTAssertThrowsError(try UEPMapData.decode(data)) { error in
            guard case .versionMismatch(let file, let code)? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(file, wrong)
            XCTAssertEqual(code, UEPMapData.expectedVersion)
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
        var data = try XCTUnwrap(UEPMapData.bundledData)
        data[4] = 2
        XCTAssertThrowsError(try UEPMapData.decode(data)) { error in
            XCTAssertEqual(error as? MapDataError, .unsupportedFormat(2))
        }
        var kind = try XCTUnwrap(UEPMapData.bundledData)
        kind[12] = 2
        XCTAssertThrowsError(try UEPMapData.decode(resigned(kind))) { error in
            XCTAssertEqual(error as? MapDataError, .wrongKind(2))
        }
    }

    func testAnEditedFileFailsItsChecksum() throws {
        var data = try XCTUnwrap(UEPMapData.bundledData)
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try UEPMapData.decode(data)) { error in
            guard case .corrupt? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
        }
    }
}
