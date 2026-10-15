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
        guard let map = MEConfigurationMap.forME(major: analysis.version.major) else {
            return []
        }
        return (analysis.configuration ?? []).map { file in
            let layout = map.file(at: file.path)
            let fitc = file.fitc?.settings ?? []
            let mfs = file.mfs?.settings ?? []
            // The map's own order first — it is the order a bench reads these
            // files in — then anything a copy carries that the map does not
            // know, which keeps a value on screen instead of dropping it.
            var names = layout?.settings.map(\.name) ?? []
            for name in (fitc + mfs).map(\.name) where !names.contains(name) {
                names.append(name)
            }
            let rows = names.map { name -> MEAConfigurationRow in
                let setting = layout?.settings.first { $0.name == name }
                var label = name
                let auto = MEAText.configurationAuto(setting?.auto == true, in: language)
                if !auto.isEmpty { label += " · " + auto }
                return MEAConfigurationRow(
                    name: label,
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

    public init(name: String, fitc: String?, mfs: String?) {
        self.name = name
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
