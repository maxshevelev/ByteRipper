import Foundation

/// A PE32/PE32+ file rebuilt from an EFI TE image, for Ghidra's PE loader,
/// which starts at a DOS header and refuses `VZ`.
///
/// The reconstruction is exact when `StrippedSize` still has room for a full
/// PE header with sixteen data directories; otherwise the payload moves and the
/// section pointers move with it by whole alignment units. All sixteen
/// directories are written: Ghidra reads entry 14 whatever
/// `NumberOfRvaAndSizes` says.
public enum TEImage {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    static let headerSize = 40
    static let sectionHeaderSize = 40
    static let machines64: Set<UInt16> = [0x8664, 0xAA64, 0x0200, 0x5064, 0x5128]

    public static func isTE(_ bytes: Data) -> Bool {
        bytes.count >= 2 && bytes[bytes.startIndex] == 0x56 && bytes[bytes.startIndex + 1] == 0x5A
    }

    public static func convert(_ input: Data, imageBase: UInt64? = nil) throws -> Data {
        let te = [UInt8](input)
        guard te.count >= headerSize, te[0] == 0x56, te[1] == 0x5A else {
            throw Failure(description: "not a TE image: the signature is not VZ")
        }
        let machine = u16(te, 2)
        let count = Int(te[4])
        let subsystem = UInt16(te[5])
        let stripped = Int(u16(te, 6))
        let entry = u32(te, 8)
        let baseOfCode = u32(te, 12)
        let base = u64(te, 16)
        guard count != 0, count <= 96 else {
            throw Failure(description: "the TE header declares \(count) sections")
        }
        guard headerSize + count * sectionHeaderSize <= te.count else {
            throw Failure(description: "the section table runs past the end of the image")
        }
        guard stripped >= headerSize else {
            throw Failure(description: "StrippedSize \(hex(stripped)) is smaller than the TE header")
        }

        struct Section {
            var name: [UInt8]
            var virtualSize, virtualAddress, rawSize, rawPointer, characteristics: UInt32
        }
        var sections: [Section] = []
        for index in 0..<count {
            let at = headerSize + index * sectionHeaderSize
            let section = Section(name: Array(te[at..<(at + 8)]),
                                  virtualSize: u32(te, at + 8), virtualAddress: u32(te, at + 12),
                                  rawSize: u32(te, at + 16), rawPointer: u32(te, at + 20),
                                  characteristics: u32(te, at + 36))
            // The loader reads a TE section at raw_pointer - stripped + 40.
            let fileOffset = Int(section.rawPointer) - stripped + headerSize
            if section.rawSize != 0, !(headerSize <= fileOffset && fileOffset + Int(section.rawSize) <= te.count) {
                let name = String(decoding: section.name.prefix { $0 != 0 }, as: UTF8.self)
                throw Failure(description: "section \(index) ('\(name)') points at \(hex(fileOffset)), outside the image")
            }
            sections.append(section)
        }

        let is64 = machines64.contains(machine)
        let optionalSize = is64 ? 240 : 224
        let fixedSize = 0x40 + 4 + 20 + optionalSize + count * sectionHeaderSize
        let rebuilt = fixedSize <= stripped ? stripped : stripped + align(fixedSize - stripped, 0x20)
        let delta = rebuilt - stripped
        guard rebuilt <= 0x10000 else {
            throw Failure(description: "the rebuilt header would be \(hex(rebuilt)) bytes")
        }

        var imageSize = 0
        var sizeOfCode: UInt32 = 0
        var sizeOfData: UInt32 = 0
        for section in sections {
            imageSize = max(imageSize, Int(section.virtualAddress) + Int(max(section.virtualSize, section.rawSize)))
            if section.characteristics & 0x20 != 0 {
                sizeOfCode &+= section.rawSize
            } else if section.characteristics & 0x40 != 0 {
                sizeOfData &+= section.rawSize
            }
        }
        imageSize = align(imageSize, 0x20)

        let baseValue = imageBase ?? base
        var characteristics: UInt16 = 0x0002 | 0x0004
        if !is64 { characteristics |= 0x0100 }
        if subsystem == 0x0B || subsystem == 0x0C { characteristics |= 0x2000 }

        var out = [UInt8](repeating: 0, count: rebuilt)
        out[0] = 0x4D
        out[1] = 0x5A
        put32(&out, 0x3C, 0x40)
        out[0x40] = 0x50
        out[0x41] = 0x45
        put16(&out, 0x44, machine)
        put16(&out, 0x46, UInt16(count))
        put16(&out, 0x54, UInt16(optionalSize))
        put16(&out, 0x56, characteristics)
        let optional = 0x58
        put16(&out, optional, is64 ? 0x20B : 0x10B)
        put32(&out, optional + 4, sizeOfCode)
        put32(&out, optional + 8, sizeOfData)
        put32(&out, optional + 16, entry)
        put32(&out, optional + 20, baseOfCode)
        var cursor = optional + 24
        if is64 {
            put64(&out, cursor, baseValue)
        } else {
            // PE32 has BaseOfData before ImageBase.
            put32(&out, cursor + 4, UInt32(truncatingIfNeeded: baseValue))
        }
        cursor += 8
        put32(&out, cursor, 0x20)
        put32(&out, cursor + 4, 0x20)
        put32(&out, cursor + 24, UInt32(imageSize))
        put32(&out, cursor + 28, UInt32(rebuilt))
        put16(&out, cursor + 36, subsystem)
        if is64 {
            put64(&out, cursor + 40, 0x100000)
            put64(&out, cursor + 48, 0x1000)
            put64(&out, cursor + 56, 0x100000)
            put64(&out, cursor + 64, 0x1000)
            cursor += 72
        } else {
            put32(&out, cursor + 40, 0x100000)
            put32(&out, cursor + 44, 0x1000)
            put32(&out, cursor + 48, 0x100000)
            put32(&out, cursor + 52, 0x1000)
            cursor += 56
        }
        put32(&out, cursor + 4, 16)
        // Base relocations and debug: the two directories a TE header keeps.
        out.replaceSubrange((cursor + 8)..<(cursor + 24), with: te[(headerSize - 16)..<headerSize])

        for (index, section) in sections.enumerated() {
            let at = optional + optionalSize + index * sectionHeaderSize
            out.replaceSubrange(at..<(at + 8), with: section.name)
            put32(&out, at + 8, section.virtualSize)
            put32(&out, at + 12, section.virtualAddress)
            put32(&out, at + 16, section.rawSize)
            put32(&out, at + 20, UInt32(truncatingIfNeeded: Int(section.rawPointer) + delta))
            put32(&out, at + 36, section.characteristics)
        }
        out += te[headerSize...]
        return Data(out)
    }

    private static func align(_ value: Int, _ to: Int) -> Int { (value + to - 1) & ~(to - 1) }
    private static func hex(_ value: Int) -> String { "0x" + String(value, radix: 16) }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }
    private static func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * $1) }
    }
    private static func put16(_ bytes: inout [UInt8], _ at: Int, _ value: UInt16) {
        for i in 0..<2 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func put32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func put64(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
}
