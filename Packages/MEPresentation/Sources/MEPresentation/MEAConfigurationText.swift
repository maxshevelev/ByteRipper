import Foundation
import Localization
import MEFirmware

// help: (none — the Configuration tab is an experiment, and the page that
// explains it is not written yet; the anchor goes in when it is)
/// The «Configuration» tab's words: the value of one configuration setting in
/// one of the two copies, and the heading of the file they belong to. Ours —
/// MFIT's panel is the only other place a setting is shown this way — and the
/// value is written the way MFIT writes it: the label its database gives a
/// number where it has one, the number itself where it does not.
extension MEAText {
    /// The two copies of a configuration file, as the tab's column headings
    /// name them: the OEM Configuration partition's record, and the ME file
    /// system's own file. Both are the trade's words — the same in every
    /// language, as `$FPT` and `MFS` are — and they are the names MFIT's own
    /// panel uses, which is what a reader looking from one tool to the other
    /// has to go by.
    public static func configurationFITC(in language: AppLanguage) -> String {
        L("FITC", in: language)
    }

    public static func configurationMFS(in language: AppLanguage) -> String {
        L("MFS", in: language)
    }

    /// What a column shows where that copy of the file is not there at all: an
    /// image that has never completed a first boot has no file system copy, and
    /// one whose OEM Configuration partition is empty has no build copy. A dash
    /// rather than a zero — zero is a value, and this is its absence.
    public static let configurationAbsent = "—"

    /// One setting's value as one column reads it, or nil where that copy of
    /// the file does not carry the setting at all. `layout` is the setting as
    /// the generation's map lays it out, which decides how the number reads: a
    /// bitfield or a single byte as a number, a wider field in hex, and a
    /// number the map enumerates by its label. A setting whose layout the map
    /// does not have — a file of another shape — reads as its number and claims
    /// nothing more.
    public static func configurationValue(_ setting: ConfigurationSetting?,
                                          layout: MEConfigurationMap.Setting?,
                                          in language: AppLanguage) -> String? {
        guard let setting else { return nil }
        if layout?.text == true, let text = text(of: setting) { return text }
        guard let number = setting.number else {
            // Wider than eight bytes: the bytes themselves, in hex.
            return setting.bytes
        }
        if let label = layout?.options?[number] { return label }
        // Written the way MFIT writes it: a number of its own in hex (`0x02` is
        // how its byte fields read in its own panel), everything else as it is.
        let hex = layout?.hex ?? (setting.bytes != nil)
        return hex ? String(format: "0x%X", number) : String(number)
    }

    /// A text field's characters: the bytes as they stand, cut at the first
    /// null. MFIT stores these as a null-terminated `String`, and what follows
    /// the terminator is the rest of the field, not text.
    ///
    /// Nil where the value did not come as bytes at all — a field of eight
    /// bytes or fewer, which no text setting of any of these platforms is —
    /// which leaves the number to be read as one.
    private static func text(of setting: ConfigurationSetting) -> String? {
        guard let hex = setting.bytes else { return nil }
        var characters: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            if byte == 0 { break }
            characters.append(byte)
            index = next
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// The quiet half of a configuration file's heading: where the file lives,
    /// without the `/home` every one of these paths begins with, and how long
    /// it is. The length is the number alone, in decimal — two copies of a file
    /// are the same length, and the bytes are not what the row is read for.
    ///
    /// The other half is the file's own name (`ConfigurationFile.alias`), which
    /// the tab draws in bold against this.
    public static func configurationFileDetail(_ file: ConfigurationFile,
                                               in language: AppLanguage) -> String {
        let path = file.path.hasPrefix("/home/")
            ? String(file.path.dropFirst("/home".count))
            : file.path
        let size = file.mfs?.size ?? file.fitc?.size ?? 0
        return L("%1$@, %2$@ bytes", in: language, path, size)
    }

    /// The mark MFIT puts on a setting it fills in itself rather than taking
    /// from a build (`process_type: Auto`). A property of the setting rather
    /// than of either copy of it, so it stands beside the setting's name.
    public static func configurationAuto(_ auto: Bool, in language: AppLanguage) -> String {
        auto ? L("auto", in: language) : ""
    }
}
