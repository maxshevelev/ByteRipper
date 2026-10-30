import Foundation

/// The original TE/PE32 module's own headers, read for one purpose: to turn a
/// Ghidra address back into an offset in the module bytes the panel shows.
///
/// It is deliberately not a general executable parser. It reads the section
/// table, the image base and the header size, validates the table's bounds, and
/// refuses a module it cannot trust. The layout is read from the **original**
/// module, not from the PE rebuilt for Ghidra: expanding a TE header moves
/// section data, while the virtual addresses stay the same.
///
/// Addresses are Ghidra's: `imageBase + RVA`. For a TE image the header's
/// `StrippedSize` names the header bytes the TE file does not contain; an
/// address in them has no file offset. For a PE image the header bytes are
/// present at offset `RVA`.
public struct ModuleLayout: Equatable, Sendable {
    public enum Format: String, Equatable, Sendable {
        case te
        case pe32
        case pe32Plus
    }

    /// One section, with `rawOffset` already translated to an offset in the
    /// module blob. For a TE image that is `PointerToRawData - StrippedSize +
    /// 40`; for a PE image it is `PointerToRawData`.
    public struct Section: Equatable, Sendable {
        public let name: String
        public let virtualAddress: UInt64
        public let virtualSize: UInt64
        public let rawOffset: UInt64
        public let rawSize: UInt64
        public let characteristics: UInt32

        public init(name: String, virtualAddress: UInt64, virtualSize: UInt64,
                    rawOffset: UInt64, rawSize: UInt64, characteristics: UInt32) {
            self.name = name
            self.virtualAddress = virtualAddress
            self.virtualSize = virtualSize
            self.rawOffset = rawOffset
            self.rawSize = rawSize
            self.characteristics = characteristics
        }

        public var rawRange: Range<UInt64> {
            rawOffset..<(rawOffset + rawSize)
        }

        public var virtualExtent: UInt64 {
            max(virtualSize, rawSize)
        }
    }

    public let format: Format
    public let machine: UInt16
    public let imageBase: UInt64
    public let entryPoint: UInt64
    public let sizeOfHeaders: UInt64
    public let strippedSize: UInt64?
    public let sections: [Section]
    public let byteCount: Int

    public var is64Bit: Bool {
        if format == .pe32Plus { return true }
        if format == .pe32 { return false }
        return Self.machines64.contains(machine)
    }

    public init(module: Data) throws {
        let parsed = try Self.parse([UInt8](module))
        format = parsed.format
        machine = parsed.machine
        imageBase = parsed.imageBase
        entryPoint = parsed.entryPoint
        sizeOfHeaders = parsed.sizeOfHeaders
        strippedSize = parsed.strippedSize
        sections = parsed.sections
        byteCount = module.count
    }

    // MARK: - Address to bytes

    /// The module offset of `address`, or nil when the address has no bytes in
    /// this module: an address in a TE image's stripped headers, a BSS range, or
    /// an address outside every section.
    public func fileOffset(for address: CodeAddress, imageBase: UInt64? = nil) -> UInt64? {
        guard let rva = rva(for: address, imageBase: imageBase) else { return nil }
        for section in sections {
            guard rva >= section.virtualAddress else { continue }
            let delta = rva - section.virtualAddress
            guard delta < section.virtualExtent else { continue }
            // The section's virtual tail may have no bytes in the file.
            guard delta < section.rawSize else { return nil }
            let (offset, overflow) = section.rawOffset.addingReportingOverflow(delta)
            guard !overflow, offset < UInt64(byteCount) else { return nil }
            return offset
        }
        // PE headers are bytes; a TE image's stripped headers are not.
        if format != .te, rva < sizeOfHeaders, rva < UInt64(byteCount) {
            return rva
        }
        return nil
    }

    /// A contiguous run of bytes for an address, or nil when the run would
    /// cross a section boundary or leave the module. The instruction listing's
    /// bytes are checked against this range, so a wrong map is visible.
    public func fileRange(for address: CodeAddress, count: Int,
                          imageBase: UInt64? = nil) -> Range<UInt64>? {
        guard count >= 0, let start = fileOffset(for: address, imageBase: imageBase) else {
            return nil
        }
        guard count > 0 else { return start..<start }
        let (end, overflow) = start.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= UInt64(byteCount) else { return nil }
        if let section = section(containingFileOffset: start) {
            let rawEnd = section.rawOffset + section.rawSize
            guard end <= rawEnd else { return nil }
        } else if format != .te, start < sizeOfHeaders {
            guard end <= sizeOfHeaders else { return nil }
        } else {
            return nil
        }
        return start..<end
    }

    /// The inverse of `fileOffset`: the Ghidra address of a module offset, when
    /// one section contains it. A TE image has no address for its 40-byte
    /// header; a PE image does for its headers.
    public func address(forFileOffset offset: UInt64, imageBase: UInt64? = nil) -> CodeAddress? {
        guard offset < UInt64(byteCount) else { return nil }
        let base = imageBase ?? self.imageBase
        if let section = section(containingFileOffset: offset) {
            let delta = offset - section.rawOffset
            let (rva, overflow) = section.virtualAddress.addingReportingOverflow(delta)
            guard !overflow else { return nil }
            let (address, addressOverflow) = base.addingReportingOverflow(rva)
            guard !addressOverflow else { return nil }
            return CodeAddress(address)
        }
        if format != .te, offset < sizeOfHeaders {
            let (address, overflow) = base.addingReportingOverflow(offset)
            guard !overflow else { return nil }
            return CodeAddress(address)
        }
        return nil
    }

    public func section(containing address: CodeAddress,
                        imageBase: UInt64? = nil) -> Section? {
        guard let rva = rva(for: address, imageBase: imageBase) else { return nil }
        return sections.first { section in
            rva >= section.virtualAddress
                && rva - section.virtualAddress < section.virtualExtent
        }
    }

    public func section(containingFileOffset offset: UInt64) -> Section? {
        sections.first { section in
            offset >= section.rawOffset
                && offset - section.rawOffset < section.rawSize
        }
    }

    // MARK: - Parsing

    private static let machines64: Set<UInt16> = [
        0x8664, 0xAA64, 0x0200, 0x5064, 0x5128
    ]

    private struct Parsed {
        let format: Format
        let machine: UInt16
        let imageBase: UInt64
        let entryPoint: UInt64
        let sizeOfHeaders: UInt64
        let strippedSize: UInt64?
        let sections: [Section]
    }

    private static func parse(_ bytes: [UInt8]) throws -> Parsed {
        guard bytes.count >= 0x40 else {
            throw ModuleLayoutError.invalid(
                "the module is \(bytes.count) bytes, shorter than a header")
        }
        if bytes[0] == 0x56, bytes[1] == 0x5A {          // "VZ"
            return try parseTE(bytes)
        }
        if bytes[0] == 0x4D, bytes[1] == 0x5A {          // "MZ"
            return try parsePE(bytes)
        }
        throw ModuleLayoutError.invalid("the signature is neither VZ nor MZ")
    }

    private static func parseTE(_ bytes: [UInt8]) throws -> Parsed {
        let count = Int(bytes[4])
        guard (1...96).contains(count) else {
            throw ModuleLayoutError.invalid("the TE header declares \(count) sections")
        }
        let stripped = UInt64(try u16(bytes, 6))
        guard stripped >= 40 else {
            throw ModuleLayoutError.invalid(
                "StrippedSize \(stripped) is smaller than the TE header")
        }
        guard 40 + count * 40 <= bytes.count else {
            throw ModuleLayoutError.invalid("the section table runs past the module")
        }
        let sections = try parseSections(bytes, at: 40, count: count, stripped: stripped)
        return Parsed(
            format: .te,
            machine: try u16(bytes, 2),
            imageBase: try u64(bytes, 16),
            entryPoint: UInt64(try u32(bytes, 8)),
            sizeOfHeaders: stripped,
            strippedSize: stripped,
            sections: sections)
    }

    private static func parsePE(_ bytes: [UInt8]) throws -> Parsed {
        let pe = Int(try u32(bytes, 0x3C))
        guard pe >= 0, pe + 24 <= bytes.count else {
            throw ModuleLayoutError.invalid("e_lfanew points outside the module")
        }
        guard bytes[pe] == 0x50, bytes[pe + 1] == 0x45,
              bytes[pe + 2] == 0x00, bytes[pe + 3] == 0x00
        else {
            throw ModuleLayoutError.invalid("the PE signature is missing")
        }
        let machine = try u16(bytes, pe + 4)
        let count = Int(try u16(bytes, pe + 6))
        guard (1...96).contains(count) else {
            throw ModuleLayoutError.invalid("the PE header declares \(count) sections")
        }
        let optionalSize = Int(try u16(bytes, pe + 20))
        let optional = pe + 24
        guard optionalSize >= 96, optional + optionalSize <= bytes.count else {
            throw ModuleLayoutError.invalid("the optional header runs past the module")
        }
        let magic = try u16(bytes, optional)
        let format: Format
        let imageBase: UInt64
        switch magic {
        case 0x10B:
            format = .pe32
            imageBase = UInt64(try u32(bytes, optional + 28))
        case 0x20B:
            format = .pe32Plus
            imageBase = try u64(bytes, optional + 24)
        default:
            throw ModuleLayoutError.invalid(
                String(format: "the optional header magic 0x%X is not PE32 or PE32+", magic))
        }
        let table = optional + optionalSize
        guard table + count * 40 <= bytes.count else {
            throw ModuleLayoutError.invalid("the section table runs past the module")
        }
        let sections = try parseSections(bytes, at: table, count: count, stripped: nil)
        return Parsed(
            format: format,
            machine: machine,
            imageBase: imageBase,
            entryPoint: UInt64(try u32(bytes, optional + 16)),
            sizeOfHeaders: UInt64(try u32(bytes, optional + 60)),
            strippedSize: nil,
            sections: sections)
    }

    private static func parseSections(_ bytes: [UInt8], at start: Int, count: Int,
                                      stripped: UInt64?) throws -> [Section] {
        var sections: [Section] = []
        sections.reserveCapacity(count)
        for index in 0..<count {
            let at = start + index * 40
            let name = sectionName(bytes, at: at)
            let virtualSize = UInt64(try u32(bytes, at + 8))
            let virtualAddress = UInt64(try u32(bytes, at + 12))
            let rawSize = UInt64(try u32(bytes, at + 16))
            let rawPointer = UInt64(try u32(bytes, at + 20))
            let characteristics = try u32(bytes, at + 36)

            let rawOffset: UInt64
            if let stripped {
                if rawSize == 0 {
                    rawOffset = rawPointer >= stripped ? rawPointer - stripped + 40 : 0
                } else {
                    guard rawPointer >= stripped else {
                        throw ModuleLayoutError.invalid(
                            "section \(index) (\(name)) points before the stripped headers")
                    }
                    rawOffset = rawPointer - stripped + 40
                    let (end, overflow) = rawOffset.addingReportingOverflow(rawSize)
                    guard !overflow, rawOffset >= 40, end <= UInt64(bytes.count) else {
                        throw ModuleLayoutError.invalid(
                            "section \(index) (\(name)) points outside the module")
                    }
                }
            } else {
                rawOffset = rawPointer
            }
            sections.append(Section(
                name: name,
                virtualAddress: virtualAddress,
                virtualSize: virtualSize,
                rawOffset: rawOffset,
                rawSize: rawSize,
                characteristics: characteristics))
        }
        return sections
    }

    private static func sectionName(_ bytes: [UInt8], at: Int) -> String {
        let nameBytes = bytes[at..<(at + 8)]
        let end = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
        return String(decoding: nameBytes[..<end], as: UTF8.self)
    }

    // MARK: - Little-endian reads

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw ModuleLayoutError.invalid("a header field ends before its bytes")
        }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw ModuleLayoutError.invalid("a header field ends before its bytes")
        }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else {
            throw ModuleLayoutError.invalid("a header field ends before its bytes")
        }
        return UInt64(try u32(bytes, offset))
            | UInt64(try u32(bytes, offset + 4)) << 32
    }

    private func rva(for address: CodeAddress, imageBase: UInt64?) -> UInt64? {
        let base = imageBase ?? self.imageBase
        guard address.value >= base else { return nil }
        return address.value - base
    }
}
