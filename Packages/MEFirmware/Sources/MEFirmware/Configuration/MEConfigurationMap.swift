// The ME configuration, file by file: which settings MFIT's own settings
// database says live in which MFS file, at what offset, in which bits, and what
// their values may say.
//
// **A map is per generation, because MFIT's own database is.** The file lists it
// carries differ between tool versions and platforms, the offsets inside a file
// like `cfg_rules` move, and a generation nobody has mapped is read as *no*
// configuration rather than through another generation's layout — a wrong
// offset read as a value is worse than a row that is not there.
//
// Every map is curated by hand from an MFIT build of that generation: its
// database is zlib-compressed XML inside `mfit.exe`, unpacked as described in
// `Design/ME_STRUCTURES.md`. Each map is a file of its own beside this one
// (`MEConfigurationMap+CSME16.swift`), so a new generation is a new file and one
// line in `forME(major:)`, and no map can be edited into another's shape by
// accident.
//
// The FPF/UEP settings — the Boot Guard profile, the OEM key hash and the rest
// of what a platform burns into its fuses — are not files of the MFS and are
// read by `BootGuardReader` instead.

import Foundation

/// One generation's map of the ME configuration.
public struct MEConfigurationMap: Sendable, Equatable {
    /// What the map is, and which MFIT build it was curated from — said in the
    /// panel, so a reader knows whose layout a value came out of.
    public var name: String
    public var files: [File]

    public init(name: String, files: [File]) {
        self.name = name
        self.files = files
    }

    /// The value another setting must have for a place to hold, or for a
    /// setting to be switched off — the tool's `source` and `conditionalVal` /
    /// `sourceVal`, resolved through the source setting's own value class to
    /// the number it stands for (`eSpiEnabled = No` is `NoYesValues`' 0).
    public struct Condition: Sendable, Equatable {
        /// The identifier of the setting the condition is on.
        public var name: String
        /// The number that setting must have.
        public var value: Int

        public init(name: String, value: Int) {
            self.name = name
            self.value = value
        }
    }

    /// One setting of one file, as MFIT lays it out.
    public struct Setting: Sendable, Equatable {
        /// The setting's identifier (`MELanPowerWell`), as the tool's own
        /// layouts and Intel's documents spell it — so it stays untranslated,
        /// like `FlexibleEomSettings`' own option labels.
        public var name: String
        /// What the tool's panel shows for the setting where that is not the
        /// identifier — `"LAN Power Well"`, `"Intel(R) PTT Supported"`, the
        /// `label` of FIT's `CfgOpt` or of MFIT's `<UI>` element. Nil where the
        /// tool states none, or states the identifier itself, and an engineer
        /// then sees the name; the two are both what a bench compares its
        /// screen against, and `name` is what a document or a report calls it.
        public var label: String?
        /// Byte offset into the file's content.
        public var offset: Int
        /// The field's length in bytes — of the word the bits below are counted
        /// in, for a bitfield.
        public var length: Int
        /// Which bits of that word the setting is, where it is a bitfield; nil
        /// where the setting is the whole field.
        public var bits: ClosedRange<Int>?
        /// What the tool's panel says about the setting, where it says
        /// anything — FIT's `help` on the `<CfgOpt>` declaration, MFIT's on the
        /// `<UI>` element of the same setting. Its own words, in English, as
        /// its labels are: a reader who wants them is reading the tool's
        /// documentation at the row. Nil where the tool has nothing to say.
        public var help: String?
        /// The values the setting may take, by their number, in MFIT's words —
        /// where MFIT itself says (its `config_params`). A setting without them
        /// is read as a number or a bit, and nothing is claimed about what the
        /// numbers mean.
        public var options: [Int: String]?
        /// True where MFIT marks the setting `Auto`: the value is not the
        /// builder's to enter — the tool works it out and writes it into the
        /// image's own `AutoNvars` container — so a file carries only what the
        /// tool put there. False is MFIT's `Generic`: a setting a build is
        /// given, in the file it lives in.
        public var auto: Bool
        /// True where the field is a number MFIT writes in hex (`byte`, `word`,
        /// `dword`, `qword` — every one of them: its own default for a byte is
        /// `0x02`, not `2`). False on an enumerated setting, which reads as its
        /// label, and on the few that are text.
        public var hex: Bool
        /// True where the field is text rather than a number — a PKI suffix, a
        /// domain name. The bytes are decoded as characters rather than printed
        /// as hex.
        public var text: Bool
        /// Where the tool places the setting here only under a condition — its
        /// `buildConditional` actions. The other branch is the same setting in
        /// the other file with the mirrored condition (`eSpiEnabled = Yes` puts
        /// the MCTP EC address in the eSPI device file, `= No` in the SMT2
        /// one), and an image holds one of them. Nil for a place that always
        /// holds.
        public var condition: Condition?
        /// What the tool switches the setting off under — its `DisableIf`
        /// action: the value is in the file and does not apply. Nil where the
        /// tool says no such thing.
        public var disabledBy: Condition?

        public init(name: String, offset: Int, length: Int, label: String? = nil,
                    help: String? = nil,
                    condition: Condition? = nil, disabledBy: Condition? = nil,
                    bits: ClosedRange<Int>? = nil,
                    options: [Int: String]? = nil, auto: Bool = false,
                    hex: Bool = false, text: Bool = false) {
            self.name = name
            self.label = label
            self.help = help
            self.offset = offset
            self.length = length
            self.bits = bits
            self.options = options
            self.auto = auto
            self.hex = hex
            self.text = text
            self.condition = condition
            self.disabledBy = disabledBy
        }
    }

    /// One configuration file: the path the MFS knows it by, MFIT's alias for
    /// it, and the settings it holds.
    public struct File: Sendable, Equatable {
        /// The MFS path, as `FileTable.dat` spells it and the panel's tree
        /// prints it — which is how the file is found in an image at all
        /// (`/home/mca/eom_config`).
        public var path: String
        /// MFIT's own name for the file, printed in its panel's file list.
        public var alias: String
        public var settings: [Setting]

        public init(path: String, alias: String, settings: [Setting]) {
            self.path = path
            self.alias = alias
            self.settings = settings
        }
    }

    /// Which half of a chipset generation a board is: the mobile parts — the
    /// tool's `_lp` and `_p` families — or the desktop ones, its `_h` and
    /// `_s`. A few settings are laid out differently between the two, so the
    /// map that reads them has to be the board's own.
    ///
    /// **The firmware does not say.** Both halves of a generation carry the
    /// same platform name in their manifests ("TGP" is Tiger Lake LP and H
    /// alike), and MFIT's chipset init table names the chipset rather than
    /// the SKU. What does differ is the descriptor's PCH strap section, which
    /// the two halves lay out over different lengths — `init(strapWords:)`.
    /// Where no descriptor was read with the region nothing is claimed, and
    /// the mobile map is used, which is what every map was before the choice
    /// existed.
    public enum MEPlatformFamily: String, Sendable, CaseIterable, Codable {
        case mobile, desktop

        /// The half a PCH strap section of `words` words belongs to, or nil
        /// where the length is one neither half uses — a section from a
        /// generation this does not know, or one erased past reading.
        ///
        /// 69, 70 and 74 are Cannon Point LP (a CSME 14 Comet Lake board), Tiger
        /// Point LP (CSME 15) and Ice Point LP (CSME 13); 90, 101 and 115 are
        /// Cannon Point H (CSME 12), Tiger Point H and Alder Point S. Measured
        /// on the dumps at hand: `CSME 14.bin`, `CSME 15.bin`, `1.bin`,
        /// `CSME 13.BIN`, `CSME 12.BIN` (`Design/UEFI/UEFI_IMAGE_FORMAT.md`
        /// §2.6).
        public init?(strapWords: Int) {
            switch strapWords {
            case 69, 70, 74: self = .mobile
            case 90, 101, 115: self = .desktop
            default: return nil
            }
        }
    }

    /// The map for a ME generation's major number, or nil where none has been
    /// made for it yet. The number is the one the engine identifies the image
    /// by (`version.major`), which is what a map is verified against.
    ///
    /// `family` names the half of the generation the board is, where the dump
    /// says: CSME 13, 14 and 15 have a map for each, and CSME 16 has one for
    /// both — MFIT's database merges the platform lists it builds from. nil is
    /// a dump that did not say (no descriptor, or a section length neither
    /// half uses), and is read as the mobile one: the engine and the panel
    /// both ask through here, so the values they show cannot come from two
    /// layouts.
    public static func forME(major: Int, family: MEPlatformFamily? = nil) -> MEConfigurationMap? {
        let desktop = family == .desktop
        let map: MEConfigurationMap
        switch major {
        case 13: map = desktop ? .csme13Desktop : .csme13
        case 14: map = desktop ? .csme14Desktop : .csme14
        case 15: map = desktop ? .csme15Desktop : .csme15
        case 16: map = .csme16
        case 18: map = .csme18
        default: return nil
        }
        return map.addingManufacturingLock()
    }

    /// The live record of the board's End of Manufacturing, appended to every
    /// map — the one file that is ours and not the tool's.
    ///
    /// `/home/mca/manuf_lock` is in **no** MFIT or FIT database: the build
    /// writes its record with a zero and the platform sets it to 1 when it
    /// closes End of Manufacturing (`Design/ME_STRUCTURES.md`). The
    /// Configuration tab can show it like any other file — both copies side by
    /// side, the build's zero and the platform's byte — which is why the entry
    /// is added here rather than in a generated map: a regenerated map must not
    /// lose it, and no generator can emit a setting its source does not have.
    /// The identifier is ours; the label is the row the Summary gives it.
    private func addingManufacturingLock() -> MEConfigurationMap {
        let path = "/home/mca/manuf_lock"
        guard file(at: path) == nil else { return self }
        var map = self
        map.files.append(File(path: path, alias: "ManufLock", settings: [
            Setting(name: "ManufLock", offset: 0, length: 1,
                    label: "Manufacturing Lock",
                    options: [0: "Not locked", 1: "Locked"]),
        ]))
        return map
    }

    /// The map's entry for a path, where it has one.
    public func file(at path: String) -> File? {
        files.first { $0.path == path }
    }
}
