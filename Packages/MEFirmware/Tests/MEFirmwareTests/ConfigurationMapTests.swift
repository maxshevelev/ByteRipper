import XCTest
@testable import MEFirmware

/// The ME configuration map, and the decoder that reads a file through it.
///
/// The map is emitted from the vendor's own database rather than typed out —
/// `Skills/me-eom-structures/scripts/mfit_map.py` for MFIT's generations and
/// `fit_map.py` for FIT's — so what is worth pinning here is not a list of
/// offsets but the three things a regeneration could quietly break: which
/// generation reads which map, the one record every generation shares, and the
/// places two generations *disagree* about.
final class ConfigurationMapTests: XCTestCase {
    func testEachMappedGenerationReadsItsOwnMap() {
        XCTAssertEqual(MEConfigurationMap.forME(major: 15)?.name, MEConfigurationMap.csme15.name)
        XCTAssertEqual(MEConfigurationMap.forME(major: 16)?.name, MEConfigurationMap.csme16.name)
        // A generation nobody has mapped reads nothing rather than another
        // generation's offsets.
        XCTAssertNil(MEConfigurationMap.forME(major: 12))
        XCTAssertNil(MEConfigurationMap.forME(major: 18))
        XCTAssertNil(MEConfigurationMap.forME(major: 7))
    }

    /// The End of Manufacturing record: the one thing the newer layouts do not
    /// bind (the tool writes it through its own `EomNvar`), and the one record
    /// whose place every generation agrees on — bit 0 of the two bytes of
    /// `/home/mca/eom_config`, and the same bit of the single byte of
    /// `/home/mca/eom`.
    func testTheEndOfManufacturingRecordIsTheSameInBothMaps() throws {
        for map in [MEConfigurationMap.csme15, MEConfigurationMap.csme16] {
            let config = try XCTUnwrap(map.file(at: "/home/mca/eom_config"),
                                       "\(map.name) has no EOM_Config")
            XCTAssertEqual(config.alias, "EOM_Config")
            let flag = try XCTUnwrap(config.settings.first { $0.name == "EomFirstBootEnabled" })
            XCTAssertEqual(flag.offset, 0)
            XCTAssertEqual(flag.bits, 0...0)
            XCTAssertEqual(flag.options?[0], "No")
            XCTAssertEqual(flag.options?[1], "Yes")

            let eom = try XCTUnwrap(map.file(at: "/home/mca/eom"),
                                    "\(map.name) has no EOM")
            XCTAssertEqual(eom.settings.first { $0.name == "EomFirstBootEnabled" }?.bits, nil)
        }
    }

    /// Where the two generations differ, and how much: the config-rule file's
    /// layout is the same in both — the same cells, the same bits — while the
    /// iunit file's is not. That difference is the reason a generation reads
    /// its own map and not the newer one's.
    func testTheTwoGenerationsAgreeOnThePolicyFileAndNotOnIunit() throws {
        let fifteen = try XCTUnwrap(MEConfigurationMap.csme15.file(at: "/home/policy/cfgmgr/cfg_rules"))
        let sixteen = try XCTUnwrap(MEConfigurationMap.csme16.file(at: "/home/policy/cfgmgr/cfg_rules"))
        let powerWell = { (file: MEConfigurationMap.File) -> MEConfigurationMap.Setting? in
            file.settings.first { $0.name == "MELanPowerWell" }
        }
        XCTAssertEqual(powerWell(fifteen)?.offset, 188)
        XCTAssertEqual(powerWell(fifteen)?.offset, powerWell(sixteen)?.offset)
        XCTAssertEqual(powerWell(fifteen)?.bits, 0...2)

        let iunit = try XCTUnwrap(MEConfigurationMap.csme15.file(at: "/home/iunit/iunit_oem_cfg"))
        let newer = try XCTUnwrap(MEConfigurationMap.csme16.file(at: "/home/iunit/iunit_oem_cfg"))
        // FIT 15 puts the secure-touch switch at byte 8 of the file; MFIT 16
        // puts it at 18. Reading one generation through the other's map would
        // have called byte 18 a setting.
        XCTAssertEqual(iunit.settings.first { $0.name == "SecureTouch" }?.offset, 8)
        XCTAssertEqual(newer.settings.first { $0.name == "SecureTouch" }?.offset, 18)
    }

    /// A file's bytes read through the map: a bitfield out of the little-endian
    /// word the map names, a plain field as itself, and a field the bytes do
    /// not reach left out rather than guessed at.
    func testTheDecoderReadsThePlacesTheMapNames() throws {
        let file = try XCTUnwrap(MEConfigurationMap.csme16.file(at: "/home/mca/eom_config"))
        var bytes = Data(repeating: 0, count: 2)
        bytes[0] = 0b0000_0110   // bit 0 clear (no EOM flag), bits 1-2 = 3
        let settings = ConfigurationDecoder.settings(of: file, in: bytes)
        XCTAssertEqual(settings.map(\.name),
                       ["EomFirstBootEnabled", "FlexibleEomSettings"])
        XCTAssertEqual(settings[0].number, 0)
        XCTAssertEqual(settings[1].number, 3)

        // A file shorter than the map's first field is a file of another shape,
        // not an empty one.
        XCTAssertTrue(ConfigurationDecoder.settings(of: file, in: Data()).isEmpty)

        // A field wider than eight bytes comes back as its bytes, which is all a
        // 256-byte PKI suffix or a SHA-384 hash is.
        let wide = MEConfigurationMap.Setting(name: "Wide", offset: 0, length: 16)
        let long = ConfigurationDecoder.settings(of: .init(path: "/home/x", alias: "X",
                                                           settings: [wide]),
                                                 in: Data(repeating: 0xAB, count: 16))
        XCTAssertNil(long.first?.number)
        XCTAssertEqual(long.first?.bytes, String(repeating: "AB", count: 16))
    }
}
