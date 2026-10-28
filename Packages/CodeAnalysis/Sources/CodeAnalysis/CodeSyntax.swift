import Foundation

/// One coloured, perhaps clickable, stretch of a line of code: where it is in
/// UTF-16 units — the units an attributed string counts — what it is, and
/// where a click on it goes.
public struct CodeToken: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case keyword, comment, type, constant, string, parameter, local
        case function, global, label, mnemonic, address, bytes
        /// An annotation's words beside the code: the agent's, the person's.
        case note, personNote
    }

    public let start: Int
    public let length: Int
    public let kind: Kind
    public let link: CodeLink?

    public init(start: Int, length: Int, kind: Kind, link: CodeLink? = nil) {
        self.start = start
        self.length = length
        self.kind = kind
        self.link = link
    }
}

/// Where a click on a token goes: a function of the module, an instruction
/// of the listing, or bytes of the module that are not code.
public enum CodeLink: Equatable, Hashable, Sendable {
    case function(Int)
    case line(Int)
    case bytes(CodeAddress)
    /// A `goto`'s label: the place in the same function's C where the label
    /// is defined, `NAME:` on a line of its own. By name, since a label the
    /// review renamed no longer spells its address.
    case label(String)
}

extension CodeModel {
    // MARK: - Links

    /// What a reference to `address` leads to: the function that starts
    /// there, the instruction at it, or the module's bytes there. An address
    /// outside the module leads nowhere.
    public func link(to address: CodeAddress) -> CodeLink? {
        if let function = function(at: address) { return .function(function) }
        if let line = line(at: address) { return .line(line) }
        if moduleOffset(of: address) != nil { return .bytes(address) }
        return nil
    }

    // MARK: - C

    /// The tokens of a function's decompiled C. A v4 artifact says what each
    /// token is; an older one is read by a small C lexer that knows the
    /// artifact's function names and Ghidra's `DAT_`/`LAB_` spelling of an
    /// address, so a call is a link either way.
    public func cTokens(ofFunction index: Int) -> [CodeToken] {
        guard functions.indices.contains(index), let c = functions[index].c else { return [] }
        return withLabels(spannedTokens(ofFunction: index, c: c), in: c)
    }

    private func spannedTokens(ofFunction index: Int, c: String) -> [CodeToken] {
        let spans = functions[index].cSpans
        guard !spans.isEmpty else { return lexC(c) }
        let length = c.utf16.count
        var tokens: [CodeToken] = []
        tokens.reserveCapacity(spans.count)
        for span in spans {
            guard let kind = span.kind, span.start + span.length <= length else { continue }
            let link = span.target.flatMap(link(to:))
            switch kind {
            case .keyword: tokens.append(CodeToken(start: span.start, length: span.length, kind: .keyword))
            case .comment: tokens.append(CodeToken(start: span.start, length: span.length, kind: .comment))
            case .type: tokens.append(CodeToken(start: span.start, length: span.length, kind: .type))
            case .constant:
                let text = utf16Slice(c, span.start, span.length)
                let isString = text.hasPrefix("\"") || text.hasPrefix("L\"") || text.hasPrefix("u\"")
                tokens.append(CodeToken(start: span.start, length: span.length,
                                        kind: isString ? .string : .constant))
            case .parameter: tokens.append(CodeToken(start: span.start, length: span.length, kind: .parameter))
            case .local: tokens.append(CodeToken(start: span.start, length: span.length, kind: .local))
            case .function:
                tokens.append(CodeToken(start: span.start, length: span.length, kind: .function,
                                        link: link ?? functionLink(named: utf16Slice(c, span.start, span.length))))
            case .global:
                tokens.append(CodeToken(start: span.start, length: span.length, kind: .global, link: link))
            }
        }
        return tokens
    }

    // MARK: - Labels

    /// `tokens` with the C's labels in them: each `goto NAME;` a link to where
    /// `NAME:` stands, and that definition a label too, so a click on either
    /// highlights both. The decompiler marks no label in its spans, and the
    /// lexer knew only Ghidra's `LAB_` spelling, so they are read off the
    /// text here — read, never rewritten. A `goto` or a colon inside a comment
    /// or a string is not one.
    func withLabels(_ tokens: [CodeToken], in c: String) -> [CodeToken] {
        let text = c as NSString
        let whole = NSRange(location: 0, length: text.length)
        let quoted = tokens.filter { $0.kind == .comment || $0.kind == .string }
        func isQuoted(_ range: NSRange) -> Bool {
            quoted.contains { NSIntersectionRange(NSRange(location: $0.start, length: $0.length), range).length > 0 }
        }
        var labels: [CodeToken] = []
        var defined: Set<String> = []
        for match in Self.labelDefinition.matches(in: c, range: whole) {
            let range = match.range(at: 1)
            let name = text.substring(with: range)
            guard !Self.cKeywords.contains(name), !isQuoted(range) else { continue }
            defined.insert(name)
            labels.append(CodeToken(start: range.location, length: range.length, kind: .label))
        }
        for match in Self.gotoStatement.matches(in: c, range: whole) {
            let range = match.range(at: 1)
            guard !isQuoted(range) else { continue }
            let name = text.substring(with: range)
            labels.append(CodeToken(start: range.location, length: range.length, kind: .label,
                                    link: defined.contains(name) ? .label(name) : nil))
        }
        guard !labels.isEmpty || tokens.contains(where: { $0.kind == .label }) else { return tokens }
        let taken = labels.map { NSRange(location: $0.start, length: $0.length) }
        let kept = tokens.filter { token in
            token.kind != .label
                && !taken.contains { NSIntersectionRange($0, NSRange(location: token.start, length: token.length)).length > 0 }
        }
        return (kept + labels).sorted { $0.start < $1.start }
    }

    /// `NAME:` alone on its line, as the decompiler writes a label.
    private static let labelDefinition = try! NSRegularExpression(
        pattern: "^[ \\t]*([A-Za-z_][A-Za-z0-9_]*):[ \\t]*$", options: [.anchorsMatchLines])
    /// `goto NAME;`.
    private static let gotoStatement = try! NSRegularExpression(
        pattern: "\\bgoto[ \\t]+([A-Za-z_][A-Za-z0-9_]*)[ \\t]*;")

    private func functionLink(named name: String) -> CodeLink? {
        functionsByName[name].map(CodeLink.function)
    }

    private func utf16Slice(_ text: String, _ start: Int, _ length: Int) -> String {
        let units = text.utf16
        guard let lower = units.index(units.startIndex, offsetBy: start, limitedBy: units.endIndex),
              let upper = units.index(lower, offsetBy: length, limitedBy: units.endIndex)
        else { return "" }
        return String(units[lower..<upper]) ?? ""
    }

    private static let cKeywords: Set<String> = [
        "if", "else", "while", "do", "for", "switch", "case", "default", "break",
        "continue", "return", "goto", "sizeof", "struct", "union", "enum", "typedef",
        "const", "volatile", "static", "extern", "unsigned", "signed"
    ]

    private static let cTypes: Set<String> = [
        "void", "char", "short", "int", "long", "float", "double", "bool", "byte", "word",
        "dword", "qword", "uint", "ushort", "ulong", "uchar", "longlong", "ulonglong",
        "undefined", "undefined1", "undefined2", "undefined4", "undefined8", "code",
        "wchar_t", "wchar16", "size_t", "BOOLEAN", "UINT8", "UINT16", "UINT32", "UINT64",
        "UINTN", "INT8", "INT16", "INT32", "INT64", "INTN", "CHAR8", "CHAR16", "VOID"
    ]

    /// The C lexer for an artifact without spans: comments, strings and
    /// numbers; keywords and types; a function's name as a link to it; and
    /// Ghidra's `DAT_0001f2c0`, `PTR_…`, `LAB_…` as links to the address they
    /// spell.
    public func lexC(_ text: String) -> [CodeToken] {
        let units = Array(text.utf16)
        var tokens: [CodeToken] = []
        var index = 0
        func isIdentifierStart(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
        }
        func isIdentifier(_ unit: UInt16) -> Bool {
            isIdentifierStart(unit) || (unit >= 0x30 && unit <= 0x39)
        }
        while index < units.count {
            let unit = units[index]
            let next: UInt16 = index + 1 < units.count ? units[index + 1] : 0
            if unit == 0x2F, next == 0x2A {                         // /* … */
                var end = index + 2
                while end + 1 < units.count, !(units[end] == 0x2A && units[end + 1] == 0x2F) { end += 1 }
                end = min(units.count, end + 2)
                tokens.append(CodeToken(start: index, length: end - index, kind: .comment))
                index = end
            } else if unit == 0x2F, next == 0x2F {                  // // …
                var end = index
                while end < units.count, units[end] != 0x0A { end += 1 }
                tokens.append(CodeToken(start: index, length: end - index, kind: .comment))
                index = end
            } else if unit == 0x22 || unit == 0x27                  // "…" '…'
                        || (unit == 0x4C && (next == 0x22 || next == 0x27)) {
                let quote = unit == 0x4C ? next : unit
                var end = index + (unit == 0x4C ? 2 : 1)
                while end < units.count, units[end] != quote, units[end] != 0x0A {
                    end += units[end] == 0x5C ? 2 : 1
                }
                end = min(units.count, end + 1)
                tokens.append(CodeToken(start: index, length: end - index, kind: .string))
                index = end
            } else if unit >= 0x30 && unit <= 0x39 {                // 0x1F, 42
                var end = index + 1
                while end < units.count, isIdentifier(units[end]) { end += 1 }
                tokens.append(CodeToken(start: index, length: end - index, kind: .constant))
                index = end
            } else if isIdentifierStart(unit) {
                var end = index + 1
                while end < units.count, isIdentifier(units[end]) { end += 1 }
                let word = String(decoding: units[index..<end], as: UTF16.self)
                if let token = identifierToken(word, start: index) { tokens.append(token) }
                index = end
            } else {
                index += 1
            }
        }
        return tokens
    }

    private func identifierToken(_ word: String, start: Int) -> CodeToken? {
        let length = word.utf16.count
        if Self.cKeywords.contains(word) {
            return CodeToken(start: start, length: length, kind: .keyword)
        }
        if Self.cTypes.contains(word) {
            return CodeToken(start: start, length: length, kind: .type)
        }
        if let index = functionsByName[word] {
            return CodeToken(start: start, length: length, kind: .function, link: .function(index))
        }
        // Ghidra spells an unnamed place by its address.
        for (prefix, kind) in [("DAT_", CodeToken.Kind.global), ("PTR_", .global),
                               ("LAB_", .label), ("FUN_", .function)] where word.hasPrefix(prefix) {
            let digits = word.dropFirst(prefix.count).prefix { $0.isHexDigit }
            guard !digits.isEmpty, let address = CodeAddress(hex: String(digits)) else { continue }
            return CodeToken(start: start, length: length, kind: kind, link: link(to: address))
        }
        if word.hasPrefix("param_") {
            return CodeToken(start: start, length: length, kind: .parameter)
        }
        return nil
    }

    // MARK: - The listing

    /// A listing row and its tokens: the module offset, the bytes, the
    /// mnemonic, and the instruction's targets written as module offsets —
    /// each target a link to the function, instruction or bytes it names.
    public func listingRow(ofLine line: Int) -> (text: String, tokens: [CodeToken]) {
        guard lines.indices.contains(line) else { return ("", []) }
        let instruction = lines[line].instruction
        let address = displayAddress(instruction.address)
        let addressColumn = address.padding(toLength: 10, withPad: " ", startingAt: 0)
        let bytes = instruction.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let byteColumn = bytes.padding(toLength: 26, withPad: " ", startingAt: 0)
        let prefix = addressColumn + "  " + byteColumn + "  "
        let shown = display(instruction)
        var tokens = [
            CodeToken(start: 0, length: address.utf16.count, kind: .address),
            CodeToken(start: addressColumn.utf16.count + 2, length: bytes.utf16.count, kind: .bytes)
        ].filter { $0.length > 0 }
        let base = prefix.utf16.count
        let mnemonicLength = shown.text.utf16.prefix { $0 != 0x20 }.count
        if mnemonicLength > 0 {
            tokens.append(CodeToken(start: base, length: mnemonicLength, kind: .mnemonic))
        }
        for target in shown.targets {
            let kind: CodeToken.Kind
            switch target.link {
            case .function: kind = .function
            case .line, .label: kind = .label
            case .bytes, .none: kind = .global
            }
            tokens.append(CodeToken(start: base + target.start, length: target.length,
                                    kind: kind, link: target.link))
        }
        return (prefix + shown.text, tokens)
    }
}
