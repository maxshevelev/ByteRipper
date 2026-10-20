import Foundation
import MapData

/// The reader's errors are the envelope's: a missing resource, a bad magic, a
/// format or version the code was not marked for, or a corrupt file.
public typealias MapDataError = MapData.MapDataError

/// One map as the binary states it: the identifier the code asks for, the set
/// it belongs to (PCH, SPT, CPU) and the table itself.
struct LoadedStrapMap: Sendable {
    var id: String
    var set: UInt16
    var map: DescriptorStrapMap
}

/// The strap tables read from `StrapMaps.bin`.
///
/// The file is generated from the JSON under
/// `Packages/UEFIImage/MapSources/strap` and committed (`Design/MAP_DATA.md`).
/// Its header carries a version that the code was marked with too
/// (`StrapMapDataVersion`); a file whose version differs is refused before a
/// section is read, so a stale resource can never be mistaken for a changed
/// layout.
enum StrapMapData {
    static let formatVersion = StrapMapDataVersion.formatVersion
    static let expectedVersion = StrapMapDataVersion.version

    private static let loaded: Result<[LoadedStrapMap], MapDataError> = {
        guard let url = resourceURL else {
            return .failure(.resourceMissing("StrapMaps.bin"))
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
        Bundle.module.url(forResource: "StrapMaps", withExtension: "bin",
                          subdirectory: "StrapMaps")
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

    /// The PCH tables, in the order the source states them.
    static var pchMaps: [DescriptorStrapMap] {
        maps(in: 0)
    }

    /// FIT 11's SPT spellings, a set of their own: a length can mean two
    /// different sections in the two sets.
    static var sptMaps: [DescriptorStrapMap] {
        maps(in: 1)
    }

    static func map(id: String) -> DescriptorStrapMap? {
        guard case .success(let maps) = loaded else { return nil }
        return maps.first { $0.id == id }?.map
    }

    /// The map a test or a table names, or a message naming the resource
    /// problem. Production code asks `map(id:)` and lives without the table.
    static func required(_ id: String) -> DescriptorStrapMap {
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

    private static func maps(in set: UInt16) -> [DescriptorStrapMap] {
        guard case .success(let maps) = loaded else { return [] }
        return maps.filter { $0.set == set }.map(\.map)
    }

    // MARK: - Reading

    private static let mapRecordSize = 24
    private static let fieldRecordSize = 28
    private static let optionRecordSize = 8

    static func decode(_ data: Data) throws -> [LoadedStrapMap] {
        let file = try MapFile(data: data, expectedVersion: expectedVersion)
        guard file.kind == .strap else {
            throw MapDataError.wrongKind(file.kind.rawValue)
        }
        let mapsSection = try file.requireSection(.maps)
        let fieldsSection = try file.requireSection(.fields)
        let optionsSection = file.section(.options)

        let count = Int(try file.u32(mapsSection.offset))
        let mapsAt = try file.records(mapsSection, offset: 4, count: count,
                                      size: mapRecordSize, name: "map")
        var loaded: [LoadedStrapMap] = []
        for index in 0..<count {
            let at = mapsAt + index * mapRecordSize
            let id = try file.string(try file.u32(at)) ?? ""
            let name = try file.string(try file.u32(at + 4)) ?? ""
            let words = Int(try file.u16(at + 8))
            let set = try file.u16(at + 10)
            let fieldCount = Int(try file.u32(at + 12))
            let fieldsOffset = Int(try file.u32(at + 16))
            guard words > 0 else {
                throw MapDataError.corrupt("map \(id) states no words")
            }
            let fieldsAt = try file.records(fieldsSection, offset: fieldsOffset,
                                            count: fieldCount,
                                            size: fieldRecordSize,
                                            name: "field")
            var fields: [DescriptorStrapMap.Field] = []
            fields.reserveCapacity(fieldCount)
            for fieldIndex in 0..<fieldCount {
                let fieldAt = fieldsAt + fieldIndex * fieldRecordSize
                let name = try file.string(try file.u32(fieldAt)) ?? ""
                let word = Int(try file.u16(fieldAt + 4))
                let low = Int(file.bytes[fieldAt + 6])
                let high = Int(file.bytes[fieldAt + 7])
                let flags = try file.u16(fieldAt + 8)
                let defaultWord = try file.u32(fieldAt + 10)
                let label = try file.string(try file.u32(fieldAt + 14))
                let optionsOffset = try file.u32(fieldAt + 18)
                let optionCount = Int(try file.u16(fieldAt + 22))
                guard word < words, low <= high, high < 32 else {
                    throw MapDataError.corrupt(
                        "\(id): \(name) at word \(word), bits \(low)…\(high)")
                }
                var fieldOptions: [Int: String] = [:]
                if flags & 2 != 0, let optionsSection = optionsSection {
                    guard optionsOffset != MapFile.noReference else {
                        throw MapDataError.corrupt("\(id): \(name) has no options")
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
                let field = DescriptorStrapMap.Field(
                    name: name, word: word, bits: low...high,
                    defaultValue: flags & 1 != 0 ? defaultWord : nil,
                    label: label,
                    options: fieldOptions.isEmpty ? nil : fieldOptions)
                fields.append(field)
            }
            loaded.append(LoadedStrapMap(
                id: id, set: set,
                map: DescriptorStrapMap(name: name, words: words, fields: fields)))
        }
        return loaded
    }
}

// The generated tables were `DescriptorStrapMap.pch69` and the like; the
// names stay, so tests and the table selection read them the same way. A
// missing or stale resource stops a test with the reader's own reason rather
// than a mystery about empty tables.
public extension DescriptorStrapMap {
    static var pch69: DescriptorStrapMap { StrapMapData.required("pch69") }
    static var pch70: DescriptorStrapMap { StrapMapData.required("pch70") }
    static var pch74: DescriptorStrapMap { StrapMapData.required("pch74") }
    static var pch90: DescriptorStrapMap { StrapMapData.required("pch90") }
    static var pch101: DescriptorStrapMap { StrapMapData.required("pch101") }
    static var pch114: DescriptorStrapMap { StrapMapData.required("pch114") }
    static var pch115: DescriptorStrapMap { StrapMapData.required("pch115") }
    static var pch130: DescriptorStrapMap { StrapMapData.required("pch130") }
    static var sptPch66: DescriptorStrapMap { StrapMapData.required("sptPch66") }
    static var sptPch88: DescriptorStrapMap { StrapMapData.required("sptPch88") }
    static var sptPch90: DescriptorStrapMap { StrapMapData.required("sptPch90") }
    static var sptPch139: DescriptorStrapMap { StrapMapData.required("sptPch139") }
}
