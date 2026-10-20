import Foundation
import MapData

/// One generation's register map as the binary states it.
struct LoadedRegisterMap: Sendable {
    var id: String
    var map: DescriptorRegisterMap
}

/// The descriptor's register maps read from `RegisterMaps.bin`.
///
/// The file is generated from the JSON under
/// `Packages/UEFIImage/MapSources/register` and committed
/// (`Design/MAP_DATA.md`). Its header carries a version the code was marked
/// with too (`DescriptorRegisterMapDataVersion`); a file whose version differs
/// is refused before a section is read.
enum DescriptorRegisterMapData {
    static let formatVersion = DescriptorRegisterMapDataVersion.formatVersion
    static let expectedVersion = DescriptorRegisterMapDataVersion.version

    private static let loaded: Result<[LoadedRegisterMap], MapDataError> = {
        guard let url = resourceURL else {
            return .failure(.resourceMissing("RegisterMaps.bin"))
        }
        do {
            return .success(try decode(Data(contentsOf: url)))
        } catch let error as MapDataError {
            return .failure(error)
        } catch {
            return .failure(.corrupt(error.localizedDescription))
        }
    }()

    /// The committed resource, for the tests that mutate a copy.
    static var resourceURL: URL? {
        Bundle.module.url(forResource: "RegisterMaps", withExtension: "bin",
                          subdirectory: "RegisterMaps")
    }

    /// The committed bytes, for a test to damage a copy of.
    static var bundledData: Data? {
        resourceURL.flatMap { try? Data(contentsOf: $0) }
    }

    /// What went wrong, for the tests. Nil when the resource loaded.
    static var failure: MapDataError? {
        if case .failure(let error) = loaded { return error }
        return nil
    }

    static func map(id: String) -> DescriptorRegisterMap? {
        guard case .success(let maps) = loaded else { return nil }
        return maps.first { $0.id == id }?.map
    }

    /// The map a test or `forGeneration` names, or a message naming the
    /// resource problem. Production code asks `map(id:)`.
    static func required(_ id: String) -> DescriptorRegisterMap {
        switch loaded {
        case .success(let maps):
            guard let map = maps.first(where: { $0.id == id })?.map else {
                preconditionFailure("the register map resource has no \(id)")
            }
            return map
        case .failure(let error):
            preconditionFailure("the register map resource: \(error)")
        }
    }

    // MARK: - Reading

    private static let mapRecordSize = 20
    private static let registerRecordSize = 24
    private static let fieldRecordSize = 28
    private static let optionRecordSize = 8

    static func decode(_ data: Data) throws -> [LoadedRegisterMap] {
        let file = try MapFile(data: data, expectedVersion: expectedVersion)
        guard file.kind == .register else {
            throw MapDataError.wrongKind(file.kind.rawValue)
        }
        let mapsSection = try file.requireSection(.maps)
        let registersSection = try file.requireSection(.registers)
        let fieldsSection = try file.requireSection(.fields)
        let optionsSection = file.section(.options)

        let count = Int(try file.u32(mapsSection.offset))
        let mapsAt = try file.records(mapsSection, offset: 4, count: count,
                                      size: mapRecordSize, name: "map")
        var loaded: [LoadedRegisterMap] = []
        loaded.reserveCapacity(count)
        for index in 0..<count {
            let at = mapsAt + index * mapRecordSize
            let id = try file.string(try file.u32(at)) ?? ""
            let registerCount = Int(try file.u32(at + 4))
            let registersOffset = Int(try file.u32(at + 8))
            let registersAt = try file.records(
                registersSection, offset: registersOffset,
                count: registerCount, size: registerRecordSize,
                name: "register")
            var registers: [DescriptorRegisterMap.Register] = []
            registers.reserveCapacity(registerCount)
            for registerIndex in 0..<registerCount {
                let registerAt = registersAt + registerIndex * registerRecordSize
                let name = try file.string(try file.u32(registerAt)) ?? ""
                let placeKind = try file.u16(registerAt + 4)
                let placeOffset = Int(try file.u32(registerAt + 8))
                let words = Int(try file.u16(registerAt + 12))
                let fieldCount = Int(try file.u16(registerAt + 14))
                let fieldsOffset = Int(try file.u32(registerAt + 16))
                guard words > 0 else {
                    throw MapDataError.corrupt(
                        "\(id): \(name) states no words")
                }
                let place: DescriptorRegisterMap.Place
                switch placeKind {
                case 0: place = .absolute(placeOffset)
                case 1: place = .flashComponent(offset: placeOffset)
                case 2: place = .flashMaster(offset: placeOffset)
                default:
                    throw MapDataError.corrupt(
                        "\(id): \(name) has place kind \(placeKind)")
                }
                let fieldsAt = try file.records(
                    fieldsSection, offset: fieldsOffset, count: fieldCount,
                    size: fieldRecordSize, name: "field")
                var fields: [DescriptorRegisterMap.Field] = []
                fields.reserveCapacity(fieldCount)
                for fieldIndex in 0..<fieldCount {
                    let fieldAt = fieldsAt + fieldIndex * fieldRecordSize
                    let fieldName = try file.string(try file.u32(fieldAt)) ?? ""
                    let word = Int(try file.u16(fieldAt + 4))
                    let low = Int(file.bytes[fieldAt + 6])
                    let high = Int(file.bytes[fieldAt + 7])
                    let flags = try file.u16(fieldAt + 8)
                    let label = try file.string(try file.u32(fieldAt + 14))
                    let optionsOffset = try file.u32(fieldAt + 18)
                    let optionCount = Int(try file.u16(fieldAt + 22))
                    guard word < words, low <= high, high < 32 else {
                        throw MapDataError.corrupt(
                            "\(id): \(fieldName) at word \(word), bits \(low)…\(high)")
                    }
                    var fieldOptions: [Int: String] = [:]
                    if flags & 2 != 0, let optionsSection = optionsSection {
                        guard optionsOffset != MapFile.noReference else {
                            throw MapDataError.corrupt(
                                "\(id): \(fieldName) has no options")
                        }
                        let optionsAt = try file.records(
                            optionsSection, offset: Int(optionsOffset),
                            count: optionCount, size: optionRecordSize,
                            name: "option")
                        for optionIndex in 0..<optionCount {
                            let optionAt = optionsAt + optionIndex * optionRecordSize
                            let value = Int(try file.u16(optionAt))
                            if let text = try file.string(try file.u32(optionAt + 4)) {
                                fieldOptions[value] = text
                            }
                        }
                    }
                    fields.append(DescriptorRegisterMap.Field(
                        name: fieldName,
                        bitOffset: word * 32 + low,
                        count: high - low + 1,
                        label: label,
                        options: fieldOptions.isEmpty ? nil : fieldOptions))
                }
                registers.append(DescriptorRegisterMap.Register(
                    name: name, place: place, words: words, fields: fields))
            }
            loaded.append(LoadedRegisterMap(
                id: id, map: DescriptorRegisterMap(registers: registers)))
        }
        return loaded
    }
}

// The generated maps were `DescriptorRegisterMap.sunrisePoint` and the like;
// the names stay, so `forGeneration` and the tests read them the same way. A
// missing or stale resource stops a test with the reader's own reason rather
// than a mystery about empty maps.
public extension DescriptorRegisterMap {
    static var sunrisePoint: DescriptorRegisterMap {
        DescriptorRegisterMapData.required("sunrisePoint")
    }
    static var cannonPoint: DescriptorRegisterMap {
        DescriptorRegisterMapData.required("cannonPoint")
    }
    static var tigerPoint: DescriptorRegisterMap {
        DescriptorRegisterMapData.required("tigerPoint")
    }
    static var elkhartLake: DescriptorRegisterMap {
        DescriptorRegisterMapData.required("elkhartLake")
    }
    static var jasperLake: DescriptorRegisterMap {
        DescriptorRegisterMapData.required("jasperLake")
    }
    static var csme18: DescriptorRegisterMap {
        DescriptorRegisterMapData.required("csme18")
    }
}
