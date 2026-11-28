import Foundation

/// An EC chip read's flash data area, read through the published review of
/// the module the read belongs to: the review's `eflash_area` rows say where
/// each area is and which type it has, and the review's types — the review
/// document's `types`, C as the exporter's `typeC` writes it — say what each
/// field and each value means, in their comments. The review document, not
/// the artifact: the artifact keeps only the types its C names, and the flash
/// data lies past the image, where no C reaches. Nothing here knows a module: a review that changes changes what
/// is shown at its next publish.
public enum ECFlashDataDecoder {
    /// One area of the flash data, as the review describes it and as the
    /// read holds it.
    public struct Area: Equatable, Sendable {
        public var address: Int
        public var size: Int
        public var label: String?
        /// The row's type, as written in `format`.
        public var format: String
        public var meaning: String?
        public var note: String?
        public var confidence: String?
        /// The code that writes and reads it: the evidence.
        public var writers: [String]
        public var readers: [String]
        /// One element per array slot; one for a scalar or a structure.
        public var elements: [Element]
        /// Why the area could not be read as its type, when it could not.
        public var problem: Problem?
        /// Every byte of the area is erased (0xFF).
        public var erased: Bool
    }

    public enum Problem: Equatable, Sendable {
        /// The area lies past the end of the bytes read.
        case pastTheEnd
        /// The review defines no type of this name.
        case unknownType(String)
    }

    /// One slot of an array, or the area itself.
    public struct Element: Equatable, Sendable {
        public var index: Int?
        public var offset: Int
        public var raw: [UInt8]
        /// A slot of a log whose first byte is erased: never written since
        /// the log was last cleared.
        public var free: Bool
        public var fields: [Field]
    }

    /// One field's value and what the review says of it.
    public struct Field: Equatable, Sendable {
        public var name: String
        public var type: String
        public var value: UInt64
        /// Bits, for a bit field.
        public var bits: Int?
        /// The field's comment in the structure.
        public var comment: String?
        /// For a value of an enum: the member's name and its comment; nil
        /// name when the enum has no member of that value.
        public var member: String?
        public var memberComment: String?
        public var isEnum: Bool
    }

    // MARK: - Types as the exporter writes them

    struct ParsedEnum {
        var members: [(name: String, value: UInt64, comment: String?)]
        var size: Int
    }

    struct ParsedField {
        var offset: Int
        var type: String
        var name: String
        var count: Int?
        var bits: Int?
        var comment: String?
    }

    struct ParsedStruct {
        var fields: [ParsedField]
        var size: Int
    }

    /// `    Name = 0xFC, // comment` lines of an exported enum.
    static func parseEnum(_ c: String, size: Int) -> ParsedEnum? {
        guard c.contains("enum ") else { return nil }
        var members: [(String, UInt64, String?)] = []
        for line in c.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let equals = text.range(of: " = 0x") else { continue }
            let name = String(text[..<equals.lowerBound])
            let rest = text[equals.upperBound...]
            let hex = rest.prefix { $0.isHexDigit }
            guard let value = UInt64(hex, radix: 16) else { continue }
            var comment: String?
            if let slashes = rest.range(of: "// ") {
                comment = String(rest[slashes.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            members.append((name, value, comment))
        }
        return members.isEmpty ? nil : ParsedEnum(members: members, size: size)
    }

    /// `    /* 0x01 */ TYPE Name[N] : bits; // comment` lines of an exported
    /// structure.
    static func parseStruct(_ c: String, size: Int) -> ParsedStruct? {
        guard c.contains("struct ") else { return nil }
        var fields: [ParsedField] = []
        let pattern = #"^\s*/\* 0x([0-9A-Fa-f]+) \*/ (.+?) ([A-Za-z_][A-Za-z0-9_]*)(\[(\d+)\])?( : (\d+))?;( // (.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in c.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            func group(_ index: Int) -> String? {
                let found = match.range(at: index)
                guard found.location != NSNotFound, let swift = Range(found, in: text) else { return nil }
                return String(text[swift])
            }
            guard let offset = group(1).flatMap({ Int($0, radix: 16) }), let type = group(2), let name = group(3)
            else { continue }
            fields.append(ParsedField(offset: offset, type: type, name: name, count: group(5).flatMap { Int($0) },
                                      bits: group(7).flatMap { Int($0) }, comment: group(9)))
        }
        return fields.isEmpty ? nil : ParsedStruct(fields: fields, size: size)
    }

    /// The width of a type in bytes: a structure's `/* size 0x… */`, or a
    /// builtin's; nil for an enum, whose width is the place it fills.
    static func width(of type: String, types: [String: String]) -> Int? {
        if let c = types[type] {
            guard let range = c.range(of: #"/\* size 0x([0-9A-Fa-f]+) \*/"#, options: .regularExpression) else {
                return nil
            }
            return Int(c[range].dropFirst(10).dropLast(3), radix: 16)
        }
        switch type {
        case "UINT8", "INT8", "uchar", "char", "byte", "undefined1", "BOOLEAN", "CHAR8", "uint8_t": return 1
        case "UINT16", "INT16", "ushort", "short", "word", "undefined2", "CHAR16", "uint16_t": return 2
        case "UINT32", "INT32", "uint", "int", "dword", "undefined4", "uint32_t": return 4
        case "UINT64", "INT64", "ulonglong", "longlong", "qword", "undefined8", "uint64_t": return 8
        default: return nil
        }
    }

    // MARK: - Decoding

    /// The areas the review lists, read from `bytes`: the chip read, from its
    /// first byte, so an area's address is its offset in it.
    public static func decode(records: ModuleRecords?, types: [String: String], bytes: Data) -> [Area] {
        guard let rows = records?["eflash_area"]?.rows else { return [] }
        let data = [UInt8](bytes)
        return rows.compactMap { row in
            guard let address = row["address"].flatMap(Self.address), let size = row["size"]?.int else { return nil }
            let format = row["format"]?.text.trimmingCharacters(in: .whitespaces) ?? ""
            var area = Area(address: address, size: size, label: row["label"]?.string, format: format,
                            meaning: row["meaning"]?.string, note: row["note"]?.string,
                            confidence: row["confidence"]?.string,
                            writers: row["writers"]?.array?.map(\.text) ?? [],
                            readers: row["readers"]?.array?.map(\.text) ?? [],
                            elements: [], problem: nil, erased: false)
            guard address >= 0, address + size <= data.count else {
                area.problem = .pastTheEnd
                return area
            }
            let slice = Array(data[address..<(address + size)])
            area.erased = slice.allSatisfy { $0 == 0xFF }
            read(&area, slice: slice, types: types)
            return area
        }.sorted { $0.address < $1.address }
    }

    /// An address cell: `0x2B800`, or a label carrying the address
    /// (`EflashEventLog_2b800`, `DAT_0002b800`).
    static func address(_ value: RecordValue) -> Int? {
        if let number = value.int { return number }
        let text = value.text
        if let range = text.range(of: #"[0-9A-Fa-f]{4,}$"#, options: .regularExpression) {
            return Int(text[range], radix: 16)
        }
        return nil
    }

    private static func read(_ area: inout Area, slice: [UInt8], types: [String: String]) {
        // `TYPE[N]` or `TYPE`.
        var name = area.format
        var count: Int?
        if let open = name.firstIndex(of: "["), let close = name.firstIndex(of: "]"),
           let number = Int(name[name.index(after: open)..<close]) {
            count = number
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let slots = count ?? 1
        guard types[name] != nil || width(of: name, types: types) != nil else {
            area.problem = .unknownType(name)
            return
        }
        // An enum fills its place: the area's size over its slots.
        let width = width(of: name, types: types) ?? (area.size / slots)
        guard width > 0 else {
            area.problem = .unknownType(name)
            return
        }
        for index in 0..<slots {
            let offset = index * width
            guard offset + width <= slice.count else { break }
            let raw = Array(slice[offset..<(offset + width)])
            let fields = Self.fields(of: name, raw: raw, types: types)
            // A log's slot is free while its first byte is erased.
            let free = count != nil && raw.first == 0xFF
            area.elements.append(Element(index: count == nil ? nil : index, offset: area.address + offset,
                                         raw: raw, free: free, fields: fields))
        }
    }

    /// The member of `values` that `number` is, at `width` bytes: a member
    /// Ghidra keeps sign-extended (`0xFFFFFFAA` for a byte's 0xAA) is that byte.
    static func member(_ values: ParsedEnum, _ number: UInt64, width: Int)
        -> (name: String, value: UInt64, comment: String?)? {
        let mask: UInt64 = width >= 8 ? .max : (1 << UInt64(width * 8)) - 1
        return values.members.first { $0.value & mask == number }
    }

    static func fields(of name: String, raw: [UInt8], types: [String: String]) -> [Field] {
        func value(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        let defined = types[name]
        if let defined, let parsed = parseStruct(defined, size: raw.count) {
            var fields: [Field] = []
            // Bit fields at one offset follow one another from bit 0 up.
            var bitAt: [Int: Int] = [:]
            // A field reaches the next offset, the last one the end.
            let offsets = Array(Set(parsed.fields.map(\.offset))).sorted()
            for field in parsed.fields {
                let next = offsets.first { $0 > field.offset } ?? raw.count
                let span = next - field.offset
                guard field.offset + span <= raw.count else { continue }
                var number = value(raw[field.offset..<(field.offset + span)])
                if let bits = field.bits {
                    let shift = bitAt[field.offset, default: 0]
                    bitAt[field.offset] = shift + bits
                    number = (number >> UInt64(shift)) & ((1 << UInt64(bits)) - 1)
                }
                var item = Field(name: field.name, type: field.type, value: number, bits: field.bits,
                                 comment: field.comment, member: nil, memberComment: nil, isEnum: false)
                if let type = types[field.type], let values = parseEnum(type, size: span) {
                    item.isEnum = true
                    if let found = member(values, number, width: field.bits.map { _ in 8 } ?? span) {
                        item.member = found.name
                        item.memberComment = found.comment
                    }
                }
                fields.append(item)
            }
            return fields
        }
        let number = value(raw[...])
        var item = Field(name: name, type: name, value: number, bits: nil, comment: nil,
                         member: nil, memberComment: nil, isEnum: false)
        if let defined, let values = parseEnum(defined, size: raw.count) {
            item.isEnum = true
            if let found = member(values, number, width: raw.count) {
                item.member = found.name
                item.memberComment = found.comment
            }
        }
        return [item]
    }
}
