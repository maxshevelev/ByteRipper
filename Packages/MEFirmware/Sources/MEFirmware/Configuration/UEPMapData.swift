import Foundation
import MapData

/// One generation's UEP layout as the binary states it: the identifier the
/// code asks for and the map itself.
struct LoadedUEPMap: Sendable {
    var id: String
    var map: UEPMap
}

/// The UEP layouts read from `UEPMaps.bin`.
///
/// The file is generated from the JSON under
/// `Packages/MEFirmware/MapSources/uep` and committed (`Design/MAP_DATA.md`).
/// Its header carries a version the code was marked with too
/// (`UEPMapDataVersion`); a file whose version differs is refused before a
/// section is read.
enum UEPMapData {
    static let formatVersion = UEPMapDataVersion.formatVersion
    static let expectedVersion = UEPMapDataVersion.version

    private static let loaded: Result<[LoadedUEPMap], MapDataError> = {
        guard let url = resourceURL else {
            return .failure(.resourceMissing("UEPMaps.bin"))
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
        Bundle.module.url(forResource: "UEPMaps", withExtension: "bin",
                          subdirectory: "UEPMaps")
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

    static func map(id: String) -> UEPMap? {
        guard case .success(let maps) = loaded else { return nil }
        return maps.first { $0.id == id }?.map
    }

    /// The map a test or `forME` names, or a message naming the resource
    /// problem. Production code asks `map(id:)` and lives without the map.
    static func required(_ id: String) -> UEPMap {
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
    private static let settingRecordSize = 32
    private static let optionRecordSize = 8

    private static let hasLabel: UInt16 = 1
    private static let hasSection: UInt16 = 2
    private static let hasHelp: UInt16 = 4
    private static let hasOptions: UInt16 = 8

    static func decode(_ data: Data) throws -> [LoadedUEPMap] {
        let file = try MapFile(data: data, expectedVersion: expectedVersion)
        guard file.kind == .uep else {
            throw MapDataError.wrongKind(file.kind.rawValue)
        }
        let mapsSection = try file.requireSection(.maps)
        let settingsSection = try file.requireSection(.settings)
        let optionsSection = file.section(.options)

        let count = Int(try file.u32(mapsSection.offset))
        let mapsAt = try file.records(mapsSection, offset: 4, count: count,
                                      size: mapRecordSize, name: "map")
        var loaded: [LoadedUEPMap] = []
        loaded.reserveCapacity(count)
        for index in 0..<count {
            let at = mapsAt + index * mapRecordSize
            let id = try file.string(try file.u32(at)) ?? ""
            let name = try file.string(try file.u32(at + 4)) ?? ""
            let arrayStart = Int(try file.u16(at + 8))
            let arraySize = Int(try file.u16(at + 10))
            let settingCount = Int(try file.u32(at + 12))
            let settingsOffset = Int(try file.u32(at + 16))
            let settingsAt = try file.records(
                settingsSection, offset: settingsOffset, count: settingCount,
                size: settingRecordSize, name: "setting")
            var settings: [UEPMap.Setting] = []
            settings.reserveCapacity(settingCount)
            for settingIndex in 0..<settingCount {
                let settingAt = settingsAt + settingIndex * settingRecordSize
                let settingName = try file.string(try file.u32(settingAt)) ?? ""
                let flags = try file.u16(settingAt + 4)
                let array = Int(try file.u16(settingAt + 6))
                let offset = Int(try file.u16(settingAt + 8))
                let bit = Int(file.bytes[settingAt + 10])
                let bits = Int(file.bytes[settingAt + 11])
                guard bits > 0, bit + bits <= 64 else {
                    throw MapDataError.corrupt(
                        "\(id): \(settingName) bits \(bit)…\(bit + bits - 1)")
                }
                let label = flags & hasLabel != 0
                    ? try file.string(try file.u32(settingAt + 12)) : nil
                let section = flags & hasSection != 0
                    ? try file.string(try file.u32(settingAt + 16)) : nil
                let help = flags & hasHelp != 0
                    ? try file.string(try file.u32(settingAt + 20)) : nil
                var options: [Int: String] = [:]
                if flags & hasOptions != 0, let optionsSection = optionsSection {
                    let optionCount = Int(try file.u16(settingAt + 28))
                    let optionsAt = try file.records(
                        optionsSection, offset: Int(try file.u32(settingAt + 24)),
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
                settings.append(UEPMap.Setting(
                    name: settingName,
                    placement: .init(array: array, offset: offset,
                                     bit: bit, count: bits),
                    label: label, section: section, help: help,
                    options: options.isEmpty ? nil : options))
            }
            loaded.append(LoadedUEPMap(
                id: id,
                map: UEPMap(name: name, settings: settings,
                            arrayStart: arrayStart, arraySize: arraySize)))
        }
        return loaded
    }
}

// The generated maps were `UEPMap.csme12` and the like; the names stay, so
// `forME` and the tests read them the same way. A missing or stale resource
// stops a test with the reader's own reason rather than a mystery about empty
// maps.
public extension UEPMap {
    static var csme12: UEPMap { UEPMapData.required("csme12") }
    static var csme13: UEPMap { UEPMapData.required("csme13") }
    static var csme14: UEPMap { UEPMapData.required("csme14") }
    static var csme15: UEPMap { UEPMapData.required("csme15") }
    static var csme16: UEPMap { UEPMapData.required("csme16") }
    static var csme18: UEPMap { UEPMapData.required("csme18") }
}
