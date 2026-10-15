import Foundation
import Localization
import MEFirmware

// help: (none — the Configuration tab is an experiment, and the page that
// explains it is not written yet; the anchor goes in when it is)
/// The «Configuration» tab's words: the value of one configuration setting, and
/// the heading of the file it belongs to. Ours — MFIT's panel is the only other
/// place a setting is shown this way — and the value is written the way MFIT
/// writes it: the label its database gives a number where it has one, the
/// number itself where it does not.
extension MEAText {
    /// One setting's value as the tab shows it. `layout` is the setting as the
    /// generation's map lays it out, which decides how the number reads: a
    /// bitfield or a single byte as a number, a wider field in hex. A setting
    /// whose layout the map does not have — a file of another shape — reads as
    /// its number and claims nothing more.
    public static func configurationValue(_ setting: ConfigurationSetting,
                                          layout: MEConfigurationMap.Setting?,
                                          in language: AppLanguage) -> String {
        guard let number = setting.number else {
            // Wider than eight bytes: the bytes themselves, in hex.
            return setting.bytes ?? ""
        }
        if let label = layout?.options?[number] { return label }
        let wide = (layout?.bits == nil) && (layout?.length ?? 1) > 1
        return wide ? String(format: "0x%X", number) : String(number)
    }

    /// A configuration file's heading: the path the file system knows it by,
    /// MFIT's own name for it, its size, and which of the image's two pages the
    /// bytes came from — the build's own record or the running file system.
    public static func configurationFileTitle(_ file: ConfigurationFile,
                                              in language: AppLanguage) -> String {
        let source = file.source == .fileSystem
            ? L("file system", in: language)
            : L("image", in: language)
        return "\(file.path) — \(file.alias), \(size(file.size)), \(source)"
    }

    /// The mark MFIT puts on a setting it fills in itself rather than taking
    /// from a build (`process_type: Auto`).
    public static func configurationAuto(_ auto: Bool, in language: AppLanguage) -> String {
        auto ? L("auto", in: language) : ""
    }
}
