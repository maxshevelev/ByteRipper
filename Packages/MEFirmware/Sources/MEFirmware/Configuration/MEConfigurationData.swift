import Foundation
import MapData

/// The reader's errors are the envelope's: a missing resource, a bad magic, a
/// format or version the code was not marked for, or a corrupt file.
public typealias MapDataError = MapData.MapDataError

/// One generation's map as the binary states it: the identifier the code asks
/// for and the map itself.
struct LoadedConfigurationMap: Sendable {
    var id: String
    var map: MEConfigurationMap
}

/// The configuration maps read from `ConfigMaps.bin`.
///
/// The file is generated from the JSON under
/// `Packages/MEFirmware/MapSources/configuration` and committed
/// (`Design/MAP_DATA.md`). Its header carries a version the code was marked
/// with too (`MEConfigurationDataVersion`); a file whose version differs is
/// refused before a section is read.
enum MEConfigurationData {
    static let formatVersion = MEConfigurationDataVersion.formatVersion
    static let expectedVersion = MEConfigurationDataVersion.version

    private static let loaded: Result<[LoadedConfigurationMap], MapDataError> = {
        guard let url = resourceURL else {
            return .failure(.resourceMissing("ConfigMaps.bin"))
        }
        do {
            return .success(try decode(Data(contentsOf: url)))
        } catch let error as MapDataError {
            return .failure(error)
        } catch {
            return .failure(.corrupt(error.localizedDescription))
        }
    }()

    /// The committed resource, for the tests that mutate a copy and for the
    /// panel's diagnostics.
    static var resourceURL: URL? {
        Bundle.module.url(forResource: "ConfigMaps", withExtension: "bin",
                          subdirectory: "ConfigMaps")
    }

    /// The committed bytes, for a test to damage a copy of.
    static var bundledData: Data? {
        resourceURL.flatMap { try? Data(contentsOf: $0) }
    }

    /// What went wrong, for the panel's diagnostics and the tests. Nil when
    /// the resource loaded.
    static var failure: MapDataError? {
        if case .failure(let error) = loaded { return error }
        return nil
    }

    static func map(id: String) -> MEConfigurationMap? {
        guard case .success(let maps) = loaded else { return nil }
        return maps.first { $0.id == id }?.map
    }

    /// The map a test or `forME` names, or a message naming the resource
    /// problem. Production code asks `map(id:)` and lives without the map.
    static func required(_ id: String) -> MEConfigurationMap {
        switch loaded {
        case .success(let maps):
            guard let map = maps.first(where: { $0.id == id })?.map else {
                preconditionFailure("the map resource has no \(id)")
            }
            return map
        case .failure(let error):
            preconditionFailure("the map resource: \(error)")
        }
    }

    // MARK: - Reading

    private static let mapRecordSize = 24
    private static let fileRecordSize = 20
    private static let settingRecordSize = 50
    private static let optionRecordSize = 8

    private static let hasBits: UInt16 = 1
    private static let hasOptions: UInt16 = 2
    private static let hasLabel: UInt16 = 4
    private static let hasHelp: UInt16 = 8
    private static let isAuto: UInt16 = 16
    private static let isHex: UInt16 = 32
    private static let isText: UInt16 = 64
    private static let hasCondition: UInt16 = 128
    private static let hasDisabledBy: UInt16 = 256

    static func decode(_ data: Data) throws -> [LoadedConfigurationMap] {
        let file = try MapFile(data: data, expectedVersion: expectedVersion)
        guard file.kind == .configuration else {
            throw MapDataError.wrongKind(file.kind.rawValue)
        }
        let mapsSection = try file.requireSection(.maps)
        let filesSection = try file.requireSection(.files)
        let settingsSection = try file.requireSection(.settings)
        let optionsSection = file.section(.options)

        let count = Int(try file.u32(mapsSection.offset))
        let mapsAt = try file.records(mapsSection, offset: 4, count: count,
                                      size: mapRecordSize, name: "map")
        var loaded: [LoadedConfigurationMap] = []
        for index in 0..<count {
            let at = mapsAt + index * mapRecordSize
            let id = try file.string(try file.u32(at)) ?? ""
            let name = try file.string(try file.u32(at + 4)) ?? ""
            let fileCount = Int(try file.u32(at + 8))
            let filesOffset = Int(try file.u32(at + 12))
            let filesAt = try file.records(filesSection, offset: filesOffset,
                                           count: fileCount,
                                           size: fileRecordSize, name: "file")
            var files: [MEConfigurationMap.File] = []
            files.reserveCapacity(fileCount)
            for fileIndex in 0..<fileCount {
                let fileAt = filesAt + fileIndex * fileRecordSize
                let path = try file.string(try file.u32(fileAt)) ?? ""
                let alias = try file.string(try file.u32(fileAt + 4)) ?? ""
                let settingCount = Int(try file.u32(fileAt + 8))
                let settingsOffset = Int(try file.u32(fileAt + 12))
                let settingsAt = try file.records(
                    settingsSection, offset: settingsOffset, count: settingCount,
                    size: settingRecordSize, name: "setting")
                var settings: [MEConfigurationMap.Setting] = []
                settings.reserveCapacity(settingCount)
                for settingIndex in 0..<settingCount {
                    let settingAt = settingsAt + settingIndex * settingRecordSize
                    let name = try file.string(try file.u32(settingAt)) ?? ""
                    let offset = Int(try file.u32(settingAt + 4))
                    let length = Int(try file.u16(settingAt + 8))
                    let flags = try file.u16(settingAt + 10)
                    let low = Int(file.bytes[settingAt + 12])
                    let high = Int(file.bytes[settingAt + 13])
                    let label = try file.string(try file.u32(settingAt + 14))
                    let help = try file.string(try file.u32(settingAt + 18))
                    let optionsOffset = try file.u32(settingAt + 22)
                    let optionCount = Int(try file.u16(settingAt + 26))
                    let condition = try readCondition(
                        file, nameAt: settingAt + 30, valueAt: settingAt + 34,
                        enabled: flags & hasCondition != 0)
                    let disabledBy = try readCondition(
                        file, nameAt: settingAt + 38, valueAt: settingAt + 42,
                        enabled: flags & hasDisabledBy != 0)
                    guard length > 0, offset >= 0 else {
                        throw MapDataError.corrupt(
                            "\(id): \(name) at \(offset), length \(length)")
                    }
                    if flags & hasBits != 0, !(low <= high && high < length * 8) {
                        throw MapDataError.corrupt(
                            "\(id): \(name) bits \(low)…\(high) of \(length) bytes")
                    }
                    var options: [Int: String] = [:]
                    if flags & hasOptions != 0, let optionsSection = optionsSection {
                        let optionsAt = try file.records(
                            optionsSection, offset: Int(optionsOffset),
                            count: optionCount, size: optionRecordSize,
                            name: "option")
                        for optionIndex in 0..<optionCount {
                            let optionAt = optionsAt + optionIndex * optionRecordSize
                            let value = Int(try file.u16(optionAt))
                            if let text = try file.string(try file.u32(optionAt + 4)) {
                                options[value] = text
                            }
                        }
                    }
                    settings.append(MEConfigurationMap.Setting(
                        name: name, offset: offset, length: length,
                        label: label, help: help,
                        condition: condition, disabledBy: disabledBy,
                        bits: flags & hasBits != 0 ? low...high : nil,
                        options: options.isEmpty ? nil : options,
                        auto: flags & isAuto != 0,
                        hex: flags & isHex != 0,
                        text: flags & isText != 0))
                }
                files.append(MEConfigurationMap.File(
                    path: path, alias: alias, settings: settings))
            }
            loaded.append(LoadedConfigurationMap(
                id: id, map: MEConfigurationMap(name: name, files: files)))
        }
        return loaded
    }

    private static func readCondition(
        _ file: MapFile, nameAt: Int, valueAt: Int, enabled: Bool
    ) throws -> MEConfigurationMap.Condition? {
        guard enabled, let name = try file.string(try file.u32(nameAt)) else {
            return nil
        }
        let value = Int(Int32(bitPattern: try file.u32(valueAt)))
        return MEConfigurationMap.Condition(name: name, value: value)
    }
}

// The generated maps were `MEConfigurationMap.csme15` and the like; the names
// stay, so `forME` and the tests read them the same way. A missing or stale
// resource stops a test with the reader's own reason rather than a mystery
// about empty maps.
public extension MEConfigurationMap {
    static var csme11: MEConfigurationMap { MEConfigurationData.required("csme11") }
    static var csme12: MEConfigurationMap { MEConfigurationData.required("csme12") }
    static var csme12Desktop: MEConfigurationMap {
        MEConfigurationData.required("csme12Desktop")
    }
    static var csme13: MEConfigurationMap { MEConfigurationData.required("csme13") }
    static var csme13Desktop: MEConfigurationMap {
        MEConfigurationData.required("csme13Desktop")
    }
    static var csme14: MEConfigurationMap { MEConfigurationData.required("csme14") }
    static var csme14Desktop: MEConfigurationMap {
        MEConfigurationData.required("csme14Desktop")
    }
    static var csme15: MEConfigurationMap { MEConfigurationData.required("csme15") }
    static var csme15Desktop: MEConfigurationMap {
        MEConfigurationData.required("csme15Desktop")
    }
    static var csme18: MEConfigurationMap { MEConfigurationData.required("csme18") }
}
