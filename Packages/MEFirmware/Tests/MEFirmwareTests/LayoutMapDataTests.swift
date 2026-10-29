import XCTest
@testable import MEFirmware

/// The binary CSME 18 layouts (`Design/MAP_DATA.md`): the MIP containers,
/// the CPU strap message and the SPHY nvar, and what the reader refuses.
final class LayoutMapDataTests: XCTestCase {
    func testTheResourceLoadsWithTheVersionTheCodeWasMarkedWith() {
        XCTAssertNil(LayoutMapData.failure)
        let mip = LayoutMapData.mipStrapMap(id: "csme18-mip")
        XCTAssertEqual(mip?.containers.map(\.fields.count),
                       [253, 5, 249, 133, 515, 253, 42])
        XCTAssertEqual(LayoutMapData.cpuStrapMap(id: "csme18-cpu")?.fields.count, 35)
        let sphy = LayoutMapData.sphyNvarMap(id: "csme18-sphy")
        XCTAssertEqual(sphy?.anchors.count, 7)
        XCTAssertEqual(sphy?.fields.count, 522)
    }

    /// The containers keep the block type and length the MIP descriptor uses
    /// to choose them, and the CPU message keeps its byte offset and bit.
    func testTheLayoutsKeepTheirSelectionKeys() throws {
        let mip = try XCTUnwrap(LayoutMapData.mipStrapMap(id: "csme18-mip"))
        let ioe = mip.containers.filter { $0.name == "IOE" }
        XCTAssertEqual(ioe.map(\.blockLength), [0x3C, 0xD0])
        XCTAssertEqual(Set(ioe.map(\.blockType)), [4])
        let pmc = try XCTUnwrap(mip.containers.first { $0.name == "PMC SoC" })
        XCTAssertEqual(pmc.blockType, 1)
        XCTAssertEqual(pmc.blockLength, 0x58)
        XCTAssertEqual(pmc.length, 0x48)

        let cpu = try XCTUnwrap(LayoutMapData.cpuStrapMap(id: "csme18-cpu"))
        let cores = try XCTUnwrap(cpu.fields.first { $0.name.contains("ATOM_CORES") })
        XCTAssertGreaterThanOrEqual(cores.offset, 0)
        XCTAssertGreaterThanOrEqual(cores.bit, 0)
        XCTAssertNotNil(cpu.fields.first { $0.options != nil })

        let sphy = try XCTUnwrap(LayoutMapData.sphyNvarMap(id: "csme18-sphy"))
        let anchor = try XCTUnwrap(sphy.anchors.first {
            $0.name == "Sub_Section_Entry2_Header_8"
        })
        XCTAssertEqual(anchor.value, 5)
    }

    func testAStaleVersionIsRefusedBeforeAnySectionIsRead() throws {
        var data = try XCTUnwrap(LayoutMapData.bundledData)
        let wrong = LayoutMapData.expectedVersion + 1
        data[8] = UInt8(truncatingIfNeeded: wrong)
        data[9] = UInt8(truncatingIfNeeded: wrong >> 8)
        data[10] = UInt8(truncatingIfNeeded: wrong >> 16)
        data[11] = UInt8(truncatingIfNeeded: wrong >> 24)
        XCTAssertThrowsError(try LayoutMapData.decode(data)) { error in
            guard case .versionMismatch(let file, let code)? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(file, wrong)
            XCTAssertEqual(code, LayoutMapData.expectedVersion)
        }
    }

    /// FNV-1a with the checksum field zeroed, as the compiler writes it.
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
        var data = try XCTUnwrap(LayoutMapData.bundledData)
        data[4] = 2
        XCTAssertThrowsError(try LayoutMapData.decode(data)) { error in
            XCTAssertEqual(error as? MapDataError, .unsupportedFormat(2))
        }
        var kind = try XCTUnwrap(LayoutMapData.bundledData)
        kind[12] = 1
        XCTAssertThrowsError(try LayoutMapData.decode(resigned(kind))) { error in
            XCTAssertEqual(error as? MapDataError, .wrongKind(1))
        }
    }

    func testAnEditedFileFailsItsChecksum() throws {
        var data = try XCTUnwrap(LayoutMapData.bundledData)
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try LayoutMapData.decode(data)) { error in
            guard case .corrupt? = error as? MapDataError else {
                return XCTFail("\(error)")
            }
        }
    }
}
