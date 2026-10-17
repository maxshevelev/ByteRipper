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
        XCTAssertEqual(MEConfigurationMap.forME(major: 13)?.name, MEConfigurationMap.csme13.name)
        XCTAssertEqual(MEConfigurationMap.forME(major: 14)?.name, MEConfigurationMap.csme14.name)
        XCTAssertEqual(MEConfigurationMap.forME(major: 15)?.name, MEConfigurationMap.csme15.name)
        XCTAssertEqual(MEConfigurationMap.forME(major: 16)?.name, MEConfigurationMap.csme16.name)
        // A generation nobody has mapped reads nothing rather than another
        // generation's offsets.
        XCTAssertNil(MEConfigurationMap.forME(major: 12))
        XCTAssertNil(MEConfigurationMap.forME(major: 18))
        XCTAssertNil(MEConfigurationMap.forME(major: 7))
    }

    /// FIT 13's own map, and the mark it shares with the other FIT maps and not
    /// with MFIT's: no setting is `Auto`, because the attribute is MFIT's — of
    /// the four maps only the CSME 16 one, which comes from MFIT, carries it.
    func testTheThirteenMapIsWhatFit13LaysOut() {
        let map = MEConfigurationMap.csme13
        // 15 files and 40 settings since the places the tool names by a file
        // alone (`hw_binding`, `amt.wol`, …) are read too; the extra files are
        // the ones those settings are.
        XCTAssertEqual(map.files.count, 15)
        XCTAssertEqual(map.files.flatMap(\.settings).count, 40)
        for fit in [MEConfigurationMap.csme13, .csme14, .csme15] {
            XCTAssertFalse(fit.files.flatMap(\.settings).contains { $0.auto }, "\(fit.name)")
        }
        XCTAssertTrue(MEConfigurationMap.csme16.files.flatMap(\.settings).contains { $0.auto },
                      "MFIT's map is the one with the mark")
    }

    /// The tool's own name for a setting travels with it: the identifier is what
    /// a report and Intel's documents call it (`MELanPowerWell`), the label is
    /// what the tool's panel shows ("LAN Power Well"), and a setting whose tool
    /// states no label of its own carries none — repeating the identifier would
    /// say a panel shows something it does not.
    func testTheToolsOwnNamesForSettingsTravelWithThem() throws {
        for map in [MEConfigurationMap.csme13, .csme14, .csme15, .csme16] {
            let setting = try XCTUnwrap(map.files.flatMap(\.settings)
                .first { $0.name == "MELanPowerWell" }, map.name)
            XCTAssertEqual(setting.label, "LAN Power Well", map.name)
        }
        // The End of Manufacturing flag carries its label on every map that lays
        // the file out — all but the 14 one, which has no `eom_config` at all.
        for map in [MEConfigurationMap.csme13, .csme15, .csme16] {
            let setting = try XCTUnwrap(map.file(at: "/home/mca/eom_config")?
                .settings.first { $0.name == "EomFirstBootEnabled" }, map.name)
            XCTAssertEqual(setting.label, "EOM on First Boot Enabled", map.name)
        }
        // FIT 15 states no label for these: its panel shows the identifiers.
        for identifier in ["FID_PAV", "FID_ISH"] {
            XCTAssertNil(MEConfigurationMap.csme15.files.flatMap(\.settings)
                .first { $0.name == identifier }?.label, identifier)
        }
    }

    /// What the tools say about a setting travels with it, in the reader's
    /// words: prose, with the tool's own breaks and none of its markup — FIT
    /// writes them as `&lt;br /&gt;` and MFIT as `&#13;&#10;`, and both are
    /// lines by the time a map carries them.
    func testTheToolsHelpAboutASettingTravelsWithIt() throws {
        // Every generation's map carries help for most of what it lays out,
        // and the flag every one of them has is among the settings that do.
        for map in [MEConfigurationMap.csme13, .csme14, .csme15, .csme16] {
            let settings = map.files.flatMap(\.settings)
            let withHelp = settings.filter { $0.help?.isEmpty == false }
            XCTAssertGreaterThan(withHelp.count, settings.count / 2, map.name)
        }
        // The flag every map but the 14 one lays out: its help is the tool's,
        // and says what the setting does.
        for map in [MEConfigurationMap.csme13, .csme15, .csme16] {
            let flag = try XCTUnwrap(map.files.flatMap(\.settings)
                .first { $0.name == "EomFirstBootEnabled" }, map.name)
            XCTAssertEqual(flag.help?.hasPrefix("This setting det"), true, "\(map.name): \(flag.help ?? "—")")
            XCTAssertNotNil(flag.help?.range(of: "End of Manufacturing"), map.name)
        }
        let help = try XCTUnwrap(MEConfigurationMap.csme15.file(at: "/home/mca/eom_config")?
            .settings.first { $0.name == "EomFirstBootEnabled" }?.help)
        XCTAssertTrue(help.contains("\nNote: When this setting is enabled"), help)
        XCTAssertFalse(help.contains("<br"), help)
        XCTAssertFalse(help.contains("&#"), help)
    }

    /// CSME 13, 14 and 15 have a map for each half of the generation — the
    /// mobile parts and the desktop ones lay a few settings out differently —
    /// and CSME 16 has one for both, MFIT's database merging the platform
    /// lists it builds from.
    func testEachGenerationHasAMapForEachHalfOfIt() throws {
        XCTAssertTrue(try XCTUnwrap(MEConfigurationMap.forME(major: 15, family: .mobile))
            .name.contains("tgp_lp"))
        XCTAssertTrue(try XCTUnwrap(MEConfigurationMap.forME(major: 15, family: .desktop))
            .name.contains("tgp_h"))

        // The setting the two halves moved, and one only the desktop half has.
        func offset(_ name: String, in map: MEConfigurationMap) -> Int? {
            map.files.flatMap(\.settings).first { $0.name == name }?.offset
        }
        let mobile = try XCTUnwrap(MEConfigurationMap.forME(major: 15, family: .mobile))
        let desktop = try XCTUnwrap(MEConfigurationMap.forME(major: 15, family: .desktop))
        XCTAssertEqual(offset("SecureTouch", in: mobile), 8)
        XCTAssertEqual(offset("SecureTouch", in: desktop), 18)
        XCTAssertNil(offset("ProcMissingDetect", in: mobile))
        XCTAssertEqual(offset("ProcMissingDetect", in: desktop), 212)

        // 13 and 14 too, under the tool's own names for their desktop parts.
        XCTAssertTrue(try XCTUnwrap(MEConfigurationMap.forME(major: 13, family: .desktop))
            .name.contains("icl_h"))
        XCTAssertTrue(try XCTUnwrap(MEConfigurationMap.forME(major: 14, family: .desktop))
            .name.contains("cml_h"))
        XCTAssertNotEqual(MEConfigurationMap.forME(major: 14, family: .desktop)?.name,
                          MEConfigurationMap.forME(major: 14, family: .mobile)?.name)

        // MFIT's 16 map serves both halves.
        XCTAssertEqual(MEConfigurationMap.forME(major: 16, family: .desktop)?.name,
                       MEConfigurationMap.forME(major: 16, family: .mobile)?.name)
        // And a dump that did not say which half it is reads as the mobile one,
        // which is what every map was before the choice existed.
        XCTAssertEqual(MEConfigurationMap.forME(major: 15)?.name, mobile.name)
    }

    /// Which half a PCH strap section's length names: the lengths the two
    /// halves use, measured on the dumps at hand, and no claim about others.
    func testTheHalvesAreToldByTheStrapSectionsLength() {
        for words in [69, 70, 74] {
            XCTAssertEqual(MEConfigurationMap.MEPlatformFamily(strapWords: words), .mobile, "\(words)")
        }
        for words in [90, 101, 115] {
            XCTAssertEqual(MEConfigurationMap.MEPlatformFamily(strapWords: words), .desktop, "\(words)")
        }
        for words in [0, 68, 75, 89, 128, 0xFF] {
            XCTAssertNil(MEConfigurationMap.MEPlatformFamily(strapWords: words), "\(words)")
        }
    }

    /// A setting the tool names by its file alone is the file: the value is
    /// its first byte, and the width comes from the declaration's type — a
    /// value class is one byte. The tool's own words for the values come with
    /// the class, and their order is the class's (`DisabledEnabledValues` is
    /// Disabled at 0, `EnabledDisabledValues` the other way round).
    func testAPlaceTheToolNamesByAFileAloneIsTheFile() throws {
        let map = MEConfigurationMap.csme13
        let binding = try XCTUnwrap(map.file(at: "/home/bup/bup_sku/hw_binding")?
            .settings.first { $0.name == "HwBindingEn" })
        XCTAssertEqual(binding.offset, 0)
        XCTAssertEqual(binding.length, 1)
        XCTAssertEqual(binding.label, "Hardware Binding Enabled")
        XCTAssertEqual(binding.options?[0], "Disabled")
        XCTAssertEqual(binding.options?[1], "Enabled")
        XCTAssertNil(binding.bits, "the whole byte, not a bitfield")

        // CSME 15's own layout does not name it — the TGL family leaves the
        // setting to the FPF — and the number type states its own width.
        XCTAssertNil(MEConfigurationMap.csme15.files.flatMap(\.settings)
            .first { $0.name == "HwBindingEn" })
        let timeout = try XCTUnwrap(MEConfigurationMap.csme15.files.flatMap(\.settings)
            .first { $0.name == "AmtIdleTimeout" })
        XCTAssertEqual(timeout.offset, 0)
        XCTAssertEqual(timeout.length, 2, "a `word`")
    }

    /// A place the tool gives only under another setting's value is kept, with
    /// its condition — both branches of it — and a setting the tool switches off
    /// says what switches it off. The desktop half's place is unconditional.
    func testAConditionalPlaceIsKeptWithItsCondition() throws {
        func setting(_ name: String, in path: String,
                     of map: MEConfigurationMap) throws -> MEConfigurationMap.Setting {
            try XCTUnwrap(map.file(at: path)?.settings.first { $0.name == name },
                          "\(path) \(name) in \(map.name)")
        }
        let mobile = MEConfigurationMap.csme15
        let smt2 = try setting("MctpEcAddress", in: "/home/mctp/smt2_devices", of: mobile)
        XCTAssertEqual(smt2.condition, .init(name: "eSpiEnabled", value: 0))
        XCTAssertEqual(smt2.offset, 4)
        let eSpi = try setting("MctpEcAddress", in: "/home/mctp/espi_devices", of: mobile)
        XCTAssertEqual(eSpi.condition, .init(name: "eSpiEnabled", value: 1))
        XCTAssertEqual(eSpi.offset, 0)
        // The mirrored place: it clears the copy in the file the address left.
        let reset = try setting("ResetMctpEcAddress", in: "/home/mctp/smt2_devices", of: mobile)
        XCTAssertEqual(reset.condition, .init(name: "eSpiEnabled", value: 1))

        let bus = try setting("SmlinkBusSelection", in: "/home/smbus/smlink_bus", of: mobile)
        XCTAssertEqual(bus.disabledBy, .init(name: "eSpiEnabled", value: 1))

        // The condition is the tool's word resolved through its own value
        // class: `eSpiEnabled` is `NoYesValues`, where No is 0.
        let switchSetting = try setting("eSpiEnabled", in: "/home/mctp/espi_en", of: mobile)
        XCTAssertEqual(switchSetting.options?[0], "No")
        XCTAssertEqual(switchSetting.options?[1], "Yes")

        let desktop = try XCTUnwrap(MEConfigurationMap.forME(major: 15, family: .desktop))
        XCTAssertNil(try setting("MctpEcAddress", in: "/home/mctp/smt3_devices", of: desktop).condition,
                     "the desktop half lays it out once, unconditionally")
    }

    /// The End of Manufacturing record: the one thing the newer layouts do not
    /// bind (the tool writes it through its own `EomNvar`), and the one record
    /// whose place every generation agrees on — bit 0 of the two bytes of
    /// `/home/mca/eom_config`, and the same bit of the single byte of
    /// `/home/mca/eom`.
    func testTheEndOfManufacturingRecordIsTheSameInEveryMap() throws {
        for map in [MEConfigurationMap.csme13, MEConfigurationMap.csme15, MEConfigurationMap.csme16] {
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

    /// What the 14 map does *not* have: ME 14 lays out no End of Manufacturing
    /// record. FIT 14 binds `/home/mca/eom` — the byte the board itself wrote —
    /// and no `eom_config`, which is why the panel's Manufacturing row leans on
    /// the descriptor for an image of that generation instead of on the flag.
    /// FIT 13, one generation older, does bind it.
    func testTheFourteenMapHasNoEOMRecord() throws {
        let fourteen = MEConfigurationMap.csme14
        XCTAssertNotNil(fourteen.file(at: "/home/mca/eom"))
        XCTAssertNil(fourteen.file(at: "/home/mca/eom_config"))
        for newer in [MEConfigurationMap.csme13, MEConfigurationMap.csme15, MEConfigurationMap.csme16] {
            XCTAssertNotNil(newer.file(at: "/home/mca/eom_config"),
                            "\(newer.name) should carry the flag the 14 map has not got")
        }
    }

    /// The maps are the tools' own layouts, so which files a generation knows
    /// is a fact of its own map. Four files every one of them lays out — that
    /// set is what a bench reads first on any of them — one the newest three
    /// have and the oldest has not, and the four iunit files the two oldest
    /// have and the newer two have not, which is where reading one generation
    /// through another's map shows.
    func testThePlatformFilesAreTheToolsOwn() {
        for path in ["/home/mca/eom", "/home/policy/cfgmgr/cfg_rules",
                     "/home/bup/si_features", "/home/mctp/smt2_devices"] {
            for map in [MEConfigurationMap.csme13, .csme14, .csme15, .csme16] {
                XCTAssertNotNil(map.file(at: path), "\(map.name) has no \(path)")
            }
        }
        // FIT 14's cml_lp lays the host-interface file out and FIT 13's icl_lp
        // does not; every newer map has it again.
        XCTAssertNil(MEConfigurationMap.csme13.file(at: "/home/amt/skip_rtfd/ncsi"))
        for map in [MEConfigurationMap.csme14, .csme15, .csme16] {
            XCTAssertNotNil(map.file(at: "/home/amt/skip_rtfd/ncsi"), "\(map.name)")
        }
        // FIT 13's icl_lp and FIT 14's cml_lp bind the iunit files the newer
        // families replaced with `iunit_oem_cfg` and `iunit_privacy_mode`;
        // neither newer map knows them at all.
        for path in ["/home/iunit/port_cfg", "/home/iunit/sec_ctl",
                     "/home/iunit/sec_touch", "/home/iunit/camera_mask"] {
            XCTAssertNotNil(MEConfigurationMap.csme13.file(at: path))
            XCTAssertNotNil(MEConfigurationMap.csme14.file(at: path))
            XCTAssertNil(MEConfigurationMap.csme15.file(at: path))
            XCTAssertNil(MEConfigurationMap.csme16.file(at: path))
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

/// The conditional places of a map, as an image's two pages answer them: a
/// setting the tool lays out in one of two files, by another setting's value.
final class ConfigurationConditionTests: XCTestCase {
    /// `/a` holds the switch; `/b` and `/c` are the two branches of one setting.
    private var map: MEConfigurationMap {
        MEConfigurationMap(name: "test", files: [
            .init(path: "/a", alias: "A", settings: [
                .init(name: "Switch", offset: 0, length: 1, options: [0: "No", 1: "Yes"]),
                .init(name: "Off", offset: 1, length: 1,
                      disabledBy: .init(name: "Switch", value: 1)),
            ]),
            .init(path: "/b", alias: "B", settings: [
                .init(name: "Address", offset: 4, length: 2,
                      condition: .init(name: "Switch", value: 0)),
            ]),
            .init(path: "/c", alias: "C", settings: [
                .init(name: "Address", offset: 0, length: 2,
                      condition: .init(name: "Switch", value: 1)),
            ]),
        ])
    }

    private func bytes(_ values: [UInt8]) -> Data { Data(values) }

    /// The condition's own value names the branch, and it is not assumed.
    func testTheConditionsValueNamesTheBranch() {
        let off = ConfigurationDecoder.conditions(of: map,
            imageBytes: ["/a": bytes([0, 0]), "/b": bytes([0, 0, 0, 0, 0, 0])], liveBytes: [:])
        XCTAssertEqual(off.branch["Address"], "/b")
        XCTAssertEqual(off.placed["Address"], ConfigurationCondition(name: "Switch", value: 0))

        let on = ConfigurationDecoder.conditions(of: map,
            imageBytes: ["/a": bytes([1, 0]), "/c": bytes([0, 0])], liveBytes: [:])
        XCTAssertEqual(on.branch["Address"], "/c")
        XCTAssertEqual(on.placed["Address"]?.value, 1)
        XCTAssertEqual(on.placed["Address"]?.assumed, false)
    }

    /// Not in the image: the branch is the one whose file is here, and the
    /// reading says it was assumed.
    func testAValueNotInTheImagePicksTheBranchWhoseFileIsHere() {
        let assumed = ConfigurationDecoder.conditions(of: map,
            imageBytes: ["/b": bytes([0, 0, 0, 0, 0, 0])], liveBytes: [:])
        XCTAssertEqual(assumed.branch["Address"], "/b")
        XCTAssertEqual(assumed.placed["Address"], ConfigurationCondition(name: "Switch", value: 0,
                                                                         assumed: true))
        // Both branch files here and no value: the map's first branch wins,
        // and it is still assumed.
        let both = ConfigurationDecoder.conditions(of: map,
            imageBytes: ["/b": bytes([0, 0, 0, 0, 0, 0]), "/c": bytes([0, 0])], liveBytes: [:])
        XCTAssertEqual(both.branch["Address"], "/b")
        XCTAssertEqual(both.placed["Address"]?.assumed, true)
        // Neither file: the image holds the setting nowhere, and no branch is
        // claimed.
        let none = ConfigurationDecoder.conditions(of: map, imageBytes: [:], liveBytes: [:])
        XCTAssertNil(none.branch["Address"])
        XCTAssertNil(none.placed["Address"])
    }

    /// A branch chosen per setting would let a setting and its mirror disagree
    /// about one condition: the value is decided once, for the condition.
    func testTheMirroredPlaceFollowsTheSameBranch() {
        let mirrored = MEConfigurationMap(name: "test", files: [
            .init(path: "/a", alias: "A", settings: [
                .init(name: "Switch", offset: 0, length: 1),
            ]),
            .init(path: "/b", alias: "B", settings: [
                .init(name: "Address", offset: 4, length: 2,
                      condition: .init(name: "Switch", value: 0)),
                .init(name: "Reset", offset: 4, length: 2,
                      condition: .init(name: "Switch", value: 1)),
            ]),
            .init(path: "/c", alias: "C", settings: [
                .init(name: "Address", offset: 0, length: 2,
                      condition: .init(name: "Switch", value: 1)),
                .init(name: "Reset", offset: 0, length: 2,
                      condition: .init(name: "Switch", value: 0)),
            ]),
        ])
        let assumed = ConfigurationDecoder.conditions(of: mirrored,
            imageBytes: ["/b": bytes([0, 0, 0, 0, 0, 0])], liveBytes: [:])
        XCTAssertEqual(assumed.branch["Address"], "/b", "the switch is off, so the address is here")
        XCTAssertNotEqual(assumed.branch["Reset"], "/b",
                          "and the reset copy is the one in the file that is not here")
    }

    /// A setting the tool switches off is marked where the image holds the
    /// value the condition names, and not where the value is absent.
    func testASwitchedOffSettingIsMarkedWhereTheValueSaysSo() {
        let on = ConfigurationDecoder.conditions(of: map,
            imageBytes: ["/a": bytes([1, 1])], liveBytes: [:])
        XCTAssertEqual(on.disabled["Off"], ConfigurationCondition(name: "Switch", value: 1))
        let off = ConfigurationDecoder.conditions(of: map,
            imageBytes: ["/a": bytes([0, 1])], liveBytes: [:])
        XCTAssertNil(off.disabled["Off"])
        XCTAssertNil(ConfigurationDecoder.conditions(of: map, imageBytes: [:], liveBytes: [:])
            .disabled["Off"], "no value, no claim")
    }

    /// The tool's `NoYesValues`: No is 0 and Yes is 1, which is what the
    /// generated maps' conditions are stated in.
    func testTheConditionWordsAreResolvedThroughTheToolsClasses() {
        let map = MEConfigurationMap.csme15
        let switchSetting = map.files.flatMap(\.settings).first { $0.name == "eSpiEnabled" }
        XCTAssertEqual(switchSetting?.options?[0], "No")
        XCTAssertEqual(switchSetting?.options?[1], "Yes")
    }
}
