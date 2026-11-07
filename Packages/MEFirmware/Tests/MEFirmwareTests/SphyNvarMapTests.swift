import XCTest
@testable import MEFirmware

/// The SPHY OEM configuration nvar: the tool's `SphyNvar` layout, its anchors,
/// and reading `phy_oem_cfg` out of a FITC partition's payload.
final class SphyNvarMapTests: XCTestCase {
    /// The map is the MTL layout the dump verifies — 522 fields — with the
    /// common header and the one variant-discriminating field as anchors.
    func testTheMapIsTheMTLLayout() throws {
        let map = try XCTUnwrap(SphyNvarMap.forME(major: 18))
        XCTAssertEqual(map.fields.count, 522)
        XCTAssertEqual(map.anchors.count, 7)
        let header = try XCTUnwrap(map.anchors.first {
            $0.name == "SPHY_OEM_NVAR_Common_Header_1"
        })
        XCTAssertEqual(header.bitOffset, 0)
        XCTAssertEqual(header.count, 32)
        XCTAssertEqual(header.value, 3)
        let variant = try XCTUnwrap(map.anchors.first {
            $0.name == "Sub_Section_Entry2_Header_8"
        })
        XCTAssertEqual(variant.value, 5, "the 542-field variant states 0x19 here")
        XCTAssertNil(SphyNvarMap.forME(major: 16))
    }

    /// The dump's own nvar — its first bytes and the discriminator below —
    /// reads through the layout; another variant's anchor makes it answer
    /// nothing.
    func testReadsTheDumpsNvarAndRefusesAnotherVariant() throws {
        var nvar = Data(repeating: 0, count: 0x431)
        nvar.replaceSubrange(0..<4, with: Data([0x03, 0x00, 0x00, 0x00]))
        nvar.replaceSubrange(4..<6, with: Data([0x05, 0x00]))
        nvar.replaceSubrange(6..<8, with: Data([0x03, 0x00]))
        nvar.replaceSubrange(8..<10, with: Data([0xFF, 0xFF]))
        nvar[12] = 0x03
        nvar[54] = 0x05                              // Sub_Section_Entry2_Header_8
        let map = try XCTUnwrap(SphyNvarMap.forME(major: 18))

        let payload = Self.fitcPayload(fileID: 0x1001_F200, value: nvar)
        let readings = try XCTUnwrap(SphyNvarReader.readings(in: payload, map: map))
        XCTAssertEqual(readings.count, 522)
        let byName = Dictionary(uniqueKeysWithValues: readings.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["SPHY_OEM_NVAR_Common_Header_1"], 3)
        XCTAssertEqual(byName["SPHY_OEM_NVAR_Common_Header_2"], 5)
        XCTAssertEqual(byName["SPHY_OEM_NVAR_Common_Header_4"], 0xFFFF)
        XCTAssertEqual(byName["Sub_Section_Entry2_Header_8"], 5)

        // The other variant's discriminator: not this layout.
        var other = nvar
        other[54] = 0x19
        XCTAssertNil(SphyNvarReader.readings(
            in: Self.fitcPayload(fileID: 0x1001_F200, value: other), map: map))
        // No such record at all.
        XCTAssertNil(SphyNvarReader.readings(
            in: Self.fitcPayload(fileID: 0x1002_0000, value: nvar), map: map))
    }

    private static func fitcPayload(fileID: UInt32, value: Data) -> Data {
        var payload = Data()
        payload.append(le32(1))
        payload.append(le32(fileID))
        payload.append(le32(0x10))
        payload.append(le16(UInt16(value.count)))
        payload.append(le16(0))
        payload.append(value)
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
