import Foundation

/// The map kinds the envelope carries. A file states one in its header; the
/// record layouts inside are the reader's, per kind.
public enum MapKind: UInt16, Sendable {
    case strap = 1
    case configuration = 2
    case uep = 3
    case gpio = 4
}

/// The envelope's sections. A reader skips one it does not know.
public enum MapSection: UInt16, Sendable {
    case strings = 1
    case maps = 2
    case fields = 3
    case options = 4
    // Kind 2 uses its own record sections:
    case files = 5
    case settings = 6
}

/// Why a map resource cannot be used.
///
/// The reader reports this rather than interpreting bytes whose layout it
/// cannot trust: a stale resource and a corrupt one both mean "no map", which
/// the panels already know how to show.
public enum MapDataError: Error, Equatable, CustomStringConvertible {
    case resourceMissing(String)
    case badMagic
    case unsupportedFormat(UInt16)
    case versionMismatch(file: UInt32, code: UInt32)
    case wrongKind(UInt16)
    case corrupt(String)

    public var description: String {
        switch self {
        case .resourceMissing(let name):
            return "the map resource \(name) is not in the bundle"
        case .badMagic:
            return "the map resource is not a BRM1 file"
        case .unsupportedFormat(let version):
            return "the map resource is format \(version); this code reads "
                + "\(MapFile.formatVersion)"
        case .versionMismatch(let file, let code):
            return "the map resource is version \(file); this code was marked "
                + "with version \(code)"
        case .wrongKind(let kind):
            return "the map resource is kind \(kind)"
        case .corrupt(let reason):
            return "the map resource is corrupt: \(reason)"
        }
    }
}

/// One compiled map file (`BRM1`), validated before any record is read.
///
/// The header, the section table, the string pool and the checksum are here;
/// what a record means belongs to the reader of its kind. Every read checks
/// its bounds: a truncated or edited file throws rather than trapping.
public struct MapFile: Sendable {
    public static let formatVersion: UInt16 = 1
    public static let noReference: UInt32 = 0xFFFF_FFFF

    /// One section's place in the file. `end` is half-open.
    public struct Section: Sendable, Equatable {
        public var offset: Int
        public var length: Int
        public var end: Int { offset + length }
    }

    public let bytes: [UInt8]
    public let kind: MapKind
    public let version: UInt32
    private let sections: [UInt16: Section]

    /// Reads and validates the envelope.
    ///
    /// - Parameters:
    ///   - expectedFormat: the layout the reader was written for.
    ///   - expectedVersion: the version the code was marked with; a file of
    ///     another version is refused before a section is read.
    public init(data: Data, expectedFormat: UInt16 = MapFile.formatVersion,
                expectedVersion: UInt32) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else {
            throw MapDataError.corrupt("short header")
        }
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
        guard bytes[0] == UInt8(ascii: "B"), bytes[1] == UInt8(ascii: "R"),
              bytes[2] == UInt8(ascii: "M"), bytes[3] == UInt8(ascii: "1")
        else { throw MapDataError.badMagic }
        let format = try u16(4)
        guard format == expectedFormat else {
            throw MapDataError.unsupportedFormat(format)
        }
        let version = try u32(8)
        guard version == expectedVersion else {
            throw MapDataError.versionMismatch(file: version,
                                               code: expectedVersion)
        }
        let kindRaw = try u16(12)
        guard let kind = MapKind(rawValue: kindRaw) else {
            throw MapDataError.wrongKind(kindRaw)
        }
        let headerSize = Int(try u16(6))
        let sectionCount = Int(try u32(16))
        var sections: [UInt16: Section] = [:]
        for index in 0..<sectionCount {
            let at = headerSize + index * 12
            let sectionKind = try u16(at)
            let offset = Int(try u32(at + 4))
            let length = Int(try u32(at + 8))
            guard offset >= 0, length >= 0, offset + length <= bytes.count else {
                throw MapDataError.corrupt(
                    "section \(sectionKind) runs past the file")
            }
            sections[sectionKind] = Section(offset: offset, length: length)
        }
        var zeroed = bytes
        let stored = try u32(20)
        zeroed[20] = 0
        zeroed[21] = 0
        zeroed[22] = 0
        zeroed[23] = 0
        guard MapFile.fnv1a32(zeroed) == stored else {
            throw MapDataError.corrupt("the checksum does not match the bytes")
        }
        self.bytes = bytes
        self.kind = kind
        self.version = version
        self.sections = sections
    }

    public func section(_ kind: MapSection) -> Section? {
        sections[kind.rawValue]
    }

    public func requireSection(_ kind: MapSection) throws -> Section {
        guard let section = section(kind) else {
            throw MapDataError.corrupt(
                "the \(kind) section the format requires is absent")
        }
        return section
    }

    public func u16(_ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else {
            throw MapDataError.corrupt("a 16-bit read at \(at) is outside the file")
        }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    public func u32(_ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else {
            throw MapDataError.corrupt("a 32-bit read at \(at) is outside the file")
        }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// A string from the pool, or nil for `noReference`.
    public func string(_ reference: UInt32) throws -> String? {
        guard reference != MapFile.noReference else { return nil }
        let section = try requireSection(.strings)
        let start = section.offset + Int(reference)
        guard start >= section.offset, start < section.end else {
            throw MapDataError.corrupt("a string reference is outside the pool")
        }
        var end = start
        while end < section.end, bytes[end] != 0 { end += 1 }
        guard end < section.end else {
            throw MapDataError.corrupt("an unterminated string at \(start)")
        }
        guard let text = String(bytes: bytes[start..<end], encoding: .utf8) else {
            throw MapDataError.corrupt("a string is not UTF-8 at \(start)")
        }
        return text
    }

    /// The bounds a record array of `count × size` bytes needs, checked
    /// against its section before the first record is read.
    public func records(_ section: Section, offset: Int, count: Int,
                        size: Int, name: String) throws -> Int {
        guard offset >= 0, count >= 0, size > 0,
              offset + count * size <= section.length else {
            throw MapDataError.corrupt(
                "the \(name) records run past their section")
        }
        return section.offset + offset
    }

    static func fnv1a32(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in bytes {
            value ^= UInt32(byte)
            value = value &* 16_777_619
        }
        return value
    }
}
