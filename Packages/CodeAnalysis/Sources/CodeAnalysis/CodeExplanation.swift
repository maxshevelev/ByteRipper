import Foundation

/// What a name in the code stands for, as the Code panel shows it beside the
/// name: a constant a review named (`PCI_CONFIG_ADDRESS = 0xCF8`), a type the
/// C names (`SEC_SERIAL_DEVICE_INFO`), a field of a structure.
///
/// The words are the review's: an enum member's comment, a type's
/// description, a field's comment. A name nobody explained still has its
/// facts — the value, the enum, the C — and `text` is then nil.
public struct CodeExplanation: Equatable, Sendable {
    public enum Subject: Equatable, Sendable {
        case constant(name: String, value: UInt64)
        case type(String)
        case field(type: String, offset: Int)
        /// The decompiler's one line for the blocks it left out of the C
        /// as unreachable; `uses` are the blocks.
        case unreachable(blocks: Int)
        /// A named global: its address.
        case global(CodeAddress)
        /// A call the processor model makes into one of its own named
        /// operations, such as x86's `InterruptDescriptorTableRegister` for
        /// SIDT. There is no function behind the name and nothing to open; the
        /// operation's name is what the C writes.
        case pcodeOperation(String)
    }

    /// An instruction that holds the constant, or a removed block's first.
    public struct Use: Equatable, Sendable {
        /// The instruction's place in `CodeModel.lines`.
        public let line: Int
        public let function: Int
        public let address: CodeAddress
    }

    public let subject: Subject
    /// The name as the code writes it: `PCI_CONFIG_ADDRESS`,
    /// `SEC_SERIAL_DEVICE_INFO`, `SEC_SERIAL_DEVICE_INFO.BaudRate`.
    public let name: String
    /// The enum a constant is a member of; nil for a bare name and for a type.
    public let enumName: String?
    /// A type's kind as C says it — `struct`, `union`, `enum`, `typedef` — and
    /// its size in bytes, 0 when it has none.
    public let kind: String?
    public let size: Int
    /// A field's declaration, `UINT32 BaudRate`, as the type's C writes it.
    public let declaration: String?
    /// The review's words for it; nil when there are none.
    public let text: String?
    /// The type's C, for a type or a field; nil for a constant.
    public let c: String?
    /// The instructions that hold the constant, in address order.
    public let uses: [Use]
    /// What a global holds in the image, `0xF8000000 = 4160749568` or a
    /// GUID; nil for anything else, or when the bytes are not at hand.
    public var value: String?

    /// The review's words split where they name their source —
    /// `… Source: PCI 3.0, 3.2.2.3.2`, `Source of the name: Linux …` — so the
    /// meaning reads first and the reference can be set apart. Nil source
    /// when the words name none.
    public static func splitSource(_ text: String) -> (text: String, source: String?) {
        guard let found = text.range(of: #"(^|(?<=[.;)]\s))Sources?( of the [a-z]+)?:"#, options: .regularExpression)
        else { return (text, nil) }
        let words = text[..<found.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let source = text[found.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (words, source.isEmpty ? nil : source)
    }

    public init(subject: Subject, name: String, enumName: String?, kind: String?, size: Int,
                declaration: String?, text: String?, c: String?, uses: [Use], value: String? = nil) {
        self.value = value
        self.subject = subject
        self.name = name
        self.enumName = enumName
        self.kind = kind
        self.size = size
        self.declaration = declaration
        self.text = text
        self.c = c
        self.uses = uses
    }
}

extension CodeModel {
    /// The explanation for a C token of function `index`: an equate's name
    /// written as a constant, a type, or a structure field. Nil for anything
    /// else, and for a name the artifact holds nothing about.
    public func explanation(ofC token: CodeToken, inFunction index: Int) -> CodeExplanation? {
        guard functions.indices.contains(index), let c = functions[index].c else { return nil }
        let text = Self.slice(c, token.start, token.length)
        switch token.kind {
        case .constant:
            // The decompiler writes an equate as its name where the number was.
            guard let first = text.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else {
                return nil
            }
            let held = Set(functions[index].instructions.map(\.address))
            let candidates = artifact.equates.filter { $0.name == text }
            // A name in two enums with two values: the one this function holds.
            let equate = candidates.first { $0.references.contains { held.contains($0.address) } } ?? candidates.first
            return equate.map(explanation(of:))
        case .type:
            return typeExplanation(named: text)
        case .pcode:
            return pcodeExplanation(name: text)
        case .global:
            // By the address it links to; one with no bytes in the module
            // links nowhere and is found by its name.
            if case .bytes(let address)? = token.link { return explanation(ofGlobal: address) }
            return artifact.symbols.first { $0.name == text }.flatMap { explanation(ofGlobal: $0.address) }
        case .comment:
            guard let removed = functions[index].cUnreachable,
                  removed.start == token.start, removed.length == token.length else { return nil }
            return unreachableExplanation(removed, text: text)
        default:
            if let field = functions[index].cFields.first(where: { $0.start == token.start && $0.length == token.length }) {
                return fieldExplanation(field, name: text)
            }
            return nil
        }
    }

    /// The structure field named at UTF-16 offset `character` of function
    /// `index`'s C, if one is.
    public func field(atC character: Int, inFunction index: Int) -> CodeArtifact.CField? {
        guard functions.indices.contains(index) else { return nil }
        return functions[index].cFields.first { $0.start <= character && character < $0.start + $0.length }
    }

    /// The explanation for the field named at a place in function `index`'s C.
    public func explanation(ofField field: CodeArtifact.CField, inFunction index: Int) -> CodeExplanation? {
        guard functions.indices.contains(index), let c = functions[index].c else { return nil }
        return fieldExplanation(field, name: Self.slice(c, field.start, field.length))
    }

    /// The explanation for a constant of the listing: the equate the
    /// instruction on `line` holds with that value. The listing writes the
    /// number, the name is what the review gave it.
    public func explanation(ofConstant value: UInt64, onLine line: Int) -> CodeExplanation? {
        guard lines.indices.contains(line) else { return nil }
        let address = lines[line].instruction.address
        let width = Self.width(of: value)
        let equate = artifact.equates.first { equate in
            equate.references.contains { $0.address == address }
                && (equate.value == value || equate.value & width == value & width)
        }
        return equate.map(explanation(of:))
    }

    /// The explanation for a named global at `address`: its type, where it
    /// is, what the image holds there, the review's words for it and the
    /// instructions that read or write it. Nil for an address no symbol names.
    public func explanation(ofGlobal address: CodeAddress) -> CodeExplanation? {
        guard let symbol = artifact.symbols.first(where: { $0.address == address }) else { return nil }
        let uses = uses(of: address).map {
            CodeExplanation.Use(line: $0.line, function: $0.function, address: $0.from)
        }
        let words = (symbol.comment ?? symbol.reason).flatMap(Self.nonEmpty)
        return CodeExplanation(subject: .global(address), name: symbol.name, enumName: nil,
                               kind: symbol.type, size: 0, declaration: nil, text: words, c: nil,
                               uses: uses, value: value(of: symbol))
    }

    /// How many bytes a datum of `type` takes: a GUID's 16, an integer's
    /// width, a pointer's; nil for a type this reader does not size.
    public func width(ofType type: String) -> Int? {
        let pointer = (artifact.program?.is64Bit ?? false) ? 8 : 4
        switch type {
        case "EFI_GUID", "GUID": return 16
        case "UINT8", "INT8", "BOOLEAN", "CHAR8", "byte", "uchar", "char", "bool": return 1
        case "UINT16", "INT16", "CHAR16", "word", "ushort", "short", "wchar16": return 2
        case "UINT32", "INT32", "dword", "uint", "int": return 4
        case "UINT64", "INT64", "qword", "ulonglong", "longlong", "EFI_PHYSICAL_ADDRESS": return 8
        case "UINTN", "INTN", "EFI_STATUS": return pointer
        default: return type.hasSuffix("*") ? pointer : nil
        }
    }

    /// What the image holds at a symbol whose type says how to read it.
    private func value(of symbol: CodeArtifact.Symbol) -> String? {
        guard let bytes = moduleBytes, let width = symbol.type.flatMap(width(ofType:)),
              let range = moduleRange(of: symbol.address, count: width),
              range.upperBound <= UInt64(bytes.count) else { return nil }
        let raw = [UInt8](bytes[bytes.startIndex + Int(range.lowerBound)..<bytes.startIndex + Int(range.upperBound)])
        if width == 16 {
            func hex(_ slice: ArraySlice<UInt8>) -> String { slice.map { String(format: "%02X", $0) }.joined() }
            let d1 = raw[0..<4].reversed().map { String(format: "%02X", $0) }.joined()
            let d2 = raw[4..<6].reversed().map { String(format: "%02X", $0) }.joined()
            let d3 = raw[6..<8].reversed().map { String(format: "%02X", $0) }.joined()
            return "\(d1)-\(d2)-\(d3)-\(hex(raw[8..<10]))-\(hex(raw[10..<16]))"
        }
        let number = raw.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Self.number(number)
    }

    /// A type by name, as the artifact holds it.
    public func typeDefinition(named name: String) -> CodeArtifact.TypeDefinition? {
        artifact.types.first { $0.name == name }
    }

    // MARK: - Building one

    private func explanation(of equate: CodeArtifact.Equate) -> CodeExplanation {
        let uses = equate.references.compactMap { use -> CodeExplanation.Use? in
            guard let line = line(at: use.address) else { return nil }
            return CodeExplanation.Use(line: line, function: lines[line].function, address: use.address)
        }
        return CodeExplanation(subject: .constant(name: equate.name, value: equate.value),
                               name: equate.name, enumName: equate.enumName, kind: nil, size: 0,
                               declaration: nil, text: equate.comment.flatMap(Self.nonEmpty), c: nil, uses: uses)
    }

    private func unreachableExplanation(_ removed: CodeArtifact.CUnreachable, text: String) -> CodeExplanation {
        let uses = removed.blocks.sorted().compactMap { address -> CodeExplanation.Use? in
            guard let line = line(at: address) else { return nil }
            return CodeExplanation.Use(line: line, function: lines[line].function, address: address)
        }
        return CodeExplanation(subject: .unreachable(blocks: removed.blocks.count), name: text, enumName: nil,
                               kind: nil, size: 0, declaration: nil, text: nil, c: nil, uses: uses)
    }

    private func typeExplanation(named name: String) -> CodeExplanation? {
        guard let type = typeDefinition(named: name) else { return nil }
        return CodeExplanation(subject: .type(type.name), name: type.name, enumName: nil,
                               kind: type.kind, size: type.size, declaration: nil, text: type.description.flatMap(Self.nonEmpty), c: type.c, uses: [])
    }

    /// A call the decompiler wrote for a p-code operation of the processor
    /// model — SIDT as `InterruptDescriptorTableRegister()` on x86. The words
    /// are the panel's: the model knows only the operation's name.
    private func pcodeExplanation(name: String) -> CodeExplanation {
        CodeExplanation(subject: .pcodeOperation(name), name: name, enumName: nil, kind: nil,
                        size: 0, declaration: nil, text: nil, c: nil, uses: [])
    }

    private func fieldExplanation(_ field: CodeArtifact.CField, name: String) -> CodeExplanation? {
        guard let type = typeDefinition(named: field.type) else { return nil }
        let declared = Self.fieldLine(in: type.c, offset: field.offset, name: name)
        return CodeExplanation(subject: .field(type: type.name, offset: field.offset),
                               name: "\(type.name).\(name)", enumName: nil, kind: type.kind, size: type.size,
                               declaration: declared?.declaration, text: declared?.comment.flatMap(Self.nonEmpty), c: type.c, uses: [])
    }

    /// A field's line in a type's C as the exporter writes it —
    /// `    /* 0x04 */ UINT32 BaudRate; // comment` — split into the
    /// declaration and the comment.
    static func fieldLine(in c: String, offset: Int, name: String) -> (declaration: String, comment: String?)? {
        let mark = String(format: "/* 0x%02X */", offset)
        for raw in c.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(mark) else { continue }
            var rest = line.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
            var comment: String?
            if let slashes = rest.range(of: " // ") {
                comment = String(rest[slashes.upperBound...])
                rest = String(rest[..<slashes.lowerBound])
            }
            let declaration = rest.hasSuffix(";") ? String(rest.dropLast()) : rest
            // A union's fields share an offset: the one with this name.
            guard declaration.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b",
                                    options: .regularExpression) != nil else { continue }
            return (declaration, comment)
        }
        return nil
    }

    /// `0xCF8 = 3320`; a small number is the same in both and is written once.
    public static func number(_ value: UInt64) -> String {
        let hex = "0x" + String(value, radix: 16, uppercase: true)
        return value < 10 ? hex : "\(hex) = \(value)"
    }

    /// The mask of the narrowest operand that holds `value`: the listing may
    /// write a byte's 0xFF where the equate holds it sign-extended.
    private static func width(of value: UInt64) -> UInt64 {
        if value <= 0xFF { return 0xFF }
        if value <= 0xFFFF { return 0xFFFF }
        if value <= 0xFFFF_FFFF { return 0xFFFF_FFFF }
        return .max
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func slice(_ text: String, _ start: Int, _ length: Int) -> String {
        let units = text.utf16
        guard start >= 0, length >= 0, start + length <= units.count else { return "" }
        let from = units.index(units.startIndex, offsetBy: start)
        let to = units.index(from, offsetBy: length)
        return String(units[from..<to]) ?? ""
    }
}
