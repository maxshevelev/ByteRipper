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

    /// One setting of one file, as MFIT lays it out.
    public struct Setting: Sendable, Equatable {
        /// MFIT's name for the setting (`EomFirstBootEnabled`), which is also
        /// what an engineer sees in its panel and in Intel's own documents — so
        /// it stays untranslated, like `FlexibleEomSettings`' own option labels.
        public var name: String
        /// Byte offset into the file's content.
        public var offset: Int
        /// The field's length in bytes — of the word the bits below are counted
        /// in, for a bitfield.
        public var length: Int
        /// Which bits of that word the setting is, where it is a bitfield; nil
        /// where the setting is the whole field.
        public var bits: ClosedRange<Int>?
        /// The values the setting may take, by their number, in MFIT's words —
        /// where MFIT itself says (its `config_params`). A setting without them
        /// is read as a number or a bit, and nothing is claimed about what the
        /// numbers mean.
        public var options: [Int: String]?
        /// True where MFIT marks the setting `Auto`: the platform writes it
        /// (a version, a strap read off the board), so a build carries only a
        /// placeholder for it.
        public var auto: Bool

        public init(name: String, offset: Int, length: Int,
                    bits: ClosedRange<Int>? = nil,
                    options: [Int: String]? = nil, auto: Bool = false) {
            self.name = name
            self.offset = offset
            self.length = length
            self.bits = bits
            self.options = options
            self.auto = auto
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

    /// The map for a ME generation's major number, or nil where none has been
    /// made for it yet. The number is the one the engine identifies the image
    /// by (`version.major`), which is what a map is verified against.
    public static func forME(major: Int) -> MEConfigurationMap? {
        switch major {
        case 16: return .csme16
        default: return nil
        }
    }

    /// The map's entry for a path, where it has one.
    public func file(at path: String) -> File? {
        files.first { $0.path == path }
    }
}
