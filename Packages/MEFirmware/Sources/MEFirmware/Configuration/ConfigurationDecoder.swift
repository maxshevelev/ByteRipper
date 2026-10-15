// Reading the ME configuration out of an image: a file's bytes, the map's layout
// of it, and the values that come out.
//
// The decoder is generation-agnostic — it takes whichever `MEConfigurationMap`
// belongs to the image being read — so a new generation adds a map and no code.
//
// One decoder serves both pages an image keeps: the OEM Configuration (FITC)
// partition's record of a file, which is what the build wrote, and the MFS
// volume's own file, which is what the platform has in it now. Which one a value
// came from is recorded on the file (`ConfigurationFile.source`), not hidden: a
// setting edited in the file system and one a build wrote are different states
// of the same machine.

import Foundation

/// Turns a configuration file's bytes into the settings a map says it holds.
enum ConfigurationDecoder {
    /// The settings a file's bytes carry, in the map's order. A setting whose
    /// field runs past the bytes there are is left out: the file may be of
    /// another generation, and a value read out of the next file's bytes would
    /// be worse than no value.
    static func settings(of file: MEConfigurationMap.File,
                         in bytes: Data) -> [ConfigurationSetting] {
        file.settings.compactMap { setting in
            guard setting.length > 0, setting.length <= 8,
                  setting.offset >= 0, setting.offset + setting.length <= bytes.count else {
                return nil
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

    /// The report's entry for one file of a map: the bytes an image carries and
    /// the settings they hold. Nil where the bytes are shorter than the map's
    /// first field, which is a file of another shape rather than an empty one.
    static func file(_ layout: MEConfigurationMap.File,
                     from source: ConfigurationFile.Source,
                     bytes: Data) -> ConfigurationFile? {
        let settings = settings(of: layout, in: bytes)
        guard !settings.isEmpty else { return nil }
        return ConfigurationFile(path: layout.path, alias: layout.alias,
                                 source: source, size: bytes.count,
                                 settings: settings)
    }
}
