import Foundation

/// Why the binary strap tables could not be used. The reader reports this
/// rather than interpreting bytes whose layout it cannot trust: a stale
/// resource and a corrupt one both mean "no table", which the panel already
/// knows how to show — the words as numbers.
public enum MapDataError: Error, CustomStringConvertible, Equatable {
    case resourceMissing(String)
    case badMagic
    case unsupportedFormat(UInt16)
    case versionMismatch(file: UInt32, code: UInt32)
    case corrupt(String)

    public var description: String {
        switch self {
        case .resourceMissing(let name):
            return "the map resource \(name) is not in the bundle"
        case .badMagic:
            return "the map resource is not a BRM1 file"
        case .unsupportedFormat(let version):
            return "the map resource is format \(version); this code reads "
                + "\(StrapMapDataVersion.formatVersion)"
        case .versionMismatch(let file, let code):
            return "the map resource is version \(file); this code was marked "
                + "with version \(code)"
        case .corrupt(let reason):
            return "the map resource is corrupt: \(reason)"
        }
    }
}

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
/// `Packages/UEFIImage/MapSources/strap` and committed
/// (`Design/UEFI/STRAP_MAP_DATA.md`). Its header carries a version that the
/// code was marked with too (`StrapMapDataVersion`); a file whose version
/// differs is refused before a section is read, so a stale resource can never
/// be mistaken for a changed layout.
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

    private enum Section: UInt16 {
        case strings = 1, maps = 2, fields = 3, options = 4
    }

    private static let noReference = 0xFFFF_FFFF
    private static let mapRecordSize = 24
    private static let fieldRecordSize = 28
    private static let optionRecordSize = 8

    static func decode(_ data: Data) throws -> [LoadedStrapMap] {
        guard data.count >= 32 else { throw MapDataError.corrupt("short header") }
        let bytes = [UInt8](data)
        func u16(_ at: Int) throws -> UInt16 {
            guard at >= 0, at + 2 <= bytes.count else {
                throw MapDataError.corrupt("a 16-bit read at \(at) is outside the file")
            }
            return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at + 4 <= bytes.count else {
                throw MapDataError.corrupt("a 32-bit read at \(at) is outside the file")
            }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
                | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        func utf8(_ offset: Int, _ length: Int) throws -> String {
            guard offset >= 0, length >= 0, offset + length <= bytes.count,
                  let text = String(bytes: bytes[offset..<offset + length], encoding: .utf8)
            else { throw MapDataError.corrupt("a string is not UTF-8 at \(offset)") }
            return text
        }

        guard bytes[0] == UInt8(ascii: "B"), bytes[1] == UInt8(ascii: "R"),
              bytes[2] == UInt8(ascii: "M"), bytes[3] == UInt8(ascii: "1")
        else { throw MapDataError.badMagic }
        let version = try u16(4)
        guard version == formatVersion else {
            throw MapDataError.unsupportedFormat(version)
        }
        let dataVersion = try u32(8)
        guard dataVersion == expectedVersion else {
            throw MapDataError.versionMismatch(file: dataVersion, code: expectedVersion)
        }
        var unchecked = bytes
        let storedChecksum = try u32(20)
        unchecked[20] = 0
        unchecked[21] = 0
        unchecked[22] = 0
        unchecked[23] = 0
        guard fnv1a32(unchecked) == storedChecksum else {
            throw MapDataError.corrupt("the checksum does not match the bytes")
        }
        let headerSize = Int(try u16(6))
        let sectionCount = Int(try u32(16))
        var sections: [UInt16: (offset: Int, length: Int)] = [:]
        for index in 0..<sectionCount {
            let at = headerSize + index * 12
            let kind = try u16(at)
            sections[kind] = (Int(try u32(at + 4)), Int(try u32(at + 8)))
        }
        guard let strings = sections[Section.strings.rawValue],
              let mapsSection = sections[Section.maps.rawValue],
              let fieldsSection = sections[Section.fields.rawValue]
        else { throw MapDataError.corrupt("a section the format requires is absent") }
        func sectionEnd(_ section: (offset: Int, length: Int), _ name: String) throws -> Int {
            guard section.offset >= 0, section.length >= 0,
                  section.offset + section.length <= bytes.count
            else { throw MapDataError.corrupt("the \(name) section runs past the file") }
            return section.offset + section.length
        }
        let stringsEnd = try sectionEnd(strings, "strings")
        let mapsEnd = try sectionEnd(mapsSection, "maps")
        let fieldsEnd = try sectionEnd(fieldsSection, "fields")
        let options = sections[Section.options.rawValue]
        let optionsEnd = try options.map { try sectionEnd($0, "options") } ?? 0

        func stringRef(_ reference: UInt32) throws -> String? {
            guard reference != noReference else { return nil }
            let start = strings.offset + Int(reference)
            guard start >= strings.offset, start < stringsEnd else {
                throw MapDataError.corrupt("a string reference is outside the pool")
            }
            var end = start
            while end < stringsEnd, bytes[end] != 0 { end += 1 }
            guard end < stringsEnd else {
                throw MapDataError.corrupt("an unterminated string at \(start)")
            }
            return try utf8(start, end - start)
        }

        let count = Int(try u32(mapsSection.offset))
        guard count >= 0, mapsSection.offset + 4 + count * mapRecordSize <= mapsEnd else {
            throw MapDataError.corrupt("the map table is larger than its section")
        }
        var loaded: [LoadedStrapMap] = []
        for index in 0..<count {
            let at = mapsSection.offset + 4 + index * mapRecordSize
            let id = try stringRef(try u32(at)) ?? ""
            let name = try stringRef(try u32(at + 4)) ?? ""
            let words = Int(try u16(at + 8))
            let set = try u16(at + 10)
            let fieldCount = Int(try u32(at + 12))
            let fieldsOffset = Int(try u32(at + 16))
            guard words > 0, fieldsOffset >= 0,
                  fieldsSection.offset + fieldsOffset
                    + fieldCount * fieldRecordSize <= fieldsEnd
            else { throw MapDataError.corrupt("map \(id) has no room for its fields") }
            var fields: [DescriptorStrapMap.Field] = []
            fields.reserveCapacity(fieldCount)
            for fieldIndex in 0..<fieldCount {
                let fieldAt = fieldsSection.offset + fieldsOffset
                    + fieldIndex * fieldRecordSize
                let name = try stringRef(try u32(fieldAt)) ?? ""
                let word = Int(try u16(fieldAt + 4))
                let low = Int(bytes[fieldAt + 6])
                let high = Int(bytes[fieldAt + 7])
                let flags = try u16(fieldAt + 8)
                let defaultWord = try u32(fieldAt + 10)
                let label = try stringRef(try u32(fieldAt + 14))
                let optionsOffset = try u32(fieldAt + 18)
                let optionCount = Int(try u16(fieldAt + 22))
                guard word < words, low <= high, high < 32 else {
                    throw MapDataError.corrupt("\(id): \(name) at word \(word), bits \(low)…\(high)")
                }
                var fieldOptions: [Int: String] = [:]
                if flags & 2 != 0, let optionsSection = options {
                    guard optionsOffset != noReference, optionsOffset < 0xFFFF_FFFF,
                          optionsSection.offset + Int(optionsOffset)
                            + optionCount * optionRecordSize <= optionsEnd
                    else { throw MapDataError.corrupt("\(id): \(name) options are outside the file") }
                    for optionIndex in 0..<optionCount {
                        let optionAt = optionsSection.offset + Int(optionsOffset)
                            + optionIndex * optionRecordSize
                        let value = Int(try u16(optionAt))
                        if let text = try stringRef(try u32(optionAt + 4)) {
                            fieldOptions[value] = text
                        }
                    }
                }
                fields.append(.init(name: name, word: word, bits: low...high,
                                    defaultValue: flags & 1 != 0 ? defaultWord : nil,
                                    label: label, options: fieldOptions.isEmpty ? nil : fieldOptions))
            }
            loaded.append(LoadedStrapMap(
                id: id, set: set,
                map: DescriptorStrapMap(name: name, words: words, fields: fields)))
        }
        return loaded
    }
}

// The checksum the compiler writes: FNV-1a over the whole file with the
// checksum field itself zeroed. A file edited without being recompiled is
// refused like a stale build.
private func fnv1a32(_ bytes: [UInt8]) -> UInt32 {
    var value: UInt32 = 2_166_136_261
    for byte in bytes {
        value ^= UInt32(byte)
        value = value &* 16_777_619
    }
    return value
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
