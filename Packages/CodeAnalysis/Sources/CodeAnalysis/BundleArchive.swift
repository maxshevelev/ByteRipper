import Foundation

/// A bundle as a zip of **stored** entries.
///
/// The artifact objects are JSON, and a bundle is a carrier, not a format to
/// compress: storing them keeps the zip simple enough to read and write
/// without a decompressor, and the Python side reads the same entries. A
/// deflated entry is refused rather than guessed at.
enum BundleArchive {
    private static let localSignature: UInt32 = 0x0403_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50

    static func write(entries: [String: Data], to url: URL) throws {
        guard entries.count <= Int(UInt16.max) else {
            throw CodeAnalysisError.bundleInvalid("too many entries")
        }
        var output = Data()
        var central = Data()
        var offset: UInt32 = 0

        for name in entries.keys.sorted() {
            guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                  let nameData = name.data(using: .utf8), nameData.count <= Int(UInt16.max)
            else {
                throw CodeAnalysisError.bundleInvalid("\(name) is not an entry name")
            }
            guard let data = entries[name], data.count <= Int(UInt32.max) else {
                throw CodeAnalysisError.bundleInvalid("\(name) is too large")
            }
            let crc = crc32(data)
            let localOffset = offset
            output.appendUInt32(localSignature)
            output.appendUInt16(20)              // version needed
            output.appendUInt16(0)               // flags
            output.appendUInt16(0)               // stored
            output.appendUInt16(0)               // time
            output.appendUInt16(0)               // date
            output.appendUInt32(crc)
            output.appendUInt32(UInt32(data.count))
            output.appendUInt32(UInt32(data.count))
            output.appendUInt16(UInt16(nameData.count))
            output.appendUInt16(0)               // extra
            output.append(nameData)
            output.append(data)
            offset += UInt32(30 + nameData.count + data.count)

            central.appendUInt32(centralSignature)
            central.appendUInt16(20)             // version made by
            central.appendUInt16(20)             // version needed
            central.appendUInt16(0)              // flags
            central.appendUInt16(0)              // stored
            central.appendUInt16(0)              // time
            central.appendUInt16(0)              // date
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(data.count))
            central.appendUInt32(UInt32(data.count))
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)              // extra
            central.appendUInt16(0)              // comment
            central.appendUInt16(0)              // disk
            central.appendUInt16(0)              // internal attributes
            central.appendUInt32(0)              // external attributes
            central.appendUInt32(localOffset)
            central.append(nameData)
        }

        let directoryOffset = offset
        output.append(central)
        output.appendUInt32(endSignature)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(UInt32(central.count))
        output.appendUInt32(directoryOffset)
        output.appendUInt16(0)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        guard let end = endRecord(in: bytes) else {
            throw CodeAnalysisError.bundleInvalid("no end of central directory")
        }
        let count = try uint16(bytes, end + 10)
        let directorySize = try uint32(bytes, end + 12)
        let directoryOffset = try uint32(bytes, end + 16)
        guard Int(directoryOffset) + Int(directorySize) <= bytes.count else {
            throw CodeAnalysisError.bundleInvalid("central directory is outside the file")
        }

        var entries: [String: Data] = [:]
        var cursor = Int(directoryOffset)
        for _ in 0..<count {
            guard try uint32(bytes, cursor) == centralSignature else {
                throw CodeAnalysisError.bundleInvalid("central directory record is not one")
            }
            let method = try uint16(bytes, cursor + 10)
            let crc = try uint32(bytes, cursor + 16)
            let storedSize = try uint32(bytes, cursor + 20)
            let uncompressedSize = try uint32(bytes, cursor + 24)
            let nameLength = try uint16(bytes, cursor + 28)
            let extraLength = try uint16(bytes, cursor + 30)
            let commentLength = try uint16(bytes, cursor + 32)
            let localOffset = try uint32(bytes, cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + Int(nameLength) <= bytes.count else {
                throw CodeAnalysisError.bundleInvalid("entry name is outside the file")
            }
            guard let name = String(bytes: bytes[nameStart..<(nameStart + Int(nameLength))],
                                    encoding: .utf8)
            else { throw CodeAnalysisError.bundleInvalid("entry name is not UTF-8") }
            guard method == 0 else {
                throw CodeAnalysisError.bundleInvalid("\(name) is compressed; only stored entries are read")
            }
            guard storedSize == uncompressedSize else {
                throw CodeAnalysisError.bundleInvalid("\(name) has two sizes")
            }

            let local = Int(localOffset)
            guard try uint32(bytes, local) == localSignature else {
                throw CodeAnalysisError.bundleInvalid("\(name) has no local header")
            }
            let localNameLength = try uint16(bytes, local + 26)
            let localExtraLength = try uint16(bytes, local + 28)
            let dataStart = local + 30 + Int(localNameLength) + Int(localExtraLength)
            let dataEnd = dataStart + Int(storedSize)
            guard dataStart >= 0, dataEnd <= bytes.count else {
                throw CodeAnalysisError.bundleInvalid("\(name) is outside the file")
            }
            let entryData = Data(bytes[dataStart..<dataEnd])
            guard crc32(entryData) == crc else {
                throw CodeAnalysisError.bundleInvalid("\(name) does not match its checksum")
            }
            entries[name] = entryData
            cursor = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return entries
    }

    private static func endRecord(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65_535)
        var cursor = bytes.count - 22
        while cursor >= lowest {
            if cursor + 4 <= bytes.count,
               uint32Unchecked(bytes, cursor) == endSignature {
                return cursor
            }
            cursor -= 1
        }
        return nil
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw CodeAnalysisError.bundleInvalid("an entry ends before its field")
        }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw CodeAnalysisError.bundleInvalid("an entry ends before its field")
        }
        return uint32Unchecked(bytes, offset)
    }

    private static func uint32Unchecked(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
