import Foundation

/// A number the artifact spells as hexadecimal, e.g. `"0x4BF"`.
///
/// A type rather than a string because it is used for comparison and for
/// mapping into the module; a malformed one must be refused at the boundary,
/// not printed in a listing as if it were an address.
public struct CodeAddress: Decodable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public init?(hex text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            text.removeFirst(2)
        }
        guard !text.isEmpty, text.count <= 16,
              text.allSatisfy({ $0.isHexDigit }),
              let value = UInt64(text, radix: 16)
        else { return nil }
        self.value = value
    }

    public var description: String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    public static func < (lhs: CodeAddress, rhs: CodeAddress) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let address = CodeAddress(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(text) is not a code address")
        }
        self = address
    }
}

/// The typed form of `code.json` (`Skills/ghidra-uefi/reference/code-artifact.md`).
///
/// The artifact is the one-time result of Ghidra reading a module. This type is
/// a reader: it keeps what the panel and an agent ask for, validates the fields
/// they rely on, and ignores fields a later exporter may add. An artifact whose
/// `script_version` this reader does not know is refused rather than read
/// halfway.
public struct CodeArtifact: Decodable, Equatable, Sendable {
    /// The exporter versions this reader understands. A new exporter writes a
    /// new number; an old artifact stays readable beside it.
    ///
    /// 3 has the same shape as 2. It keeps UTF-16 strings, which 2 dropped,
    /// and names `ReportStatusCode` candidates only in a 32-bit image. 4 adds,
    /// all optional: where each function's name came from, the decompiled C's
    /// spans (what each token is, and what a call or a global names), and the
    /// named data — the GUIDs, service tables and interfaces the UEFI pass
    /// named.
    ///
    /// 5 follows each port write back to the call that supplies its value:
    /// `post_codes` are the writes to port 0x80 with the value and the
    /// wrappers it went through, `port_writes` the other ports, and each
    /// function's `c_sites` place its calls in the C. Later, and optional:
    /// `equates` — the names a review gave its constants, with the enum each
    /// is a member of and what it stands for — `types`, the C of the types
    /// the decompiled C names, and each function's `c_fields`.
    public static let supportedScriptVersions: Set<Int> = [2, 3, 4, 5]

    public let scriptVersion: Int
    public let ghidra: String
    public let program: Program?
    public let blocks: [Block]
    public let strings: [StringEntry]
    public let functions: [Function]
    /// Before v5, every OUT instruction, as it reads; from v5, the writes to
    /// port 0x80 — and to a port the analysis could not tell — at the place
    /// that supplies the value.
    public let postCodes: [PostCode]
    /// The writes to every other port (v5): CMOS, PCI configuration, the
    /// keyboard controller.
    public let portWrites: [PostCode]
    public let statusCodeCalls: [StatusCodeCall]
    /// Named data, from v4 on: what the UEFI pass named, and what the image's
    /// own symbols did. Empty for an older artifact.
    public let symbols: [Symbol]
    /// The names a review gave the constants instructions hold — an I/O
    /// port, an MSR, a register bit — and what each stands for. Empty when
    /// the exporter wrote none.
    public let equates: [Equate]
    /// The types the decompiled C names, as C, with their comments. Empty
    /// when the exporter wrote none.
    public let types: [TypeDefinition]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .scriptVersion)
        guard Self.supportedScriptVersions.contains(version) else {
            throw CodeArtifactError.unsupportedVersion(version)
        }
        scriptVersion = version
        ghidra = try container.decodeIfPresent(String.self, forKey: .ghidra) ?? "unknown"
        program = try container.decodeIfPresent(Program.self, forKey: .program)
        blocks = try container.decodeIfPresent([Block].self, forKey: .blocks) ?? []
        strings = try container.decodeIfPresent([StringEntry].self, forKey: .strings) ?? []
        functions = try container.decodeIfPresent([Function].self, forKey: .functions) ?? []
        postCodes = try container.decodeIfPresent([PostCode].self, forKey: .postCodes) ?? []
        portWrites = try container.decodeIfPresent([PostCode].self, forKey: .portWrites) ?? []
        let calls = try container.decodeIfPresent(
            [StatusCodeCall].self, forKey: .statusCodeCalls) ?? []
        // The v2 exporter took any call through `[reg + 0x58]` for
        // ReportStatusCode. That is the slot in the 32-bit PEI services table
        // only; in a 64-bit image it is Boot Services' SetTimer or Runtime
        // Services' SetVariable, so the list is noise and is not shown.
        statusCodeCalls = version == 2 && (program?.is64Bit ?? false) ? [] : calls
        symbols = try container.decodeIfPresent([Symbol].self, forKey: .symbols) ?? []
        equates = try container.decodeIfPresent([Equate].self, forKey: .equates) ?? []
        types = try container.decodeIfPresent([TypeDefinition].self, forKey: .types) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case scriptVersion = "script_version"
        case ghidra, program, blocks, strings, functions
        case postCodes = "post_codes"
        case portWrites = "port_writes"
        case statusCodeCalls = "status_code_calls"
        case symbols, equates, types
    }

    /// What Ghidra says about the program it read. `sha256` is the hash of the
    /// **converted** PE the loader saw, not the firmware module's hash; the
    /// module key comes from the manifest, not from here.
    public struct Program: Decodable, Equatable, Sendable {
        public let name: String?
        public let language: String?
        public let imageBase: CodeAddress?
        public let sha256: String?
        public let executable: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            imageBase = try container.decodeIfPresent(CodeAddress.self, forKey: .imageBase)
            sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
            executable = try container.decodeIfPresent(String.self, forKey: .executable)
        }

        private enum CodingKeys: String, CodingKey {
            case name, language, sha256, executable
            case imageBase = "image_base"
        }

        /// Whether Ghidra's language id names a 64-bit processor
        /// (`x86:LE:64:default`). An unknown language is not assumed to be.
        public var is64Bit: Bool {
            guard let language else { return false }
            let parts = language.split(separator: ":")
            return parts.count >= 3 && parts[2] == "64"
        }
    }

    /// One memory block Ghidra built. `end` is Ghidra's inclusive end; the
    /// module layout is read from the original headers, not from here.
    public struct Block: Decodable, Equatable, Sendable {
        public let name: String
        public let start: CodeAddress
        public let end: CodeAddress
        public let executable: Bool
        public let initialized: Bool

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            start = try container.decode(CodeAddress.self, forKey: .start)
            end = try container.decode(CodeAddress.self, forKey: .end)
            executable = try container.decodeIfPresent(Bool.self, forKey: .executable) ?? false
            initialized = try container.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case name, start, end, executable, initialized
        }
    }

    /// A string Ghidra defined, at its address.
    public struct StringEntry: Decodable, Equatable, Sendable {
        public let address: CodeAddress
        public let type: String
        public let value: String

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            address = try container.decode(CodeAddress.self, forKey: .address)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "string"
            value = try container.decode(String.self, forKey: .value)
        }

        private enum CodingKeys: String, CodingKey {
            case address, type, value
        }
    }

    /// One function, its callers and callees, its decompiled C if Ghidra
    /// produced any, and its instructions in address order.
    public struct Function: Decodable, Equatable, Sendable {
        public let entry: CodeAddress
        public let name: String
        public let size: Int?
        public let signature: String?
        public let external: Bool
        public let thunk: Bool
        public let callers: [CodeAddress]
        public let callees: [CodeAddress]
        public let c: String?
        /// What each token of `c` is, from v4 on; empty before.
        public let cSpans: [CSpan]
        /// Where each call is made, by the call's own address (v5): the place
        /// of an instruction of the listing in the C.
        public let cSites: [CSite]
        /// Where each structure field is named in `c`: the structure and the
        /// field's offset in it.
        public let cFields: [CField]
        /// The one line of `c` that stands for the blocks the decompiler
        /// left out as unreachable, when there were two or more; nil
        /// otherwise.
        public let cUnreachable: CUnreachable?
        /// Where the name came from (v4): `DEFAULT` for Ghidra's FUN_
        /// placeholder, `ANALYSIS` for the UEFI pass, `IMPORTED` for the
        /// image's own symbols, `USER_DEFINED` for a person's.
        public let nameSource: String?
        /// Why the UEFI pass gave the name, in the pass's words.
        public let nameReason: String?
        public let instructions: [Instruction]

        /// Whether the name is Ghidra's placeholder rather than evidence.
        public var hasPlaceholderName: Bool {
            nameSource == "DEFAULT" || (nameSource == nil && name.hasPrefix("FUN_"))
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entry = try container.decode(CodeAddress.self, forKey: .entry)
            name = try container.decode(String.self, forKey: .name)
            size = try container.decodeIfPresent(Int.self, forKey: .size)
            signature = try container.decodeIfPresent(String.self, forKey: .signature)
            external = try container.decodeIfPresent(Bool.self, forKey: .external) ?? false
            thunk = try container.decodeIfPresent(Bool.self, forKey: .thunk) ?? false
            callers = try container.decodeIfPresent([CodeAddress].self, forKey: .callers) ?? []
            callees = try container.decodeIfPresent([CodeAddress].self, forKey: .callees) ?? []
            c = try container.decodeIfPresent(String.self, forKey: .c)
            cSpans = try container.decodeIfPresent([CSpan].self, forKey: .cSpans) ?? []
            cSites = try container.decodeIfPresent([CSite].self, forKey: .cSites) ?? []
            cFields = try container.decodeIfPresent([CField].self, forKey: .cFields) ?? []
            cUnreachable = try container.decodeIfPresent(CUnreachable.self, forKey: .cUnreachable)
            nameSource = try container.decodeIfPresent(String.self, forKey: .nameSource)
            nameReason = try container.decodeIfPresent(String.self, forKey: .nameReason)
            instructions = try container.decodeIfPresent(
                [Instruction].self, forKey: .instructions) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case entry, name, size, signature, external, thunk
            case callers, callees, c, instructions
            case cSpans = "c_spans"
            case cSites = "c_sites"
            case cFields = "c_fields"
            case cUnreachable = "c_unreachable"
            case nameSource = "name_source"
            case nameReason = "name_reason"
        }
    }

    /// One token of the decompiled C: where it is (UTF-16 units into `c`),
    /// what it is, and — for a called function or a global — the address it
    /// names. Written as `[start, length, kind]` or `[start, length, kind,
    /// target]`.
    public struct CSpan: Decodable, Equatable, Sendable {
        public enum Kind: String, Sendable {
            case keyword, comment, type, constant, parameter, local, function, global
        }

        public let start: Int
        public let length: Int
        /// Nil for a kind this reader does not know: the span is not drawn.
        public let kind: Kind?
        public let target: CodeAddress?

        public init(start: Int, length: Int, kind: Kind?, target: CodeAddress?) {
            self.start = start
            self.length = length
            self.kind = kind
            self.target = target
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            start = try container.decode(Int.self)
            length = try container.decode(Int.self)
            kind = Kind(rawValue: try container.decode(String.self))
            target = container.isAtEnd ? nil : try container.decodeIfPresent(CodeAddress.self)
            guard start >= 0, length > 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "a span must have a place and a length")
            }
        }
    }

    /// The called name of a call in the C and the call's address, written as
    /// `[start, length, address]` in UTF-16 units into `c`.
    public struct CSite: Decodable, Equatable, Sendable {
        public let start: Int
        public let length: Int
        public let address: CodeAddress

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            start = try container.decode(Int.self)
            length = try container.decode(Int.self)
            address = try container.decode(CodeAddress.self)
            guard start >= 0, length > 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "a site must have a place and a length")
            }
        }
    }

    /// The blocks Ghidra's decompiler removed as unreachable — with the
    /// values it knows, no path runs them — and the line of the C that says
    /// so, written as `[start, length, [address, …]]`. The instructions are
    /// still in the listing; only the C leaves them out.
    public struct CUnreachable: Decodable, Equatable, Sendable {
        public let start: Int
        public let length: Int
        /// The removed blocks' first addresses, in the decompiler's order.
        public let blocks: [CodeAddress]

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            start = try container.decode(Int.self)
            length = try container.decode(Int.self)
            blocks = try container.decode([CodeAddress].self)
            guard start >= 0, length > 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "the line must have a place and a length")
            }
        }
    }

    /// A structure field named in the C, written as `[start, length, type,
    /// offset]`: UTF-16 units into `c`, the structure's name, and the
    /// field's offset in it.
    public struct CField: Decodable, Equatable, Sendable {
        public let start: Int
        public let length: Int
        public let type: String
        public let offset: Int

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            start = try container.decode(Int.self)
            length = try container.decode(Int.self)
            type = try container.decode(String.self)
            offset = try container.decode(Int.self)
            guard start >= 0, length > 0, offset >= 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "a field must have a place, a length and an offset")
            }
        }
    }

    /// A name a review gave a constant: an I/O port, an MSR, a register bit.
    /// `comment` is what the name stands for and where it is known from, as
    /// the enum member it belongs to says; `references` are the operands
    /// that hold it, by instruction address and operand index.
    public struct Equate: Decodable, Equatable, Sendable {
        public struct Use: Equatable, Sendable {
            public let address: CodeAddress
            public let operand: Int
        }

        public let name: String
        public let value: UInt64
        /// The enum the name is a member of; nil for a bare name.
        public let enumName: String?
        public let comment: String?
        public let references: [Use]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            value = try container.decode(CodeAddress.self, forKey: .value).value
            enumName = try container.decodeIfPresent(String.self, forKey: .enumName)
            comment = try container.decodeIfPresent(String.self, forKey: .comment)
            var list = try container.nestedUnkeyedContainer(forKey: .references)
            var uses: [Use] = []
            while !list.isAtEnd {
                var pair = try list.nestedUnkeyedContainer()
                uses.append(Use(address: try pair.decode(CodeAddress.self), operand: try pair.decode(Int.self)))
            }
            references = uses
        }

        private enum CodingKeys: String, CodingKey {
            case name, value, comment, references
            case enumName = "enum"
        }
    }

    /// A type the C names, as C: every field with its offset and comment.
    public struct TypeDefinition: Decodable, Equatable, Sendable {
        public let name: String
        /// Where Ghidra keeps it: `/ByteRipper/…` for a review's, the EDK2
        /// archive's category for one of EDK2's.
        public let path: String?
        /// `struct`, `union`, `enum`, `typedef`, `function`.
        public let kind: String
        public let size: Int
        public let description: String?
        public let c: String

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "builtin"
            size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
            description = try container.decodeIfPresent(String.self, forKey: .description)
            c = try container.decode(String.self, forKey: .c)
        }

        private enum CodingKeys: String, CodingKey {
            case name, path, kind, size, description, c
        }
    }

    /// A named place in the module's data (v4).
    public struct Symbol: Decodable, Equatable, Sendable {
        public let address: CodeAddress
        public let name: String
        public let type: String?
        public let source: String?
        public let reason: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            address = try container.decode(CodeAddress.self, forKey: .address)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
        }

        private enum CodingKeys: String, CodingKey {
            case address, name, type, source, reason
        }
    }

    /// One instruction: its address, the bytes as stored in the image, and
    /// what Ghidra made of them. `bytes` is empty when Ghidra could not read
    /// them; the listing still has its text.
    public struct Instruction: Decodable, Equatable, Sendable {
        public let address: CodeAddress
        public let bytes: [UInt8]
        public let mnemonic: String?
        public let text: String
        public let flow: String?
        public let references: [Reference]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            address = try container.decode(CodeAddress.self, forKey: .address)
            let rawBytes = try container.decodeIfPresent(String.self, forKey: .bytes) ?? ""
            guard let parsed = Self.parseBytes(rawBytes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bytes, in: container,
                    debugDescription: "\(rawBytes) is not a byte string")
            }
            bytes = parsed
            mnemonic = try container.decodeIfPresent(String.self, forKey: .mnemonic)
            text = try container.decode(String.self, forKey: .text)
            flow = try container.decodeIfPresent(String.self, forKey: .flow)
            references = try container.decodeIfPresent(
                [Reference].self, forKey: .references) ?? []
        }

        private static func parseBytes(_ text: String) -> [UInt8]? {
            let tokens = text.split(whereSeparator: { $0.isWhitespace })
            if tokens.isEmpty { return [] }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(tokens.count)
            for token in tokens {
                guard token.count == 2, let byte = UInt8(token, radix: 16) else {
                    return nil
                }
                bytes.append(byte)
            }
            return bytes
        }

        private enum CodingKeys: String, CodingKey {
            case address, bytes, mnemonic, text, flow, references
        }
    }

    /// A non-fallthrough reference from an instruction.
    public struct Reference: Decodable, Equatable, Sendable {
        public let to: CodeAddress
        public let type: String

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            to = try container.decode(CodeAddress.self, forKey: .to)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case to, type
        }
    }

    /// A write to an I/O port. Before v5 an OUT instruction as it reads, its
    /// `port` the operand (`DX` mostly). From v5 the place that supplies the
    /// value — the OUT itself, or the call of IoWrite8, of a PostCode(), of a
    /// halt routine that writes it — with the port and the value as numbers
    /// when the code says them, and what is left when it does not.
    public struct PostCode: Decodable, Equatable, Sendable {
        /// Why a port or a value is missing (v5).
        public enum Unresolved: String, Sendable {
            /// The function writes a port its caller names, and no caller
            /// was found: a service another module calls through a table.
            case portParameter = "port-parameter"
            case portComputed = "port-computed"
            /// The value comes from a caller that was not found.
            case valueParameter = "value-parameter"
            /// The value is worked out at run time: a table, a loop, a read.
            case valueComputed = "value-computed"
        }

        /// A function the value went through on its way to the OUT,
        /// innermost last.
        public struct Wrapper: Decodable, Equatable, Sendable {
            public let function: CodeAddress
            public let name: String?
        }

        public let address: CodeAddress
        public let function: CodeAddress?
        public let port: String
        /// The value written (v5); nil when the code does not say it.
        public let value: UInt64?
        /// The width of the write in bytes (v5).
        public let width: Int?
        public let unresolved: Unresolved?
        /// The functions between this place and the OUT, outermost first.
        public let via: [Wrapper]
        public let text: String

        /// The port as a number, when it is one.
        public var portNumber: UInt64? {
            port.lowercased().hasPrefix("0x") ? UInt64(port.dropFirst(2), radix: 16) : nil
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            address = try container.decode(CodeAddress.self, forKey: .address)
            function = try container.decodeIfPresent(CodeAddress.self, forKey: .function)
            port = try container.decodeIfPresent(String.self, forKey: .port) ?? ""
            value = try container.decodeIfPresent(String.self, forKey: .value).flatMap { text in
                text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
            }
            width = try container.decodeIfPresent(Int.self, forKey: .width)
            unresolved = try container.decodeIfPresent(String.self, forKey: .unresolved).flatMap(Unresolved.init)
            via = try container.decodeIfPresent([Wrapper].self, forKey: .via) ?? []
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case address, function, port, value, width, unresolved, via, text
        }
    }

    /// A call through a table entry that may be `ReportStatusCode`. A
    /// candidate, not a conclusion; the context is what says whether it is.
    public struct StatusCodeCall: Decodable, Equatable, Sendable {
        public let address: CodeAddress
        public let function: CodeAddress?
        public let text: String
        public let context: [String]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            address = try container.decode(CodeAddress.self, forKey: .address)
            function = try container.decodeIfPresent(CodeAddress.self, forKey: .function)
            text = try container.decode(String.self, forKey: .text)
            context = try container.decodeIfPresent([String].self, forKey: .context) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case address, function, text, context
        }
    }
}
