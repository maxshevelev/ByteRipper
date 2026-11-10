import Foundation

/// Whether an EDK2 library function's plate cites its source truly: the
/// `Evidence: <Function>, <path>:<line>` line names a file of the pinned tag
/// and the line in it that holds the function's definition.
///
/// The check reads a checkout of the tag and nothing else; it never searches
/// for the function on its own behalf, only says where the cited one is
/// defined when the file defines it once. Finding the source and judging that
/// the body matches it stays the reviewer's.
///
/// A checkout may hold part of the tag: `files.txt` at its root, when there,
/// lists every path the tag has, so a file the tag has and the checkout left
/// out is told apart from one the tag does not have.
public enum EDK2Evidence {
    public static let listingName = "files.txt"

    public enum Outcome: String, Codable, Sendable {
        /// The cited line holds the function's definition.
        case ok
        /// The plate has no `Evidence:` line.
        case noEvidence = "no_evidence"
        /// An `Evidence:` line not in the form `<Function>, <path>:<line>`.
        case unparseable
        /// The tag has no file at that path.
        case fileNotAtTag = "file_not_at_tag"
        /// The tag has the file, this checkout does not hold it.
        case notInCheckout = "not_in_checkout"
        /// The file is there and the line is not the function's definition.
        case notDefinition = "not_definition"
    }

    public struct Citation: Codable, Equatable, Sendable {
        public var function: String
        public var path: String
        public var line: Int
    }

    public struct Finding: Codable, Equatable, Sendable {
        public var outcome: Outcome
        /// The `Evidence:` line as the plate has it; nil when there is none.
        public var evidence: String?
        public var citation: Citation?
        /// Where the file defines the function, when it defines it exactly once
        /// and not at the cited line.
        public var definedAt: Int?
        /// How many definitions of the function the file holds, for a
        /// `not_definition`.
        public var definitions: Int?

        enum CodingKeys: String, CodingKey {
            case outcome, evidence, citation, definitions
            case definedAt = "defined_at"
        }
    }

    // MARK: - The plate

    /// Every `Evidence:` line of a plate, each read as a citation or not.
    public static func evidenceLines(in plate: String) -> [(text: String, citation: Citation?)] {
        plate.split(whereSeparator: \.isNewline).compactMap { raw -> (String, Citation?)? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "Evidence:") else { return nil }
            let text = String(line[range.lowerBound...])
            return (text, citation(String(line[range.upperBound...])))
        }
    }

    /// `GetFirstGuidHob, MdePkg/Library/PeiHobLib/HobLib.c:181.` → the citation; a
    /// remark may follow the line number.
    static func citation(_ text: String) -> Citation? {
        // What follows the line number is the reviewer's: an inlined callee,
        // a difference from the source.
        let pattern = #"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z0-9_][A-Za-z0-9_./+-]*):([0-9]+)(?![0-9]|-[0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
        let path = group(2)
        guard !path.split(separator: "/").contains(".."), let line = Int(group(3)), line > 0 else { return nil }
        return Citation(function: group(1), path: path, line: line)
    }

    // MARK: - The check

    /// The findings for a plate: one per `Evidence:` line, or one
    /// `no_evidence` when it has none.
    public static func check(plate: String, checkout: URL) -> [Finding] {
        let lines = evidenceLines(in: plate)
        guard !lines.isEmpty else { return [Finding(outcome: .noEvidence)] }
        let listing = self.listing(checkout)
        return lines.map { text, citation in
            guard let citation else { return Finding(outcome: .unparseable, evidence: text) }
            return check(citation, evidence: text, checkout: checkout, listing: listing)
        }
    }

    static func check(_ citation: Citation, evidence: String, checkout: URL, listing: Set<String>?) -> Finding {
        var finding = Finding(outcome: .ok, evidence: evidence, citation: citation)
        let file = checkout.appendingPathComponent(citation.path)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            let atTag = listing?.contains(citation.path) ?? false
            finding.outcome = atTag ? .notInCheckout : .fileNotAtTag
            return finding
        }
        let text = String(decoding: data, as: UTF8.self)
        let found = definitions(of: citation.function, in: text, path: citation.path)
        if found.contains(citation.line) { return finding }
        finding.outcome = .notDefinition
        finding.definitions = found.count
        if found.count == 1 { finding.definedAt = found[0] }
        return finding
    }

    static func listing(_ checkout: URL) -> Set<String>? {
        guard let data = FileManager.default.contents(atPath: checkout.appendingPathComponent(listingName).path)
        else { return nil }
        return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
    }

    // MARK: - The registry

    /// One registry entry the audit found short.
    public struct EntryFinding: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: Int
        public var module: String
        public var rev: Int?
        public var address: String
        public var findings: [Finding]
    }

    public struct Audit: Codable, Equatable, Sendable {
        public var checked: Int
        public var outcomes: [String: Int]
        /// The entries with at least one finding that is not `ok`.
        public var entries: [EntryFinding]
    }

    /// Every `edk2` entry's current plate, checked. Reads only: the index and
    /// each entry's object.
    public static func audit(_ index: LibraryIndex, object: (SHA256Digest) throws -> Data,
                             checkout: URL) throws -> Audit {
        var audit = Audit(checked: 0, outcomes: [:], entries: [])
        for (id, entry) in index.entries.sorted(by: { ($0.value.name, $0.key) < ($1.value.name, $1.key) })
        where entry.kind == "edk2" {
            let review = (try? JSONSerialization.jsonObject(with: try object(entry.entry))) as? [String: Any]
            let findings = check(plate: review?["plate"] as? String ?? "", checkout: checkout)
            audit.checked += 1
            for finding in findings { audit.outcomes[finding.outcome.rawValue, default: 0] += 1 }
            guard findings.contains(where: { $0.outcome != .ok }) else { continue }
            audit.entries.append(EntryFinding(id: id, name: entry.name, version: entry.version,
                                              module: entry.source.module.hex, rev: entry.source.rev,
                                              address: entry.source.address, findings: findings))
        }
        return audit
    }

    // MARK: - Definitions in a file

    static let assemblyExtensions: Set<String> = ["nasm", "asm", "s", "inc", "nasmb"]

    /// The 1-based lines of a file that define `name`: in C the line that
    /// holds the name of a function whose parameter list a body follows, in
    /// assembly the function's label.
    public static func definitions(of name: String, in text: String, path: String) -> [Int] {
        let ext = (path as NSString).pathExtension.lowercased()
        return assemblyExtensions.contains(ext) ? assemblyLabels(of: name, in: text)
            : cDefinitions(of: name, in: text)
    }

    static func assemblyLabels(of name: String, in text: String) -> [Int] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [#"^\s*ASM_PFX\(\s*"# + escaped + #"\s*\)\s*:"#,
                        #"^\s*"# + escaped + #"\s*:"#,
                        #"^\s*"# + escaped + #"\s+PROC\b"#,
                        #"^\s*global\s+ASM_PFX\(\s*"# + escaped + #"\s*\)"#]
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        var found: [Int] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) { found.append(index + 1) }
        }
        return found
    }

    /// C with comments and string literals blanked, newlines kept, so a
    /// position still names its line.
    static func blanked(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        var index = 0
        func blank(_ at: Int) { if bytes[at] != UInt8(ascii: "\n") { bytes[at] = UInt8(ascii: " ") } }
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { blank(index); index += 1 }
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                blank(index); blank(index + 1); index += 2
                while index < bytes.count,
                      !(bytes[index] == UInt8(ascii: "*") && index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/")) {
                    blank(index); index += 1
                }
                if index < bytes.count { blank(index); blank(index + 1); index += 2 }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                index += 1
                while index < bytes.count, bytes[index] != byte, bytes[index] != UInt8(ascii: "\n") {
                    if bytes[index] == UInt8(ascii: "\\") { blank(index); index += 1 }
                    if index < bytes.count { blank(index) }
                    index += 1
                }
                index += 1
            } else {
                index += 1
            }
        }
        return bytes
    }

    static func cDefinitions(of name: String, in text: String) -> [Int] {
        let bytes = blanked(text)
        let target = Array(name.utf8)
        func isIdentifier(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
        }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        var found: [Int] = []
        var index = 0
        var line = 1
        var lineStart = 0
        while index + target.count <= bytes.count {
            if bytes[index] == 0x0A { line += 1; lineStart = index + 1; index += 1; continue }
            guard bytes[index] == target[0], Array(bytes[index..<index + target.count]) == target,
                  index == 0 || !isIdentifier(bytes[index - 1]),
                  index + target.count == bytes.count || !isIdentifier(bytes[index + target.count]) else {
                index += 1
                continue
            }
            // Before the name on its line: only the return type's words.
            let before = bytes[lineStart..<index]
            let typeOnly = before.allSatisfy { isIdentifier($0) || isSpace($0) || $0 == UInt8(ascii: "*") }
            // Before the line: nothing that leaves an expression open.
            var back = lineStart - 1
            while back >= 0, isSpace(bytes[back]) { back -= 1 }
            let opener = back >= 0 ? bytes[back] : UInt8(ascii: ";")
            let afterStatement = isIdentifier(opener) || [UInt8(ascii: ";"), UInt8(ascii: "}"), UInt8(ascii: "{"),
                                                          UInt8(ascii: "*"), UInt8(ascii: ")")].contains(opener)
            var cursor = index + target.count
            while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
            if typeOnly, afterStatement, cursor < bytes.count, bytes[cursor] == UInt8(ascii: "(") {
                var depth = 0
                while cursor < bytes.count {
                    if bytes[cursor] == UInt8(ascii: "(") { depth += 1 }
                    if bytes[cursor] == UInt8(ascii: ")") { depth -= 1; if depth == 0 { break } }
                    cursor += 1
                }
                cursor += 1
                while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "{") { found.append(line) }
            }
            index += target.count
        }
        return found
    }
}
