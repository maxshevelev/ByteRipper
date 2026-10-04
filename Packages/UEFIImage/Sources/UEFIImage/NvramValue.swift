import Foundation

/// What a variable's value is, read as its type (§9).
///
/// A VSS header says nothing about the type of the value, so the type comes
/// from three places, in this order. The UEFI specification defines a number
/// of variables by name and GUID — `BootOrder` is a list of `UINT16`, `Lang`
/// an ASCII string, `ConOut` a device path, `PK` a signature list — and those
/// are read as it defines them. The attributes name one more: a hardware
/// error record. Everything else is read from its own bytes, by structures
/// that check themselves (a device path, a load option, a signature list)
/// and then by plain shapes: text, a number of a register's width, bytes.
/// What the value was read by is kept (`basis`), so the panel can say which
/// readings are certain and which are guesses.
public struct NvramValue: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// No bytes at all.
        case empty
        /// A little-endian unsigned number of `size` bytes: 1, 2, 4 or 8.
        case number(UInt64, size: Int)
        /// `BootOrder` and its kind: a list of load option numbers.
        case optionList([UInt16])
        /// `BootNext`, `BootCurrent`: one load option number.
        case optionNumber(UInt16)
        case text(String, TextEncoding)
        /// A device path, in the spec's text form.
        case devicePath(String)
        case loadOption(LoadOption)
        case signatures([SignatureList])
        /// A record the firmware keeps of a hardware error (`HwErrRec####`).
        case hardwareErrorRecord
        /// Nothing the bytes read as.
        case bytes
    }

    public enum TextEncoding: Equatable, Sendable {
        case ascii
        case ucs2
    }

    /// What decided the type.
    public enum Basis: Equatable, Sendable {
        /// The UEFI specification defines the variable by this name and GUID.
        case specification
        /// The specification defines a variable of this name; this one has
        /// a vendor's GUID.
        case name
        /// The attributes say what it is.
        case attributes
        /// The bytes read as this; nothing else says so.
        case content
    }

    public var content: Content
    public var basis: Basis

    public init(content: Content, basis: Basis) {
        self.content = content
        self.basis = basis
    }

    /// `EFI_LOAD_OPTION`: `Boot####` and its kind.
    public struct LoadOption: Equatable, Sendable {
        public var attributes: UInt32
        public var description: String
        /// The file path list in text; nil when it does not read as one.
        public var devicePath: String?
        public var optionalDataSize: Int

        public init(attributes: UInt32, description: String, devicePath: String?, optionalDataSize: Int) {
            self.attributes = attributes
            self.description = description
            self.devicePath = devicePath
            self.optionalDataSize = optionalDataSize
        }

        public var isActive: Bool { attributes & 0x1 != 0 }
    }

    /// `EFI_SIGNATURE_LIST`: signatures of one type.
    public struct SignatureList: Equatable, Sendable {
        public var type: EFIGUID
        /// The spec's name of the type — `X.509`, `SHA-256` — or nil.
        public var typeName: String?
        public var signatures: [Signature]

        public init(type: EFIGUID, typeName: String?, signatures: [Signature]) {
            self.type = type
            self.typeName = typeName
            self.signatures = signatures
        }

        public var isCertificates: Bool { type == NvramValue.certX509 }
    }

    public struct Signature: Equatable, Sendable {
        public var owner: EFIGUID
        /// A certificate's subject: its common name, or its organisation.
        public var subject: String?
        public var size: Int

        public init(owner: EFIGUID, subject: String?, size: Int) {
            self.owner = owner
            self.subject = subject
            self.size = size
        }
    }

    // MARK: - Reading

    /// `EFI_GLOBAL_VARIABLE`.
    public static let globalVariable = EFIGUID("8BE4DF61-93CA-11D2-AA0D-00E098032B8C")!
    /// `EFI_IMAGE_SECURITY_DATABASE_GUID`: `db`, `dbx`, `dbt`, `dbr`.
    public static let imageSecurityDatabase = EFIGUID("D719B2CB-3D3A-4596-A3BC-DAD00E67656F")!
    static let certX509 = EFIGUID("A5C059A1-94E4-4AA7-87B5-AB155C2BF072")!

    /// The attribute that marks a hardware error record.
    static let hardwareErrorRecordAttribute: UInt32 = 0x0000_0008

    /// `value` of the variable `name` in `guid`, with `attributes`.
    public static func read(name: String, guid: EFIGUID?, attributes: UInt32, value: [UInt8]) -> NvramValue {
        guard !value.isEmpty else { return NvramValue(content: .empty, basis: .content) }
        if let defined = specified(name: name, guid: guid, value: value) { return defined }
        if attributes & hardwareErrorRecordAttribute != 0 {
            return NvramValue(content: .hardwareErrorRecord, basis: .attributes)
        }
        return NvramValue(content: guessed(value), basis: .content)
    }

    /// What the spec defines a variable of this name to be, when the value
    /// has that shape. A value of another shape — a vendor reusing a name —
    /// is left to be read from its bytes.
    private static func specified(name: String, guid: EFIGUID?, value: [UInt8]) -> NvramValue? {
        let owner: EFIGUID
        let content: Content?
        switch name {
        case "BootOrder", "DriverOrder", "SysPrepOrder", "PlatformRecoveryOrder":
            owner = globalVariable
            content = value.count % 2 == 0 ? .optionList(words(value)) : nil
        case "BootNext", "BootCurrent":
            owner = globalVariable
            content = value.count == 2 ? .optionNumber(words(value)[0]) : nil
        case "Timeout", "HwErrRecSupport":
            owner = globalVariable
            content = number(value, size: 2)
        case "BootOptionSupport":
            owner = globalVariable
            content = number(value, size: 4)
        case "OsIndications", "OsIndicationsSupported":
            owner = globalVariable
            content = number(value, size: 8)
        case "SecureBoot", "SetupMode", "AuditMode", "DeployedMode", "VendorKeys":
            owner = globalVariable
            content = number(value, size: 1)
        case "Lang", "PlatformLang", "LangCodes", "PlatformLangCodes":
            owner = globalVariable
            content = asciiText(value, strict: false).map { .text($0, .ascii) }
        case "ConIn", "ConOut", "ErrOut", "ConInDev", "ConOutDev", "ErrOutDev":
            owner = globalVariable
            content = DevicePath.text(value).map(Content.devicePath)
        case "PK", "KEK", "PKDefault", "KEKDefault", "dbDefault", "dbxDefault", "dbtDefault", "dbrDefault":
            owner = globalVariable
            content = signatureLists(value).map(Content.signatures)
        case "db", "dbx", "dbt", "dbr":
            owner = imageSecurityDatabase
            content = signatureLists(value).map(Content.signatures)
        default:
            guard isLoadOptionName(name) else { return nil }
            owner = globalVariable
            content = loadOption(value).map(Content.loadOption)
        }
        guard let content else { return nil }
        return NvramValue(content: content, basis: guid == owner ? .specification : .name)
    }

    /// `Boot####`, `Driver####`, `SysPrep####`, `PlatformRecovery####`: four
    /// upper-case hex digits after the prefix.
    static func isLoadOptionName(_ name: String) -> Bool {
        for prefix in ["Boot", "Driver", "SysPrep", "PlatformRecovery"] where name.hasPrefix(prefix) {
            let digits = name.dropFirst(prefix.count)
            return digits.count == 4 && digits.allSatisfy { $0.isHexDigit && !$0.isLowercase }
        }
        return false
    }

    /// The structures that check themselves first, then the shapes.
    private static func guessed(_ value: [UInt8]) -> Content {
        if let lists = signatureLists(value) { return .signatures(lists) }
        if let path = DevicePath.text(value) { return .devicePath(path) }
        if let text = ucs2Text(value) { return .text(text, .ucs2) }
        if let text = asciiText(value) { return .text(text, .ascii) }
        if [1, 2, 4, 8].contains(value.count), let number = number(value, size: value.count) { return number }
        return .bytes
    }

    // MARK: - Shapes

    private static func number(_ value: [UInt8], size: Int) -> Content? {
        guard value.count == size else { return nil }
        return .number(value.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, size: size)
    }

    private static func words(_ value: [UInt8]) -> [UInt16] {
        stride(from: 0, to: value.count - 1, by: 2).map { UInt16(value[$0]) | UInt16(value[$0 + 1]) << 8 }
    }

    private static func isPrintable(_ unit: UInt16) -> Bool {
        (0x20...0x7E).contains(unit) || (0xA0...0xFF).contains(unit) || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    /// Whether a run of `characters` in a value of `size` bytes is text
    /// rather than a number. A value as wide as a register — 1, 2, 4 or 8
    /// bytes — is a number before it is anything else: a counter whose bytes
    /// happen to be printable (`"9 "`, ``"e@7`"``) is far more common than a
    /// word that short. So there it counts as text only with a terminator
    /// after three characters or more; elsewhere two will do.
    private static func isText(characters: Int, terminated: Bool, size: Int) -> Bool {
        [1, 2, 4, 8].contains(size) ? terminated && characters >= 3 : characters >= 2
    }

    /// UCS-2 text: printable characters, then nothing but zeros.
    static func ucs2Text(_ value: [UInt8]) -> String? {
        guard value.count >= 4, value.count % 2 == 0 else { return nil }
        let units = words(value)
        let end = units.firstIndex(of: 0) ?? units.count
        guard units[end...].allSatisfy({ $0 == 0 }), units[..<end].allSatisfy(isPrintable),
              isText(characters: end, terminated: end < units.count, size: value.count)
        else { return nil }
        return String(decoding: units[..<end], as: UTF16.self)
    }

    /// ASCII text: printable bytes, then nothing but zeros. `strict` holds
    /// a guess to `isText`; a variable the spec says is text needs only one
    /// character.
    static func asciiText(_ value: [UInt8], strict: Bool = true) -> String? {
        let end = value.firstIndex(of: 0) ?? value.count
        guard value[end...].allSatisfy({ $0 == 0 }),
              value[..<end].allSatisfy({ isPrintable(UInt16($0)) && $0 < 0x80 }),
              strict ? isText(characters: end, terminated: end < value.count, size: value.count) : end >= 1
        else { return nil }
        return String(decoding: value[..<end], as: UTF8.self)
    }

    // MARK: - Structures

    /// `EFI_LOAD_OPTION`: attributes, the path list's length, a terminated
    /// UCS-2 description, the path list, optional data. Nil unless all of it
    /// fits and the path list reads as one.
    static func loadOption(_ value: [UInt8]) -> LoadOption? {
        guard value.count >= 8 else { return nil }
        let attributes = UInt32(value[0]) | UInt32(value[1]) << 8 | UInt32(value[2]) << 16 | UInt32(value[3]) << 24
        let pathLength = Int(value[4]) | Int(value[5]) << 8
        var at = 6
        var units: [UInt16] = []
        while true {
            guard at + 2 <= value.count else { return nil }
            let unit = UInt16(value[at]) | UInt16(value[at + 1]) << 8
            at += 2
            if unit == 0 { break }
            units.append(unit)
        }
        guard at + pathLength <= value.count else { return nil }
        let path = Array(value[at..<(at + pathLength)])
        return LoadOption(attributes: attributes, description: String(decoding: units, as: UTF16.self),
                          devicePath: DevicePath.text(path),
                          optionalDataSize: value.count - at - pathLength)
    }

    /// Signature lists back to back, filling the value exactly, each of a
    /// type the spec names. Nil otherwise.
    static func signatureLists(_ value: [UInt8]) -> [SignatureList]? {
        func u32(_ at: Int) -> Int {
            Int(value[at]) | Int(value[at + 1]) << 8 | Int(value[at + 2]) << 16 | Int(value[at + 3]) << 24
        }
        var lists: [SignatureList] = []
        var at = 0
        while at < value.count {
            guard at + 28 <= value.count else { return nil }
            let type = EFIGUID(bytes: Array(value[at..<(at + 16)]))
            guard let typeName = signatureTypes[type] else { return nil }
            let listSize = u32(at + 16), headerSize = u32(at + 20), signatureSize = u32(at + 24)
            let first = at + 28 + headerSize
            guard signatureSize > 16, listSize >= 28, first <= at + listSize, at + listSize <= value.count,
                  (at + listSize - first) % signatureSize == 0
            else { return nil }
            var signatures: [Signature] = []
            var entry = first
            while entry < at + listSize {
                let owner = EFIGUID(bytes: Array(value[entry..<(entry + 16)]))
                let data = Array(value[(entry + 16)..<(entry + signatureSize)])
                signatures.append(Signature(owner: owner, subject: type == certX509 ? X509.subject(data) : nil,
                                            size: data.count))
                entry += signatureSize
            }
            lists.append(SignatureList(type: type, typeName: typeName, signatures: signatures))
            at += listSize
        }
        return lists.isEmpty ? nil : lists
    }

    /// The signature types of UEFI §32.4.1.
    static let signatureTypes: [EFIGUID: String] = {
        var types: [EFIGUID: String] = [:]
        for (guid, name) in [
            ("C1C41626-504C-4092-ACA9-41F936934328", "SHA-256"),
            ("3C5766E8-269C-4E34-AA14-ED776E85B3B6", "RSA-2048"),
            ("E2B36190-879B-4A3D-AD8D-F2E7BBA32784", "RSA-2048 + SHA-256"),
            ("826CA512-CF10-4AC9-B187-BE01496631BD", "SHA-1"),
            ("67F8444F-8743-48F1-A328-1EAAB8736080", "RSA-2048 + SHA-1"),
            ("A5C059A1-94E4-4AA7-87B5-AB155C2BF072", "X.509"),
            ("0B6E5233-A65C-44C9-9407-D9AB83BFC8BD", "SHA-224"),
            ("FF3E5307-9FD0-48C9-85F1-8AD56C701E01", "SHA-384"),
            ("093E0FAE-A6C4-4F50-9F1B-D41E2B89C19A", "SHA-512"),
            ("3BD2A492-96C0-4079-B420-FCF98EF103ED", "X.509 + SHA-256"),
            ("7076876E-80C2-4EE6-AAD2-28B349A6865B", "X.509 + SHA-384"),
            ("446DBF63-2502-4CDA-BCFA-2465D2B0FE9D", "X.509 + SHA-512"),
        ] {
            types[EFIGUID(guid)!] = name
        }
        return types
    }()
}

/// Just enough DER to name a certificate: its subject's common name, or its
/// organisation where it has no common name.
enum X509 {
    static func subject(_ der: [UInt8]) -> String? {
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version
        // OPTIONAL, serial, signature, issuer, validity, subject, … } … }
        guard let certificate = element(der, at: 0), certificate.tag == 0x30,
              let tbs = element(der, at: certificate.content.lowerBound), tbs.tag == 0x30
        else { return nil }
        var at = tbs.content.lowerBound
        if let version = element(der, at: at), version.tag == 0xA0 { at = version.end }
        // Serial, signature, issuer, validity, subject.
        var fields: [Element] = []
        while fields.count < 5, at < tbs.end, let field = element(der, at: at) {
            fields.append(field)
            at = field.end
        }
        guard fields.count == 5, fields[4].tag == 0x30 else { return nil }
        let subject = fields[4].content
        return attribute([0x55, 0x04, 0x03], in: subject, of: der)
            ?? attribute([0x55, 0x04, 0x0A], in: subject, of: der)
    }

    /// The value of the attribute `oid` names in a Name: SEQUENCE OF SET OF
    /// SEQUENCE { OID, value }.
    private static func attribute(_ oid: [UInt8], in name: Range<Int>, of der: [UInt8]) -> String? {
        var at = name.lowerBound
        while at < name.upperBound, let set = element(der, at: at) {
            var inner = set.content.lowerBound
            while inner < set.content.upperBound, let pair = element(der, at: inner) {
                if let id = element(der, at: pair.content.lowerBound), id.tag == 0x06,
                   der[id.content].elementsEqual(oid), let value = element(der, at: id.end) {
                    return string(Array(der[value.content]), tag: value.tag)
                }
                inner = pair.end
            }
            at = set.end
        }
        return nil
    }

    private static func string(_ bytes: [UInt8], tag: UInt8) -> String? {
        switch tag {
        case 0x0C, 0x13, 0x16, 0x14: return String(decoding: bytes, as: UTF8.self)
        case 0x1E:
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
            return String(decoding: units, as: UTF16.self)
        default: return nil
        }
    }

    private struct Element {
        var tag: UInt8
        var content: Range<Int>
        var end: Int { content.upperBound }
    }

    private static func element(_ der: [UInt8], at: Int) -> Element? {
        guard at + 2 <= der.count else { return nil }
        let tag = der[at]
        var length = Int(der[at + 1])
        var start = at + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), start + count <= der.count else { return nil }
            length = der[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard start + length <= der.count else { return nil }
        return Element(tag: tag, content: start..<(start + length))
    }
}
