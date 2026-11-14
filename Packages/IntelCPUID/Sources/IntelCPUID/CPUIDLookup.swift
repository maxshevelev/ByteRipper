import Foundation

/// The search the Intel CPUID Lookup window runs over the tables: the same
/// rules as the repository's lookup page (`index.html` of IntelCPUID), so a
/// query finds the same rows in both.
///
/// A query is split into words; a row matches when every word is in its
/// CPUID, model, S-SPECs, code names or steppings, with case, spaces and
/// punctuation ignored — `i72600k` finds `Core i7-2600K`. A CPUID written with
/// an `X` (`606AX`) matches any digit there. Built once per installed table.
public struct CPUIDLookup: Sendable {
    /// One model under one entry: a row of the window's table.
    public struct Row: Equatable, Sendable {
        /// The entry's place in `families`.
        public var entry: Int
        public var cpuids: [String]
        /// Without the `Intel ` every name starts with.
        public var name: String
        public var sSpecs: [String]
        public var steppings: String
        public var codeNames: String
        /// A line that names a series rather than its models.
        public var series: Bool
        fileprivate var haystack: String
        fileprivate var patterns: [String]
    }

    /// A completion offered under the search field.
    public struct Hint: Equatable, Sendable {
        public enum Kind: Int, Sendable { case cpuid, sSpec, model, codeName }
        public var kind: Kind
        public var text: String
        /// Said beside it, quieter: an S-SPEC's model, a model's CPUID, a
        /// CPUID's code name, a code name's CPUIDs.
        public var detail: String
        fileprivate var normalized: String
    }

    /// What the window shows over its table for a query that is one CPUID.
    public struct Heading: Equatable, Sendable {
        /// The entry, when the table has one for the CPUID.
        public var family: ProcessorFamily?
        /// The CPUID the query names — the entry's own, or one no entry has
        /// but a microcode update names.
        public var cpuids: [String]
        /// The updates that serve these CPUIDs and others, newest first, with
        /// the others each names.
        public var shared: [(update: MicrocodeSignatures.Update, others: [String])]
        public var notes: EntryNotes?

        public static func == (a: Heading, b: Heading) -> Bool {
            a.family == b.family && a.cpuids == b.cpuids && a.notes == b.notes
                && a.shared.map(\.update) == b.shared.map(\.update) && a.shared.map(\.others) == b.shared.map(\.others)
        }
    }

    public let tables: ProcessorTables
    public let rows: [Row]
    public let hints: [Hint]

    public init(tables: ProcessorTables) {
        self.tables = tables
        var rows: [Row] = []
        var hints: [Hint] = []
        var seen: [Hint.Kind: Set<String>] = [:]
        func hint(_ kind: Hint.Kind, _ text: String, _ detail: String) {
            guard seen[kind, default: []].insert(text).inserted else { return }
            hints.append(Hint(kind: kind, text: text, detail: detail, normalized: Self.normalize(text)))
        }
        for (index, family) in tables.families.enumerated() {
            let cpuids = family.cpuids.joined(separator: ", ")
            let codeNames = family.codeNames.joined(separator: ", ")
            let steppings = family.steppings.joined(separator: ", ")
            family.cpuids.forEach { hint(.cpuid, $0, family.codeNames.first ?? "") }
            family.codeNames.forEach { hint(.codeName, $0, cpuids) }
            let patterns = family.cpuids.filter { $0.contains("X") }.map { $0.lowercased() }
            for model in family.processors {
                let name = model.shortName
                rows.append(Row(
                    entry: index, cpuids: family.cpuids, name: name, sSpecs: model.sSpec,
                    steppings: steppings, codeNames: codeNames, series: model.series == true,
                    haystack: [Self.normalize(cpuids), Self.normalize(model.name),
                               model.sSpec.map(Self.normalize).joined(separator: "|"),
                               Self.normalize(codeNames), Self.normalize(steppings)].joined(separator: "|"),
                    patterns: patterns))
                if model.series != true { hint(.model, name, family.cpuids.first ?? "") }
                model.sSpec.forEach { hint(.sSpec, $0, name) }
            }
        }
        self.rows = rows
        self.hints = hints
    }

    /// The models the table lists, series left out.
    public var modelCount: Int { rows.filter { !$0.series }.count }
    /// The CPUIDs the table has entries for, each once.
    public var cpuidCount: Int { Set(tables.families.flatMap(\.cpuids)).count }

    // MARK: - Searching

    /// Lower case, Latin and Cyrillic letters, digits and `+` only: what a
    /// query and a row are compared in.
    public static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { scalar in
            switch scalar {
            case "a"..."z", "0"..."9", "а"..."я", "+": return true
            default: return false
            }
        }.map(Character.init))
    }

    /// The query's words, normalized; the empty ones dropped.
    public static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    /// The rows every word of `query` is in, in the table's order. An empty
    /// query is every row.
    public func rows(matching query: String) -> [Row] {
        let words = Self.words(query)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in words.allSatisfy { row.matches($0) } }
    }

    /// What the window says over the table for `query`: the entries whose
    /// CPUID the query is, whole — or, where no entry has it, the CPUID as a
    /// microcode update names it. Empty for anything else.
    public func headings(for query: String) -> [Heading] {
        let words = Self.words(query)
        guard words.count == 1, let word = words.first else { return [] }
        let named = tables.families.filter { family in family.cpuids.contains { Self.normalize($0) == word } }
        if !named.isEmpty {
            return named.map { family in
                Heading(family: family, cpuids: family.cpuids, shared: shared(family.cpuids),
                        notes: tables.notes(on: family))
            }
        }
        guard let lone = tables.microcode.cpuids.first(where: { Self.normalize($0) == word }) else { return [] }
        return [Heading(family: nil, cpuids: [lone], shared: shared([lone]), notes: nil)]
    }

    private func shared(_ cpuids: [String]) -> [(update: MicrocodeSignatures.Update, others: [String])] {
        var seen: [MicrocodeSignatures.Update] = []
        for cpuid in cpuids {
            for update in tables.microcode.updates(serving: cpuid) where !seen.contains(update) {
                seen.append(update)
            }
        }
        return seen.map { ($0, $0.others(than: cpuids)) }
    }

    /// Up to `limit` completions of `query`: those that start with it before
    /// those that only contain it; CPUIDs, then S-SPECs, models and code
    /// names; the shorter first. Nothing that is the query already.
    public func hints(for query: String, limit: Int = 8) -> [Hint] {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return [] }
        func rank(_ hint: Hint) -> Int { (hint.normalized.hasPrefix(query) ? 1 : 2) * 10 + hint.kind.rawValue }
        return hints
            .filter { $0.normalized.contains(query) && $0.normalized != query }
            .sorted { a, b in
                let (ra, rb) = (rank(a), rank(b))
                if ra != rb { return ra < rb }
                if a.text.count != b.text.count { return a.text.count < b.text.count }
                return a.text.localizedStandardCompare(b.text) == .orderedAscending
            }
            .prefix(limit).map { $0 }
    }

    /// The stretches of `text` the words of `query` are found in, as the
    /// text is written: a word may span characters the search ignores —
    /// `i72600` lights `i7-2600`.
    public static func highlights(in text: String, query: String) -> [Range<String.Index>] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        var flat: [Character] = []
        var origin: [String.Index] = []
        for index in text.indices {
            for character in normalize(String(text[index])) {
                flat.append(character)
                origin.append(index)
            }
        }
        var lit = Set<String.Index>()
        for word in words.map(Array.init) where word.count <= flat.count {
            for start in 0...(flat.count - word.count) where Array(flat[start..<start + word.count]) == word {
                // From its first character to its last as written, the
                // ignored ones between included.
                var index = origin[start]
                let last = origin[start + word.count - 1]
                while index <= last {
                    lit.insert(index)
                    index = text.index(after: index)
                }
            }
        }
        var ranges: [Range<String.Index>] = []
        var open: String.Index?
        for index in text.indices {
            if lit.contains(index) {
                if open == nil { open = index }
            } else if let start = open {
                ranges.append(start..<index)
                open = nil
            }
        }
        if let start = open { ranges.append(start..<text.endIndex) }
        return ranges
    }
}

private extension CPUIDLookup.Row {
    func matches(_ word: String) -> Bool {
        haystack.contains(word) || patterns.contains { pattern in
            pattern.count == word.count && zip(pattern, word).allSatisfy { p, w in
                p == "x" ? w.isHexDigit : p == w
            }
        }
    }
}

/// The last searches, newest first — what the search field offers before
/// anything is typed.
public enum SearchHistory {
    public static let limit = 10

    /// `query` put first. It replaces itself and what was typed on the way to
    /// it (`SR0` before `SR00C`); the oldest falls off past `limit`.
    public static func remembering(_ query: String, in history: [String]) -> [String] {
        let query = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalized = CPUIDLookup.normalize(query)
        guard !normalized.isEmpty else { return history }
        let rest = history.filter { !normalized.hasPrefix(CPUIDLookup.normalize($0)) }
        return Array(([query] + rest).prefix(limit))
    }
}
