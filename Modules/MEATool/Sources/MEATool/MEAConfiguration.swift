import Foundation
import Localization
import MEFirmware
import MEPresentation
import ToolModuleKit

/// The «Configuration» tab: the ME configuration file by file, as MFIT's own
/// settings database lays it out for this generation (`MEConfigurationMap`) —
/// what a build wrote, or what the running file system holds, setting by
/// setting.
///
/// Pure, like `MEASummary`: the controller lays out what this returns and reads
/// nothing itself. The map is chosen by the image's own generation, so a
/// generation nobody has mapped yet shows no tab content rather than another
/// generation's offsets read as values.
public enum MEAConfiguration {
    /// The tab's blocks — one per file, in the map's order — or none where the
    /// image's generation has no map.
    public static func build(_ analysis: FirmwareAnalysis,
                             in language: AppLanguage) -> [MEASummaryBlock] {
        guard let map = MEConfigurationMap.forME(major: analysis.version.major) else {
            return []
        }
        return (analysis.configuration ?? []).map { file in
            let layout = map.file(at: file.path)
            let rows = file.settings.map { setting -> MEASummaryRow in
                let settingLayout = layout?.settings.first { $0.name == setting.name }
                var text = MEAText.configurationValue(setting, layout: settingLayout,
                                                      in: language)
                let auto = MEAText.configurationAuto(setting.auto, in: language)
                if !auto.isEmpty { text += " · " + auto }
                return MEASummaryRow(setting.name, .value(text))
            }
            return MEASummaryBlock(title: MEAText.configurationFileTitle(file, in: language),
                                   rows: rows)
        }
    }
}
