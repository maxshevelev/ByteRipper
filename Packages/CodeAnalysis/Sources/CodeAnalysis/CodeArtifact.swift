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
    public static let supportedScriptVersions: Set<Int> = [2]

    public let scriptVersion: Int
    public let ghidra: String
    public let program: Program?
    public let blocks: [Block]
    public let strings: [StringEntry]
    public let functions: [Function]
    public let postCodes: [PostCode]
    public let statusCodeCalls: [StatusCodeCall]

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
        statusCodeCalls = try container.decodeIfPresent(
            [StatusCodeCall].self, forKey: .statusCodeCalls) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case scriptVersion = "script_version"
        case ghidra, program, blocks, strings, functions
        case postCodes = "post_codes"
        case statusCodeCalls = "status_code_calls"
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
        public let instructions: [Instruction]

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
            instructions = try container.decodeIfPresent(
                [Instruction].self, forKey: .instructions) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case entry, name, size, signature, external, thunk
            case callers, callees, c, instructions
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

    /// A write to the POST port.
    public struct PostCode: Decodable, Equatable, Sendable {
        public let address: CodeAddress
        public let function: CodeAddress?
        public let port: String
        public let text: String

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            address = try container.decode(CodeAddress.self, forKey: .address)
            function = try container.decodeIfPresent(CodeAddress.self, forKey: .function)
            port = try container.decodeIfPresent(String.self, forKey: .port) ?? ""
            text = try container.decode(String.self, forKey: .text)
        }

        private enum CodingKeys: String, CodingKey {
            case address, function, port, text
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
