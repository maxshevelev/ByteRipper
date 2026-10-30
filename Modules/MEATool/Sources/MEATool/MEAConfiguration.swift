import Foundation
import Localization
import MEFirmware
import MEPresentation
import ToolModuleKit

/// The «Configuration» tab: the ME configuration file by file, as MFIT's own
/// settings database lays it out for this generation (`MEConfigurationMap`) —
/// each setting read in **both** copies an image carries of the file it lives
/// in: the OEM Configuration (FITC) partition's record, which is what the build
/// wrote, and the ME file system's own file, which is what the platform holds
/// now.
///
/// Pure, like `MEASummary`: the controller lays out what this returns and reads
/// nothing itself. The map is chosen by the image's own generation, so a
/// generation nobody has mapped yet shows no tab content rather than another
/// generation's offsets read as values.
public enum MEAConfiguration {
    /// The tab's blocks — one per file, in the map's order — or none where the
    /// image's generation has no map.
    public static func build(_ analysis: FirmwareAnalysis,
                             in language: AppLanguage) -> [MEAConfigurationBlock] {
        // The map the engine read the values through: the same call with the
        // same answer, so a row's labels and its values cannot come from two
        // layouts.
        guard let map = MEConfigurationMap.forME(major: analysis.version.major,
                                                 family: analysis.platformFamily) else {
            return []
        }
        return (analysis.configuration ?? []).map { file in
            let layout = map.file(at: file.path)
            let fitc = file.fitc?.settings ?? []
            let mfs = file.mfs?.settings ?? []
            // The map's own order first — it is the order a bench reads these
            // files in — then anything a copy carries that the map does not
            // know, which keeps a value on screen instead of dropping it.
            // A conditionally placed setting is a row of the file the image
            // holds it in, and of no other: the map has both branches, and the
            // other one belongs to a file this image does not read it from.
            var names = layout?.settings.filter { setting in
                setting.condition == nil || (fitc + mfs).contains { $0.name == setting.name }
            }.map(\.name) ?? []
            for name in (fitc + mfs).map(\.name) where !names.contains(name) {
                names.append(name)
            }
            let rows = names.map { name -> MEAConfigurationRow in
                let setting = layout?.settings.first { $0.name == name }
                // The tool's own name for the setting where it has one —
                // "LAN Power Well" where the map's identifier is
                // `MELanPowerWell` — and the identifier alone where the tool
                // shows that instead. The row reads as the tool's panel does;
                // the identifier is the map's, and a report's.
                var label = setting?.label ?? name
                let auto = MEAText.configurationAuto(setting?.auto == true, in: language)
                if !auto.isEmpty { label += " · " + auto }
                // What placed the setting, and what switches it off: the
                // tool's own identifiers and option words, kept for the `?`'s
                // popover — a row's name has no room for them, and a name
                // three phrases long reads as no name at all. This setting's
                // own, in either copy: a file's other settings say nothing
                // about this one.
                let copies = (fitc + mfs).filter { $0.name == name }
                let condition = copies.compactMap(\.condition).first
                let disabled = copies.compactMap(\.disabled).first
                var note: [String] = []
                if let condition {
                    note.append(MEAText.configurationCondition(condition, in: map, language: language))
                }
                if let disabled {
                    note.append(MEAText.configurationDisabled(disabled, in: map, language: language))
                }
                return MEAConfigurationRow(
                    name: label,
                    identifier: name,
                    // Where the tool says nothing about a setting, there is no
                    // button to press and no popover to open.
                    help: setting?.help,
                    note: note.isEmpty ? nil : note.joined(separator: " · "),
                    condition: condition,
                    disabled: disabled != nil,
                    fitc: MEAText.configurationValue(fitc.first { $0.name == name },
                                                     layout: setting, in: language),
                    mfs: MEAText.configurationValue(mfs.first { $0.name == name },
                                                    layout: setting, in: language))
            }
            return MEAConfigurationBlock(
                alias: file.alias,
                detail: MEAText.configurationFileDetail(file, in: language),
                rows: rows)
        }
    }
}

/// One row of the Configuration tab: a setting, and the value each copy of the
/// file it lives in gives it.
///
/// The two are kept apart rather than resolved into one value, because they
/// answer different questions: what the build wrote is what a board is meant to
/// get, and what the file system holds is what it has. Nil is a copy that does
/// not carry the setting at all — an image that has never completed a first
/// boot has no file system copy — and is not a value.
public struct MEAConfigurationRow: Sendable, Equatable {
    /// The setting's name in MFIT's own words, with its `Auto` mark where the
    /// database gives it one.
    public let name: String
    /// What the setting is called where it is written down — the identifier
    /// the map lays it out by (`MELanPowerWell`). The row shows the tool's
    /// name for the setting, so this is what the row's help is headed with.
    public let identifier: String
    /// What the tool's panel says about the setting, where it says anything;
    /// nil there is no `?` beside the row at all.
    public let help: String?
    /// What the row's `?` says under the identifier: what placed the setting,
    /// and what switches it off — `eSpiEnabled = No, assumed · disabled by …`.
    /// Nil for a row with nothing to add. The popover's subtitle, not the
    /// row's: a name with three phrases after it reads as no name at all.
    public let note: String?
    /// The condition the tool placed the setting under, where it placed it
    /// conditionally, and which branch this image holds.
    public let condition: ConfigurationCondition?
    /// The tool switches the setting off in this image: its value is there and
    /// does not apply, and the row's values are drawn quiet.
    public let disabled: Bool
    /// The build's copy — the OEM Configuration partition's record.
    public let fitc: String?
    /// The file system's copy — the state in force.
    public let mfs: String?

    /// Whether the two copies disagree, which is the row a reader is looking
    /// for and the one the view marks. A copy that is not there at all is not a
    /// disagreement: an image nobody has booted has one column and no
    /// argument.
    public var differs: Bool {
        guard let fitc, let mfs else { return false }
        return fitc != mfs
    }

    public init(name: String, identifier: String, help: String? = nil, note: String? = nil,
                condition: ConfigurationCondition? = nil, disabled: Bool = false,
                fitc: String?, mfs: String?) {
        self.name = name
        self.identifier = identifier
        self.help = help
        self.note = note
        self.condition = condition
        self.disabled = disabled
        self.fitc = fitc
        self.mfs = mfs
    }
}

/// One configuration file's rows, under the heading that names the file.
///
/// The heading is in two parts because it is drawn in two weights: MFIT's own
/// name for the file (`alias`) — what Intel calls it, which is the word a bench
/// looks for — in bold, and where the file lives and how long it is (`detail`)
/// in the ordinary one. Kept apart here rather than composed, so the view does
/// the styling and this does the words.
public struct MEAConfigurationBlock: Sendable, Equatable {
    public let alias: String
    public let detail: String
    public let rows: [MEAConfigurationRow]

    public init(alias: String, detail: String, rows: [MEAConfigurationRow]) {
        self.alias = alias
        self.detail = detail
        self.rows = rows
    }
}
