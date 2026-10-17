import XCTest
@testable import MEFirmware

/// CSME 18's CPU strap message: the tool's `CPU_smip` layout, and reading the
/// message out of the FITC partition's MIP table.
final class CPUStrapMapTests: XCTestCase {
    /// The map is the tool's own: 35 fields, its labels and option words.
    func testTheMapIsTheToolsOwnCPULayout() throws {
        let map = try XCTUnwrap(CPUStrapMap.forME(major: 18))
        XCTAssertEqual(map.fields.count, 35)
        let smt = try XCTUnwrap(map.fields.first { $0.name == "CPU_smip_Strap_CPU_SMT_Disable" })
        XCTAssertEqual(smt.offset, 0)
        XCTAssertEqual(smt.bit, 0)
        XCTAssertEqual(smt.count, 1)
        XCTAssertEqual(smt.label, "Disable Hyperthreading")
        XCTAssertEqual(smt.section, "CpuStraps")
        XCTAssertEqual(smt.options, [0: "No", 1: "Yes"])
        let atoms = try XCTUnwrap(map.fields.first {
            $0.name == "CPU_smip_Strap_CPU_NUM_OF_SOC_ATOM_CORES"
        })
        XCTAssertEqual(atoms.offset, 0)
        XCTAssertEqual(atoms.bit, 22)
        XCTAssertEqual(atoms.count, 3)
        XCTAssertEqual(atoms.options, [0: "Disable All Cores", 1: "1 Core Active",
                                       2: "2 Cores Active"])
        // The older generations keep their message in the descriptor, not here.
        XCTAssertNil(CPUStrapMap.forME(major: 16))
    }

    /// The MIP table of the CSME 18 dump at hand: four blocks, the CPU message
    /// header at 0x48 of the first and the three words at 0x4C, its CRC-16
    /// (CCITT-FALSE over the last two words, field zeroed) matching.
    func testReadsTheDumpsMIPTable() throws {
        let payload = Self.fitcPayload(message: Data([0x00, 0x10, 0x80, 0x00,
                                                      0x00, 0x20, 0x00, 0x04,
                                                      0x00, 0x00, 0xCE, 0xD6]))
        let map = try XCTUnwrap(CPUStrapMap.forME(major: 18))
        let straps = try XCTUnwrap(MIPTableReader.cpuStraps(in: payload, map: map))
        XCTAssertEqual(straps.messageLengthWords, 3)
        XCTAssertEqual(straps.crcStored, 0xD6CE)
        XCTAssertTrue(straps.crcValid)
        let byName = Dictionary(uniqueKeysWithValues: straps.readings.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_SMT_Disable"], 0)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_Num_Of_Big_Cores"], 0)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_BIST"], 0)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_FlexRatio"], 0)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_Fast_wakeup"], 1)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_NUM_OF_SOC_ATOM_CORES"], 2)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_IA_VR_ADDR"], 0)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_GT_VR_ADDR"], 1)
        XCTAssertEqual(byName["CPU_smip_Strap_CPU_SA_VR_ADDR"], 2)
    }

    /// A payload with no MIP table, or a message whose CRC disagrees, is not
    /// read as straps: the CRC is what says the placement is aligned.
    func testAPayloadWithoutAMIPTableAnswersNothing() throws {
        let map = try XCTUnwrap(CPUStrapMap.forME(major: 18))
        XCTAssertNil(MIPTableReader.cpuStraps(in: Data(repeating: 0xFF, count: 0x40), map: map))
        var payload = Self.fitcPayload(message: Data(repeating: 0x11, count: 12))
        let straps = try XCTUnwrap(MIPTableReader.cpuStraps(in: payload, map: map))
        XCTAssertFalse(straps.crcValid, "the values are still the image's, the CRC says they are not aligned")
        payload[0] = 0
        XCTAssertNil(MIPTableReader.cpuStraps(in: payload, map: map))
    }

    /// A FITC payload — record count, one record — whose record value is a MIP
    /// table of four contiguous blocks, the first carrying the CPU header and
    /// the message. The blocks after it are padding of the sizes the dump has.
    private static func fitcPayload(message: Data) -> Data {
        let headerSize = 4 + 4 * 8
        var block1 = Data(repeating: 0, count: 0x58)
        block1.replaceSubrange(0x48..<0x4C, with: Data([0x00, 0x00, 0x00, 0x03]))
        block1.replaceSubrange(0x4C..<(0x4C + message.count), with: message)
        let block2 = Data(repeating: 0, count: 0x40)
        let block3 = Data(repeating: 0, count: 0xD0)
        let block4 = Data(repeating: 0, count: 8)
        var table = Data()
        table.append(le16(4))
        let size = headerSize + block1.count + block2.count + block3.count + block4.count
        table.append(le16(UInt16(size)))
        var offset = headerSize
        for (type, block) in [(1, block1), (2, block2), (4, block3), (0, block4)] {
            table.append(le16(UInt16(type)))
            table.append(le16(UInt16(offset)))
            table.append(le16(UInt16(block.count)))
            table.append(le16(0))
            offset += block.count
        }
        table.append(block1)
        table.append(block2)
        table.append(block3)
        table.append(block4)
        XCTAssertEqual(table.count, size)

        var payload = Data()
        payload.append(le32(1))                       // one record
        payload.append(le32(0x1002_3E00))             // the smip nvar's File ID
        payload.append(le32(0x10))                    // value at 4 + 12
        payload.append(le16(UInt16(table.count)))     // size
        payload.append(le16(0))                       // flags
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
