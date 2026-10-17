// Reading the ME configuration out of an image: a file's bytes, the map's layout
// of it, and the values that come out.
//
// The decoder is generation-agnostic — it takes whichever `MEConfigurationMap`
// belongs to the image being read — so a new generation adds a map and no code.
//
// One decoder serves both copies an image keeps: the OEM Configuration (FITC)
// partition's record of a file, which is what the build wrote, and the MFS
// volume's own file, which is what the platform has in it now. It is the same
// read either way — the same map, the same offsets, the same bytes — so the
// caller runs it twice and keeps both (`ConfigurationFile.fitc` / `.mfs`): a
// setting edited in the file system and one a build wrote are different states
// of the same machine.

import Foundation

/// Turns a configuration file's bytes into the settings a map says it holds.
/// What an image's two pages say about a map's conditional places.
struct ConfigurationConditions: Sendable, Equatable {
    /// Setting name → the branch file the image holds it in.
    var branch: [String: String] = [:]
    /// The condition each conditionally placed setting was placed by, with
    /// `assumed` where the branch had to be told from the files present.
    var placed: [String: ConfigurationCondition] = [:]
    /// The condition each switched-off setting is off under.
    var disabled: [String: ConfigurationCondition] = [:]

    /// Whether the map's place of `setting` in `path` is the one the image
    /// holds: a place that always holds, or the branch chosen for it.
    func holds(_ setting: MEConfigurationMap.Setting, in path: String) -> Bool {
        setting.condition == nil || branch[setting.name] == path
    }
}

enum ConfigurationDecoder {
    /// The settings a file's bytes carry, in the map's order. A setting whose
    /// field runs past the bytes there are is left out: the file may be of
    /// another generation, and a value read out of the next file's bytes would
    /// be worse than no value.
    static func settings(of file: MEConfigurationMap.File,
                         in bytes: Data) -> [ConfigurationSetting] {
        file.settings.compactMap { setting in
            guard setting.length > 0,
                  setting.offset >= 0, setting.offset + setting.length <= bytes.count else {
                return nil
            }
            // Wider than a machine word: carried as the bytes themselves, which
            // is all a 256-byte PKI suffix or a SHA-384 hash is. A bitfield is
            // never one of these — there are no bits to take out of 16 bytes.
            guard setting.length <= 8 else {
                guard setting.bits == nil else { return nil }
                let field = bytes[bytes.startIndex + setting.offset
                                  ..< bytes.startIndex + setting.offset + setting.length]
                return ConfigurationSetting(name: setting.name, number: nil,
                                            bytes: field.map { String(format: "%02X", $0) }
                                                .joined(),
                                            auto: setting.auto)
            }
            var word = 0
            for index in 0..<setting.length {
                word |= Int(bytes[bytes.startIndex + setting.offset + index]) << (8 * index)
            }
            let value: Int
            if let bits = setting.bits {
                guard bits.lowerBound >= 0, bits.upperBound < setting.length * 8 else {
                    return nil
                }
                let width = bits.upperBound - bits.lowerBound + 1
                value = (word >> bits.lowerBound) & ((1 << width) - 1)
            } else {
                value = word
            }
            return ConfigurationSetting(name: setting.name, number: value,
                                        auto: setting.auto)
        }
    }


    /// The branch of each conditionally placed setting the image holds, and the
    /// settings the tool switches off in it.
    ///
    /// A condition's own value is read from the same two pages the tab shows,
    /// the build's copy first — the branch was chosen when the image was
    /// built. Where neither page carries the file the condition lives in, the
    /// branch is the one whose file the image does carry, and it is marked
    /// `assumed`: the reading rests on which files are there, not on the
    /// condition. Where neither branch's file is there, neither is kept — the
    /// image does not hold the setting in either place.
    static func conditions(of map: MEConfigurationMap,
                           imageBytes: [String: Data], liveBytes: [String: Data])
        -> ConfigurationConditions {
        var result = ConfigurationConditions()

        func value(of condition: MEConfigurationMap.Condition) -> Int? {
            for bytes in [imageBytes, liveBytes] {
                for file in map.files {
                    guard let setting = file.settings.first(where: { $0.name == condition.name }),
                          let data = bytes[file.path] else { continue }
                    let one = MEConfigurationMap.File(path: file.path, alias: file.alias,
                                                      settings: [setting])
                    if let number = settings(of: one, in: data).first?.number { return number }
                }
            }
            return nil
        }
        func present(_ path: String) -> Bool {
            imageBytes[path] != nil || liveBytes[path] != nil
        }

        // The conditions themselves first: the value each must have is one
        // fact, and every setting placed under it takes the same one — a
        // branch chosen per setting would let `MctpEcAddress` and its mirrored
        // `ResetMctpEcAddress` disagree about the same condition.
        var values: [String: (value: Int, assumed: Bool)] = [:]
        var conditional: [String: MEConfigurationMap.Condition] = [:]
        for file in map.files {
            for setting in file.settings {
                guard let condition = setting.condition else { continue }
                conditional[setting.name] = conditional[setting.name] ?? condition
            }
        }
        var conditionNames: [String] = []
        for (_, condition) in conditional where !conditionNames.contains(condition.name) {
            conditionNames.append(condition.name)
        }
        for name in conditionNames {
            let condition = MEConfigurationMap.Condition(name: name, value: 0)
            if let decided = value(of: condition) {
                values[name] = (decided, false)
                continue
            }
            // Not in the image: the branch whose file is here names the value,
            // and the reading is marked assumed. The two branches of one
            // condition live in different files, so a file being here is
            // evidence of the side it belongs to.
            let places = map.files.compactMap { file -> (path: String, value: Int)? in
                guard let setting = file.settings.first(where: {
                    $0.condition?.name == name
                }), let branch = setting.condition else { return nil }
                return (file.path, branch.value)
            }
            if let first = places.first(where: { present($0.path) }) {
                values[name] = (first.value, true)
            }
        }
        for (setting, condition) in conditional {
            guard let decided = values[condition.name] else { continue }
            result.branch[setting] = map.files.first { file in
                file.settings.contains { $0.name == setting && $0.condition?.value == decided.value }
            }?.path
            result.placed[setting] = ConfigurationCondition(name: condition.name,
                                                            value: decided.value,
                                                            assumed: decided.assumed)
        }
        // The settings the tool switches off, where the image holds the value
        // the condition names. Nothing is claimed where the value is not in
        // the image.
        for file in map.files {
            for setting in file.settings {
                guard let condition = setting.disabledBy,
                      result.disabled[setting.name] == nil,
                      value(of: condition) == condition.value else { continue }
                result.disabled[setting.name] = ConfigurationCondition(name: condition.name,
                                                                       value: condition.value)
            }
        }
        return result
    }

    /// One of a file's two copies, as the bytes an image carries give it. Nil    /// One of a file's two copies, as the bytes an image carries give it. Nil
    /// where the bytes hold none of the map's settings — a file of another
    /// shape rather than an empty one — which is what leaves the copy out of
    /// `ConfigurationFile` rather than reporting it as zeroes.
    static func page(of layout: MEConfigurationMap.File,
                     bytes: Data) -> ConfigurationFile.Page? {
        let settings = settings(of: layout, in: bytes)
        guard !settings.isEmpty else { return nil }
        return ConfigurationFile.Page(size: bytes.count, settings: settings)
    }
}
