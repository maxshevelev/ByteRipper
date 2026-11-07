import Foundation
import MapData

/// One generation's GPIO pin dictionary as the binary states it: the
/// identifier the code asks for and the map itself.
struct LoadedGPIOPinMap: Sendable {
    var id: String
    var map: GPIOPinMap
}

/// The GPIO pin dictionaries read from `GPIOMaps.bin`.
///
/// The file is generated from the JSON under
/// `Packages/MEFirmware/MapSources/gpio` and committed (`Design/MAP_DATA.md`).
/// Its header carries a version the code was marked with too
/// (`GPIOPinMapDataVersion`); a file whose version differs is refused before a
/// section is read.
enum GPIOPinMapData {
    static let formatVersion = GPIOPinMapDataVersion.formatVersion
    static let expectedVersion = GPIOPinMapDataVersion.version

    private static let loaded: Result<[LoadedGPIOPinMap], MapDataError> = {
        guard let url = resourceURL else {
            return .failure(.resourceMissing("GPIOMaps.bin"))
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
        Bundle.module.url(forResource: "GPIOMaps", withExtension: "bin",
                          subdirectory: "GPIOMaps")
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

    static func map(id: String) -> GPIOPinMap? {
        guard case .success(let maps) = loaded else { return nil }
        return maps.first { $0.id == id }?.map
    }

    /// The map a test or `forME` names, or a message naming the resource
    /// problem. Production code asks `map(id:)` and lives without the map.
    static func required(_ id: String) -> GPIOPinMap {
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

    private static let mapRecordSize = 40
    private static let optionRecordSize = 8

    /// The five dictionaries in the record's order, with the property each
    /// fills.
    private static let dictionaryNames = ["features", "usages", "ownerships",
                                          "padModes", "groups"]

    static func decode(_ data: Data) throws -> [LoadedGPIOPinMap] {
        let file = try MapFile(data: data, expectedVersion: expectedVersion)
        guard file.kind == .gpio else {
            throw MapDataError.wrongKind(file.kind.rawValue)
        }
        let mapsSection = try file.requireSection(.maps)
        let optionsSection = file.section(.options)

        let count = Int(try file.u32(mapsSection.offset))
        let mapsAt = try file.records(mapsSection, offset: 4, count: count,
                                      size: mapRecordSize, name: "map")
        var loaded: [LoadedGPIOPinMap] = []
        loaded.reserveCapacity(count)
        for index in 0..<count {
            let at = mapsAt + index * mapRecordSize
            let id = try file.string(try file.u32(at)) ?? ""
            let name = try file.string(try file.u32(at + 4)) ?? ""
            var dictionaries: [[Int: String]] = []
            for dictionary in 0..<dictionaryNames.count {
                let offset = Int(try file.u32(at + 8 + dictionary * 4))
                let entries = Int(try file.u16(at + 28 + dictionary * 2))
                dictionaries.append(try readDictionary(
                    file, optionsSection, id: id,
                    name: dictionaryNames[dictionary],
                    offset: offset, count: entries))
            }
            loaded.append(LoadedGPIOPinMap(
                id: id,
                map: GPIOPinMap(name: name,
                                features: dictionaries[0],
                                usages: dictionaries[1],
                                ownerships: dictionaries[2],
                                padModes: dictionaries[3],
                                groups: dictionaries[4])))
        }
        return loaded
    }

    private static func readDictionary(
        _ file: MapFile, _ section: MapFile.Section?, id: String,
        name: String, offset: Int, count: Int
    ) throws -> [Int: String] {
        guard count > 0 else { return [:] }
        guard let section = section,
              offset != Int(MapFile.noReference) else {
            throw MapDataError.corrupt(
                "\(id): \(name) has \(count) entries and no section")
        }
        let entriesAt = try file.records(section, offset: offset, count: count,
                                         size: optionRecordSize, name: name)
        var entries: [Int: String] = [:]
        entries.reserveCapacity(count)
        for index in 0..<count {
            let at = entriesAt + index * optionRecordSize
            let number = Int(try file.u16(at))
            if let text = try file.string(try file.u32(at + 4)) {
                entries[number] = text
            }
        }
        return entries
    }
}

// The generated maps were `GPIOPinMap.csme11` and the like; the names stay, so
// `forME` and the tests read them the same way. A missing or stale resource
// stops a test with the reader's own reason rather than a mystery about empty
// maps.
public extension GPIOPinMap {
    static var csme11: GPIOPinMap { GPIOPinMapData.required("csme11") }
    static var csme12: GPIOPinMap { GPIOPinMapData.required("csme12") }
    static var csme13: GPIOPinMap { GPIOPinMapData.required("csme13") }
    static var csme14: GPIOPinMap { GPIOPinMapData.required("csme14") }
    static var csme15: GPIOPinMap { GPIOPinMapData.required("csme15") }
}
