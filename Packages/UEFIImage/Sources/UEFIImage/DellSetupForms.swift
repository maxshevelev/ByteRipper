import Foundation

/// What Dell's BIOS Setup says a DVAR variable is (`UEFI_IMAGE_FORMAT.md` §9).
///
/// A DVAR variable is only a number in a namespace. The firmware's Setup
/// pages are what give it a meaning: Dell's forms are standard HII — an IFR
/// form package per page and string packages beside them, compiled into the
/// driver that publishes them (`DellSetupFormSets`) — and each question that
/// is kept in DVAR is followed, at its own level, by a GUID opcode of Dell's
/// (`A5D58BCF-…`, subtype `0x1D`) naming the namespace and the name id. So the
/// question's prompt, its help, the page it is on and, for a list, the text
/// of each value are all in the dump, in the image's own words.
///
/// The `x-UEFI` strings, where the driver has them, are each question's
/// keyword — `AllowBiosDowngrade`, `AutoOnSun` — the name Dell's own tools set
/// the option by. A prompt is the line on its page and is often meaningless
/// alone ("Sunday", "Clear"); the keyword is not.
///
/// Read off the bytes as they are, with no driver run: a prompt a driver
/// fills in at run time reads as whatever placeholder was compiled in.
public enum DellSetup {
    /// The GUID of Dell's IFR opcodes.
    static let opcodeGuid = EFIGUID("A5D58BCF-EB5C-44FC-9122-CA4369B9ABE6")!
    /// The opcode that ties the question before it to a DVAR variable:
    /// subtype, the namespace's GUID, a 32-bit name id.
    static let bindsVariable: UInt8 = 0x1D

    public struct Key: Hashable, Sendable {
        public var namespace: EFIGUID
        public var nameId: UInt32

        public init(namespace: EFIGUID, nameId: UInt32) {
            self.namespace = namespace
            self.nameId = nameId
        }
    }

    /// One Setup question, as its page shows it.
    public struct Setting: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case checkbox, oneOf, numeric, string, other
        }

        public struct Option: Equatable, Sendable {
            public var value: UInt64
            public var text: String

            public init(value: UInt64, text: String) {
                self.value = value
                self.text = text
            }
        }

        /// The line on the page, in English.
        public var prompt: String
        /// The `x-UEFI` keyword, when the driver has one for the question.
        public var keyword: String?
        public var help: String?
        /// The title of the page the question is on.
        public var form: String?
        public var kind: Kind
        /// A list's values and what each is called, in the page's order.
        public var options: [Option]

        public init(prompt: String, keyword: String? = nil, help: String? = nil, form: String? = nil,
                    kind: Kind, options: [Option] = []) {
            self.prompt = prompt
            self.keyword = keyword
            self.help = help
            self.form = form
            self.kind = kind
            self.options = options
        }

        /// What a row is called: the keyword, which is unambiguous, and the
        /// prompt where there is none.
        public var name: String { keyword ?? prompt }

        /// The text of the option `value` is, for a list.
        public func option(for value: UInt64) -> String? {
            options.first { $0.value == value }?.text
        }
    }

    /// Every setting the image's forms tie to a DVAR variable.
    public struct Catalogue: Equatable, Sendable {
        public var settings: [Key: Setting]

        public init(settings: [Key: Setting] = [:]) {
            self.settings = settings
        }

        public var isEmpty: Bool { settings.isEmpty }

        /// The setting a DVAR entry holds, by the namespace and name id its
        /// row was given. Nil for an entry the tree could not place in a
        /// namespace, and for one no page asks about.
        public func setting(for entry: UEFINode) -> Setting? {
            guard entry.kind == .dvarEntry, let namespace = entry.guid else { return nil }
            return setting(namespace: namespace, nameId: entry.name)
        }

        /// The setting of the variable `nameId` — in hex, as a row names it —
        /// in `namespace`.
        public func setting(namespace: EFIGUID, nameId: String) -> Setting? {
            UInt32(nameId, radix: 16).flatMap { settings[Key(namespace: namespace, nameId: $0)] }
        }
    }

    /// The settings of every driver in `image` that carries Dell's opcode —
    /// read over the sections the tree has materialized, so a caller that
    /// wants them all opens everything first.
    public static func read(_ image: UEFIImage, readers: SpaceReaders) -> Catalogue {
        var settings: [Key: Setting] = [:]
        let pattern = opcodeGuid.bytes
        for node in image.allNodes where node.kind == .section && node.subtype == pe32Section {
            guard let reader = readers.reader(for: node.space),
                  let body = reader.bytes(node.body), contains(pattern, in: body) else { continue }
            settings.merge(Self.settings(in: body)) { first, _ in first }
        }
        return Catalogue(settings: settings)
    }

    /// The settings one driver's bytes define: its string packages, and the
    /// questions of its form packages that Dell's opcode ties to a variable.
    public static func settings(in bytes: [UInt8]) -> [Key: Setting] {
        let strings = stringPackages(in: bytes)
        let text = strings.first { $0.language == "en-US" }
            ?? strings.first { $0.language.hasPrefix("en") }
            ?? strings.first { !$0.language.hasPrefix("x-") }
        let keywords = strings.first { $0.language == "x-UEFI" }
        func string(_ id: UInt16) -> String? {
            text?.strings[id].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func keyword(_ id: UInt16) -> String? {
            // Some carry a condition after the word: `TpmClear[SuppressIf:…]`.
            guard let raw = keywords?.strings[id] else { return nil }
            let word = raw.prefix { $0 != "[" }.trimmingCharacters(in: .whitespaces)
            return word.isEmpty ? nil : word
        }

        var settings: [Key: Setting] = [:]
        for form in formPackages(in: bytes) {
            for question in questions(in: form, of: bytes) {
                let prompt = string(question.prompt)
                let keyword = keyword(question.prompt)
                guard let name = prompt ?? keyword else { continue }
                let setting = Setting(
                    prompt: name,
                    keyword: keyword,
                    help: string(question.help),
                    form: question.form.flatMap(string),
                    kind: question.kind,
                    options: question.options.map { Setting.Option(value: $0.value, text: string($0.text) ?? "") }
                )
                for key in question.keys where settings[key] == nil {
                    settings[key] = setting
                }
            }
        }
        return settings
    }

    // MARK: - HII string packages

    static let pe32Section: UInt8 = 0x10

    struct StringPackage {
        var language: String
        var strings: [UInt16: String]
    }

    /// `EFI_HII_PACKAGE_STRINGS`: a header whose size is where the strings
    /// start, a language tag, and string blocks up to an end block.
    static func stringPackages(in bytes: [UInt8]) -> [StringPackage] {
        var found: [StringPackage] = []
        var offset = 0
        while offset + 48 <= bytes.count {
            defer { offset += 1 }
            guard bytes[offset + 3] == 0x04 else { continue }
            let length = Int(u24(bytes, offset)), headerSize = Int(u32(bytes, offset + 4))
            guard headerSize == Int(u32(bytes, offset + 8)), (48...0x100).contains(headerSize),
                  length > headerSize, offset + length <= bytes.count else { continue }
            // The language: printable ASCII, ending inside the header.
            let tag = bytes[(offset + 46)..<(offset + headerSize)].prefix { $0 != 0 }
            guard !tag.isEmpty, tag.count < headerSize - 46, tag.allSatisfy({ (0x21...0x7E).contains($0) }),
                  let strings = stringBlocks(bytes, from: offset + headerSize, to: offset + length)
            else { continue }
            found.append(StringPackage(language: String(decoding: tag, as: UTF8.self), strings: strings))
            offset += length - 1
        }
        return found
    }

    /// The string blocks from `start` up to the end block, by id; nil when
    /// they do not read as blocks up to one inside `end`.
    private static func stringBlocks(_ bytes: [UInt8], from start: Int, to end: Int) -> [UInt16: String]? {
        var strings: [UInt16: String] = [:]
        var id: UInt16 = 1
        var at = start
        func ucs2(_ from: Int) -> (String, Int)? {
            var cursor = from
            var units: [UInt16] = []
            while cursor + 1 < end {
                let unit = UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8
                cursor += 2
                if unit == 0 { return (String(decoding: units, as: UTF16.self), cursor) }
                units.append(unit)
            }
            return nil
        }
        func scsu(_ from: Int) -> (String, Int)? {
            guard let zero = bytes[from..<end].firstIndex(of: 0) else { return nil }
            return (String(decoding: bytes[from..<zero], as: UTF8.self), zero + 1)
        }
        func take(_ read: (Int) -> (String, Int)?, count: Int, from: Int) -> Int? {
            var cursor = from
            for _ in 0..<count {
                guard let (string, next) = read(cursor) else { return nil }
                strings[id] = string
                id &+= 1
                cursor = next
            }
            return cursor
        }
        while at < end {
            let type = bytes[at]
            var next: Int?
            switch type {
            case 0x00: return strings                                   // end
            case 0x10: next = take(scsu, count: 1, from: at + 1)
            case 0x11: next = take(scsu, count: 1, from: at + 2)        // + font
            case 0x12 where at + 3 <= end:
                next = take(scsu, count: Int(u16(bytes, at + 1)), from: at + 3)
            case 0x13 where at + 4 <= end:
                next = take(scsu, count: Int(u16(bytes, at + 2)), from: at + 4)
            case 0x14: next = take(ucs2, count: 1, from: at + 1)
            case 0x15: next = take(ucs2, count: 1, from: at + 2)
            case 0x16 where at + 3 <= end:
                next = take(ucs2, count: Int(u16(bytes, at + 1)), from: at + 3)
            case 0x17 where at + 4 <= end:
                next = take(ucs2, count: Int(u16(bytes, at + 2)), from: at + 4)
            case 0x20 where at + 3 <= end:                              // duplicate
                strings[id] = strings[u16(bytes, at + 1)]
                id &+= 1
                next = at + 3
            case 0x21 where at + 3 <= end: id &+= u16(bytes, at + 1); next = at + 3   // skip2
            case 0x22 where at + 2 <= end: id &+= UInt16(bytes[at + 1]); next = at + 2 // skip1
            case 0x30 where at + 3 <= end: next = at + Int(bytes[at + 2])              // ext1
            case 0x31 where at + 4 <= end: next = at + Int(u16(bytes, at + 2))         // ext2
            case 0x32 where at + 6 <= end: next = at + Int(u32(bytes, at + 2))         // ext4
            default: next = nil
            }
            guard let next, next > at, next <= end else { return nil }
            at = next
        }
        return nil
    }

    // MARK: - IFR form packages

    /// `EFI_HII_PACKAGE_FORMS` that open on a form set and whose opcodes run
    /// exactly to their end, with every scope closed.
    static func formPackages(in bytes: [UInt8]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            defer { offset += 1 }
            guard bytes[offset + 3] == 0x02, bytes[offset + 4] == formSetOp else { continue }
            let length = Int(u24(bytes, offset))
            guard length > 8, offset + length <= bytes.count else { continue }
            var at = offset + 4, depth = 0
            while at + 2 <= offset + length {
                let size = Int(bytes[at + 1] & 0x7F)
                guard size >= 2 else { break }
                if bytes[at + 1] & 0x80 != 0 { depth += 1 }
                if bytes[at] == endOp { depth -= 1 }
                at += size
            }
            guard at == offset + length, depth == 0 else { continue }
            found.append((offset + 4)..<(offset + length))
            offset += length - 1
        }
        return found
    }

    static let formSetOp: UInt8 = 0x0E
    static let formOp: UInt8 = 0x01
    static let oneOfOptionOp: UInt8 = 0x09
    static let guidOp: UInt8 = 0x5F
    static let endOp: UInt8 = 0x29
    static let questionKinds: [UInt8: Setting.Kind] = [
        0x05: .oneOf, 0x06: .checkbox, 0x07: .numeric, 0x1C: .string,
        0x08: .other, 0x1A: .other, 0x1B: .other, 0x23: .other,
    ]

    struct Question {
        var prompt: UInt16
        var help: UInt16
        var form: UInt16?
        var kind: Setting.Kind
        var options: [(value: UInt64, text: UInt16)] = []
        var keys: [Key] = []
    }

    /// The questions of one form package that Dell's opcode ties to a
    /// variable. The opcode follows the question it is about at the
    /// question's own level, right after the question's scope closes — or
    /// right after the question, when it has none — so it ties to the
    /// question just finished, and any other opcode in between unties it.
    static func questions(in form: Range<Int>, of bytes: [UInt8]) -> [Question] {
        /// An open scope: the question it belongs to, if any, and the title
        /// of the page it is on.
        struct Scope {
            var question: Int?
            var form: UInt16?
        }
        var questions: [Question] = []
        var scopes: [Scope] = []
        var finished: Int?
        var at = form.lowerBound
        while at + 2 <= form.upperBound {
            let op = bytes[at], size = Int(bytes[at + 1] & 0x7F), opensScope = bytes[at + 1] & 0x80 != 0
            let next = at + size
            guard size >= 2, next <= form.upperBound else { break }
            var opened: Int?
            var isBinding = false

            if op == guidOp, size >= 39, bytes[(at + 2)..<(at + 18)].elementsEqual(opcodeGuid.bytes),
               bytes[at + 18] == bindsVariable {
                isBinding = true
                if let finished {
                    let namespace = EFIGUID(bytes: Array(bytes[(at + 19)..<(at + 35)]))
                    questions[finished].keys.append(Key(namespace: namespace, nameId: u32(bytes, at + 35)))
                }
            } else if let kind = questionKinds[op], size >= 13 {
                questions.append(Question(prompt: u16(bytes, at + 2), help: u16(bytes, at + 4),
                                          form: scopes.last?.form, kind: kind))
                opened = questions.count - 1
            } else if op == oneOfOptionOp, size >= 7,
                      let owner = scopes.last(where: { $0.question != nil })?.question {
                let value: UInt64
                switch bytes[at + 5] {
                case 1 where size >= 8: value = UInt64(u16(bytes, at + 6))
                case 2 where size >= 10: value = UInt64(u32(bytes, at + 6))
                case 3 where size >= 14: value = UInt64(u32(bytes, at + 6)) | UInt64(u32(bytes, at + 10)) << 32
                default: value = UInt64(bytes[at + 6])
                }
                questions[owner].options.append((value, u16(bytes, at + 2)))
            }

            if !isBinding { finished = nil }
            if opensScope {
                let title = op == formOp && size >= 6 ? u16(bytes, at + 4) : scopes.last?.form
                scopes.append(Scope(question: opened, form: title))
            } else if let opened {
                finished = opened
            }
            if op == endOp, let closed = scopes.popLast(), let question = closed.question {
                finished = question
            }
            at = next
        }
        return questions.filter { !$0.keys.isEmpty }
    }

    // MARK: - Bytes

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u24(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(u16(bytes, at)) | UInt32(u16(bytes, at + 2)) << 16
    }

    private static func contains(_ pattern: [UInt8], in bytes: [UInt8]) -> Bool {
        guard let first = pattern.first, bytes.count >= pattern.count else { return false }
        var at = 0
        while let hit = bytes[at...].firstIndex(of: first), hit + pattern.count <= bytes.count {
            if bytes[hit..<(hit + pattern.count)].elementsEqual(pattern) { return true }
            at = hit + 1
        }
        return false
    }
}
