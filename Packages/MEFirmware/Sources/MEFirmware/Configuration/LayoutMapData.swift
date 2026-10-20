import Foundation
import MapData

/// One CSME 18 layout as the binary states it, before it is turned into the
/// model its reader asks for.
struct LoadedLayoutMap: Sendable {
    struct Field: Sendable {
        var name: String
        var offset: Int
        var bit: Int
        var count: Int
        var label: String?
        var section: String?
        var help: String?
        var options: [Int: String]?
    }

    struct Container: Sendable {
        var name: String
        var blockType: Int
        var blockLength: Int
        var offset: Int
        var length: Int
        var fields: [Field]
    }

    struct Anchor: Sendable {
        var name: String
        var bitOffset: Int
        var count: Int
        var value: Int
    }

    var id: String
    var name: String
    var layout: UInt16
    var containers: [Container]
    var anchors: [Anchor]
    var fields: [Field]
}

/// The CSME 18 container, CPU-message and SPHY layouts read from
/// `LayoutMaps.bin`.
///
/// The file is generated from the JSON under
/// `Packages/MEFirmware/MapSources/layout` and committed
/// (`Design/MAP_DATA.md`). Its header carries a version the code was marked
/// with too (`LayoutMapDataVersion`); a file whose version differs is refused
/// before a section is read.
enum LayoutMapData {
    static let formatVersion = LayoutMapDataVersion.formatVersion
    static let expectedVersion = LayoutMapDataVersion.version

    private static let layoutMIP: UInt16 = 0
    private static let layoutCPU: UInt16 = 1
    private static let layoutSPHY: UInt16 = 2

    private static let loaded: Result<[LoadedLayoutMap], MapDataError> = {
        guard let url = resourceURL else {
            return .failure(.resourceMissing("LayoutMaps.bin"))
        }
        do {
            return .success(try decode(Data(contentsOf: url)))
        } catch let error as MapDataError {
            return .failure(error)
        } catch {
            return .failure(.corrupt(error.localizedDescription))
        }
    }()

    static var resourceURL: URL? {
        Bundle.module.url(forResource: "LayoutMaps", withExtension: "bin",
                          subdirectory: "LayoutMaps")
    }

    static var bundledData: Data? {
        resourceURL.flatMap { try? Data(contentsOf: $0) }
    }

    static var failure: MapDataError? {
        if case .failure(let error) = loaded { return error }
        return nil
    }

    private static func map(id: String, layout: UInt16) -> LoadedLayoutMap? {
        guard case .success(let maps) = loaded,
              let map = maps.first(where: { $0.id == id }) else { return nil }
        return map.layout == layout ? map : nil
    }

    static func mipStrapMap(id: String) -> MIPStrapMap? {
        guard let map = map(id: id, layout: layoutMIP) else { return nil }
        return MIPStrapMap(
            name: map.name,
            containers: map.containers.map { container in
                MIPStrapMap.Container(
                    name: container.name,
                    blockType: container.blockType,
                    blockLength: container.blockLength,
                    offset: container.offset,
                    length: container.length,
                    fields: container.fields.map { field in
                        MIPStrapMap.Field(
                            name: field.name, bitOffset: field.offset,
                            count: field.count, label: field.label,
                            section: field.section, help: field.help,
                            options: field.options)
                    })
            })
    }

    static func cpuStrapMap(id: String) -> CPUStrapMap? {
        guard let map = map(id: id, layout: layoutCPU) else { return nil }
        return CPUStrapMap(
            name: map.name,
            fields: map.fields.map { field in
                CPUStrapMap.Field(
                    name: field.name, offset: field.offset, bit: field.bit,
                    count: field.count, label: field.label,
                    section: field.section, help: field.help,
                    options: field.options)
            })
    }

    static func sphyNvarMap(id: String) -> SphyNvarMap? {
        guard let map = map(id: id, layout: layoutSPHY) else { return nil }
        return SphyNvarMap(
            name: map.name,
            anchors: map.anchors.map { anchor in
                SphyNvarMap.Anchor(
                    name: anchor.name, bitOffset: anchor.bitOffset,
                    count: anchor.count, value: anchor.value)
            },
            fields: map.fields.map { field in
                SphyNvarMap.Field(name: field.name, bitOffset: field.offset,
                                  count: field.count)
            })
    }

    static func requiredMIP(_ id: String) -> MIPStrapMap {
        guard let map = mipStrapMap(id: id) else {
            preconditionFailure("the layout resource has no MIP map \(id)")
        }
        return map
    }

    static func requiredCPU(_ id: String) -> CPUStrapMap {
        guard let map = cpuStrapMap(id: id) else {
            preconditionFailure("the layout resource has no CPU map \(id)")
        }
        return map
    }

    static func requiredSPHY(_ id: String) -> SphyNvarMap {
        guard let map = sphyNvarMap(id: id) else {
            preconditionFailure("the layout resource has no SPHY map \(id)")
        }
        return map
    }

    // MARK: - Reading

    private static let mapRecordSize = 40
    private static let containerRecordSize = 28
    private static let anchorRecordSize = 16
    private static let fieldRecordSize = 36
    private static let optionRecordSize = 8

    private static let hasLabel: UInt16 = 1
    private static let hasSection: UInt16 = 2
    private static let hasHelp: UInt16 = 4
    private static let hasOptions: UInt16 = 8

    static func decode(_ data: Data) throws -> [LoadedLayoutMap] {
        let file = try MapFile(data: data, expectedVersion: expectedVersion)
        guard file.kind == .layout else {
            throw MapDataError.wrongKind(file.kind.rawValue)
        }
        let mapsSection = try file.requireSection(.maps)
        let fieldsSection = try file.requireSection(.layoutFields)
        let optionsSection = file.section(.options)
        let containersSection = file.section(.containers)
        let anchorsSection = file.section(.anchors)

        func fields(offset: Int, count: Int, name: String) throws
            -> [LoadedLayoutMap.Field] {
            guard count > 0 else { return [] }
            let start = try file.records(fieldsSection, offset: offset,
                                         count: count, size: fieldRecordSize,
                                         name: name)
            var result: [LoadedLayoutMap.Field] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                let at = start + index * fieldRecordSize
                let fieldName = try file.string(try file.u32(at)) ?? ""
                let fieldOffset = Int(try file.u32(at + 4))
                let bit = Int(try file.u16(at + 8))
                let bits = Int(try file.u16(at + 10))
                let flags = try file.u16(at + 12)
                guard bits > 0, bits <= 32 else {
                    throw MapDataError.corrupt(
                        "\(fieldName) states \(bits) bits")
                }
                let label = flags & hasLabel != 0
                    ? try file.string(try file.u32(at + 16)) : nil
                let section = flags & hasSection != 0
                    ? try file.string(try file.u32(at + 20)) : nil
                let help = flags & hasHelp != 0
                    ? try file.string(try file.u32(at + 24)) : nil
                var options: [Int: String] = [:]
                if flags & hasOptions != 0, let optionsSection = optionsSection {
                    let optionCount = Int(try file.u16(at + 32))
                    let optionsAt = try file.records(
                        optionsSection, offset: Int(try file.u32(at + 28)),
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
                result.append(LoadedLayoutMap.Field(
                    name: fieldName, offset: fieldOffset, bit: bit,
                    count: bits, label: label, section: section, help: help,
                    options: options.isEmpty ? nil : options))
            }
            return result
        }

        let count = Int(try file.u32(mapsSection.offset))
        let mapsAt = try file.records(mapsSection, offset: 4, count: count,
                                      size: mapRecordSize, name: "map")
        var loaded: [LoadedLayoutMap] = []
        loaded.reserveCapacity(count)
        for index in 0..<count {
            let at = mapsAt + index * mapRecordSize
            let id = try file.string(try file.u32(at)) ?? ""
            let name = try file.string(try file.u32(at + 4)) ?? ""
            let layout = try file.u16(at + 8)
            guard [layoutMIP, layoutCPU, layoutSPHY].contains(layout) else {
                throw MapDataError.corrupt("\(id) has layout \(layout)")
            }
            let containerCount = Int(try file.u32(at + 12))
            let containerOffset = Int(try file.u32(at + 16))
            let anchorCount = Int(try file.u32(at + 20))
            let anchorOffset = Int(try file.u32(at + 24))
            let fieldCount = Int(try file.u32(at + 28))
            let fieldOffset = Int(try file.u32(at + 32))

            var containers: [LoadedLayoutMap.Container] = []
            if containerCount > 0 {
                guard let containersSection = containersSection else {
                    throw MapDataError.corrupt("\(id) has no containers section")
                }
                let containersAt = try file.records(
                    containersSection, offset: containerOffset,
                    count: containerCount, size: containerRecordSize,
                    name: "container")
                for containerIndex in 0..<containerCount {
                    let cat = containersAt + containerIndex * containerRecordSize
                    let containerName = try file.string(try file.u32(cat)) ?? ""
                    let blockType = Int(try file.u16(cat + 4))
                    let blockLength = Int(try file.u32(cat + 8))
                    let offset = Int(try file.u32(cat + 12))
                    let length = Int(try file.u32(cat + 16))
                    let containerFields = Int(try file.u32(cat + 20))
                    let fieldsOffset = Int(try file.u32(cat + 24))
                    guard blockLength > 0, offset >= 0, length > 0,
                          offset + length <= blockLength else {
                        throw MapDataError.corrupt(
                            "\(id): \(containerName) is not a container")
                    }
                    containers.append(LoadedLayoutMap.Container(
                        name: containerName, blockType: blockType,
                        blockLength: blockLength, offset: offset,
                        length: length,
                        fields: try fields(offset: fieldsOffset,
                                           count: containerFields,
                                           name: "container field")))
                }
            }
            var anchors: [LoadedLayoutMap.Anchor] = []
            if anchorCount > 0 {
                guard let anchorsSection = anchorsSection else {
                    throw MapDataError.corrupt("\(id) has no anchors section")
                }
                let anchorsAt = try file.records(
                    anchorsSection, offset: anchorOffset, count: anchorCount,
                    size: anchorRecordSize, name: "anchor")
                for anchorIndex in 0..<anchorCount {
                    let aat = anchorsAt + anchorIndex * anchorRecordSize
                    let anchorName = try file.string(try file.u32(aat)) ?? ""
                    let bitOffset = Int(try file.u32(aat + 4))
                    let anchorBits = Int(try file.u16(aat + 8))
                    let value = Int(try file.u32(aat + 12))
                    guard anchorBits > 0, anchorBits <= 32 else {
                        throw MapDataError.corrupt(
                            "\(id): anchor \(anchorName) has \(anchorBits) bits")
                    }
                    anchors.append(LoadedLayoutMap.Anchor(
                        name: anchorName, bitOffset: bitOffset,
                        count: anchorBits, value: value))
                }
            }
            loaded.append(LoadedLayoutMap(
                id: id, name: name, layout: layout, containers: containers,
                anchors: anchors,
                fields: try fields(offset: fieldOffset, count: fieldCount,
                                   name: "field")))
        }
        return loaded
    }
}

// The generated maps were `MIPStrapMap.csme18`, `CPUStrapMap.csme18` and
// `SphyNvarMap.csme18`; the names stay, so `forME` and the tests read them
// the same way.
public extension MIPStrapMap {
    static var csme18: MIPStrapMap { LayoutMapData.requiredMIP("csme18-mip") }
}

public extension CPUStrapMap {
    static var csme18: CPUStrapMap { LayoutMapData.requiredCPU("csme18-cpu") }
}

public extension SphyNvarMap {
    static var csme18: SphyNvarMap { LayoutMapData.requiredSPHY("csme18-sphy") }
}
