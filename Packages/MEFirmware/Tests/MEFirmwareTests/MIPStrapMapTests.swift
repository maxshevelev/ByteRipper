import XCTest
@testable import MEFirmware

/// The MIP table's non-CPU strap containers: the tool's layouts, and reading
/// CSME, PMC IOE and IOE out of a FITC partition's payload.
final class MIPStrapMapTests: XCTestCase {
    /// The map holds the three containers — CSME at block type 0, PMC IOE at
    /// 2, IOE at 4 — and both IOE layouts, chosen by the block's length.
    func testTheMapIsTheToolsContainers() throws {
        let map = try XCTUnwrap(MIPStrapMap.forME(major: 18))
        XCTAssertEqual(map.containers.map(\.name), ["CSME", "PMC IOE", "IOE", "IOE"])
        XCTAssertEqual(map.containers.map(\.blockType), [0, 2, 4, 4])
        XCTAssertEqual(map.containers.map(\.length), [0x8, 0x40, 0x3C, 0xD0])
        XCTAssertEqual(map.containers.map { $0.fields.count }, [5, 249, 133, 515])
        let ioEP = try XCTUnwrap(map.containers[3].fields.first {
            $0.name == "IOE_smip_Strap_IOEP_PCIED_RPCFG"
        })
        XCTAssertEqual(ioEP.bitOffset, 1, "a field may start at any bit of the block")
        XCTAssertEqual(ioEP.count, 3)
        let csme = try XCTUnwrap(map.containers[0].fields.first {
            $0.name == "CSME_smip_Strap_CSME_Early_USB_DbC_ME_Boot_Stall_Enable"
        })
        XCTAssertEqual(csme.bitOffset, 48)
        XCTAssertEqual(csme.label, "Enable early USB2 DbC connection")
        XCTAssertEqual(csme.options, [0: "No", 1: "Yes"])
        XCTAssertNil(MIPStrapMap.forME(major: 16))
    }

    /// The containers of the dump's table: CSME's five fields, PMC IOE's and
    /// IOE's read from their blocks, the IOE layout picked by the block length.
    func testReadsTheContainersOfTheMIPTable() throws {
        var blocks = [
            (type: 1, data: Data(repeating: 0, count: 0x58)),
            (type: 2, data: Data(repeating: 0, count: 0x40)),
            (type: 4, data: Data(repeating: 0, count: 0xD0)),
            (type: 0, data: Data(repeating: 0, count: 0x8)),
        ]
        blocks[1].data[0] = 0x01                     // PMC IOE: CPWRG_STCH_WTDIS
        blocks[2].data[0] = 0x02                     // IOE: RPCFG = 1 (bits 1–3)
        blocks[3].data[6] = 0x01                     // CSME: Early USB DbC at bit 48
        let payload = Self.fitcPayload(blocks: blocks)
        let map = try XCTUnwrap(MIPStrapMap.forME(major: 18))
        let containers = try XCTUnwrap(MIPTableReader.containers(in: payload, map: map))
        XCTAssertEqual(containers.map(\.name), ["CSME", "PMC IOE", "IOE"])

        let csme = Dictionary(uniqueKeysWithValues: containers[0].readings.map { ($0.name, $0.value) })
        XCTAssertEqual(csme["CSME_smip_Strap_CSME_Early_USB_DbC_ME_Boot_Stall_Enable"], 1)
        XCTAssertEqual(csme["CSME_smip_Strap_CSME_DAM_EN"], 0)

        let pmc = Dictionary(uniqueKeysWithValues: containers[1].readings.map { ($0.name, $0.value) })
        XCTAssertEqual(pmc["PMC_IOE_smip_Strap_pmc_ioem_smip_CPWRG_STCH_WTDIS"], 1)
        XCTAssertEqual(containers[1].length, 0x40)

        let ioe = Dictionary(uniqueKeysWithValues: containers[2].readings.map { ($0.name, $0.value) })
        XCTAssertEqual(ioe["IOE_smip_Strap_IOEP_PCIED_RPCFG"], 1)
        XCTAssertEqual(ioe["IOE_smip_Strap_IOEP_PCIED_LNREV"], 0)
        XCTAssertEqual(containers[2].length, 0xD0)
    }

    /// A 0x3C IOE block is MTL-M's layout, not the 0xD0 one: the block's
    /// length is what chooses between them.
    func testTheIOELayoutIsChosenByTheBlockLength() throws {
        var blocks = [
            (type: 4, data: Data(repeating: 0, count: 0x3C)),
            (type: 0, data: Data(repeating: 0, count: 0x8)),
        ]
        blocks[0].data[0] = 0x01
        let payload = Self.fitcPayload(blocks: blocks)
        let map = try XCTUnwrap(MIPStrapMap.forME(major: 18))
        let containers = try XCTUnwrap(MIPTableReader.containers(in: payload, map: map))
        let ioe = try XCTUnwrap(containers.first { $0.name == "IOE" })
        XCTAssertEqual(ioe.length, 0x3C)
        XCTAssertEqual(ioe.readings.first?.name,
                       "IOE_smip_Strap_IOEM_TCSS_XHCI_XHC_PORT1_OWNERSHIP_STRAP")
        XCTAssertEqual(ioe.readings.first?.value, 1)
    }

    /// A payload with no MIP table answers nothing.
    func testAPayloadWithoutAMIPTableAnswersNothing() throws {
        let map = try XCTUnwrap(MIPStrapMap.forME(major: 18))
        XCTAssertNil(MIPTableReader.containers(in: Data(repeating: 0xFF, count: 0x40), map: map))
    }

    /// A FITC payload — record count, one record — whose value is a MIP table
    /// of the given blocks, contiguous from the end of the header.
    private static func fitcPayload(blocks: [(type: Int, data: Data)]) -> Data {
        let headerSize = 4 + blocks.count * 8
        var table = Data()
        table.append(le16(UInt16(blocks.count)))
        let size = headerSize + blocks.reduce(0) { $0 + $1.data.count }
        table.append(le16(UInt16(size)))
        var offset = headerSize
        for block in blocks {
            table.append(le16(UInt16(block.type)))
            table.append(le16(UInt16(offset)))
            table.append(le16(UInt16(block.data.count)))
            table.append(le16(0))
            offset += block.data.count
        }
        for block in blocks { table.append(block.data) }

        var payload = Data()
        payload.append(le32(1))
        payload.append(le32(0x1002_3E00))
        payload.append(le32(0x10))
        payload.append(le16(UInt16(table.count)))
        payload.append(le16(0))
        payload.append(table)
        return payload
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }
}
