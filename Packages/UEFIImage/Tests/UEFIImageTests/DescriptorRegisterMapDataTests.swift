import XCTest
@testable import UEFIImage

/// The binary register maps (`Design/MAP_DATA.md`): what the JSON sources
/// state, and what the reader refuses before it interprets a byte.
final class DescriptorRegisterMapDataTests: XCTestCase {
    func testTheResourceLoadsWithTheVersionTheCodeWasMarkedWith() {
        XCTAssertNil(DescriptorRegisterMapData.failure)
        let expected: [(String, Int, Int)] = [
            ("sunrisePoint", 2, 9), ("cannonPoint", 4, 34),
            ("tigerPoint", 6, 42), ("elkhartLake", 6, 42),
            ("jasperLake", 4, 35), ("csme18", 8, 74),
        ]
        for (id, registers, fields) in expected {
            let map = DescriptorRegisterMapData.map(id: id)
            XCTAssertEqual(map?.registers.count, registers, id)
            XCTAssertEqual(map?.registers.flatMap(\.fields).count, fields, id)
        }
    }

    /// A register's place is the tool's: absolute in the descriptor, at the
    /// flash component base or at the flash master base.
    func testTheRegistersKeepTheirPlaces() throws {
        let eighteen = try XCTUnwrap(DescriptorRegisterMapData.map(id: "csme18"))
        let flmap0 = try XCTUnwrap(eighteen.registers.first { $0.name == "FLMAP0" })
        XCTAssertEqual(flmap0.place, .absolute(0x14))
        let flstr = try XCTUnwrap(eighteen.registers.first { $0.name == "FLMSTR" })
        XCTAssertEqual(flstr.place, .flashMaster(offset: 0))
        XCTAssertEqual(flstr.words, 6)
        let flcomp = try XCTUnwrap(eighteen.registers.first { $0.name == "FLCOMP" })
        XCTAssertEqual(flcomp.place, .flashComponent(offset: 0))

        let tiger = try XCTUnwrap(DescriptorRegisterMapData.map(id: "tigerPoint"))
        let flmap2 = try XCTUnwrap(tiger.registers.first { $0.name == "FLMAP2" })
        XCTAssertEqual(flmap2.place, .absolute(0x1C))
    }

    /// Labels and option words are the tool's and survive as text.
    func testTheFieldsKeepTheirLabelsAndOptions() throws {
        let map = try XCTUnwrap(DescriptorRegisterMapData.map(id: "cannonPoint"))
        let field = try XCTUnwrap(map.registers.flatMap(\.fields)
            .first { $0.options != nil })
        XCTAssertNotNil(field.label)
        XCTAssertFalse(try XCTUnwrap(field.options).isEmpty)

        let eighteen = try XCTUnwrap(DescriptorRegisterMapData.map(id: "csme18"))
        let component = try XCTUnwrap(eighteen.registers.flatMap(\.fields)
            .first { $0.name == "FLMAP0_Flash_Component_Base_Address" })
        XCTAssertEqual(component.bitOffset, 0)
        XCTAssertEqual(component.count, 8)
    }

    func testAStaleVersionIsRefusedBeforeAnySectionIsRead() throws {
        var data = try XCTUnwrap(DescriptorRegisterMapData.bundledData)
        let wrong = DescriptorRegisterMapData.expectedVersion + 1
        data[8] = UInt8(truncatingIfNeeded: wrong)
        data[9] = UInt8(truncatingIfNeeded: wrong >> 8)
        data[10] = UInt8(truncatingIfNeeded: wrong >> 16)
        data[11] = UInt8(truncatingIfNeeded: wrong >> 24)
        XCTAssertThrowsError(try DescriptorRegisterMapData.decode(data)) { error in
            guard case .versionMismatch(let file, let code)? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(file, wrong)
            XCTAssertEqual(code, DescriptorRegisterMapData.expectedVersion)
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
        var data = try XCTUnwrap(DescriptorRegisterMapData.bundledData)
        data[4] = 2
        XCTAssertThrowsError(try DescriptorRegisterMapData.decode(data)) { error in
            XCTAssertEqual(error as? MapDataError, .unsupportedFormat(2))
        }
        var kind = try XCTUnwrap(DescriptorRegisterMapData.bundledData)
        kind[12] = 1
        XCTAssertThrowsError(try DescriptorRegisterMapData.decode(resigned(kind))) { error in
            XCTAssertEqual(error as? MapDataError, .wrongKind(1))
        }
    }

    func testAnEditedFileFailsItsChecksum() throws {
        var data = try XCTUnwrap(DescriptorRegisterMapData.bundledData)
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try DescriptorRegisterMapData.decode(data)) { error in
            guard case .corrupt? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
        }
    }
}
