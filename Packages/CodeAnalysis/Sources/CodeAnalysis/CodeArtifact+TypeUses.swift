import Foundation

/// Where a stored analysis names a type: what a review has to walk when a name
/// turns out to be false and is taken out of the shared archive. A module that
/// took the type keeps its copy, so each of these still reads the old name until
/// a review changes it.
public struct CodeTypeUses: Encodable, Equatable, Sendable {
    public struct Line: Encodable, Equatable, Sendable {
        public let line: Int
        public let text: String
    }

    /// A function naming the type: in its signature, its C — locals, casts and
    /// its comments alike — or both, with the first lines of the C that do.
    public struct Function: Encodable, Equatable, Sendable {
        public let entry: String
        public let name: String
        public let inSignature: Bool
        public let lines: [Line]
        public let lineCount: Int

        enum CodingKeys: String, CodingKey {
            case entry, name, lines
            case inSignature = "in_signature"
            case lineCount = "line_count"
        }
    }

    /// A datum typed with it, or whose comment names it.
    public struct Datum: Encodable, Equatable, Sendable {
        public let address: String
        public let name: String
        public let type: String?
    }

    public let functions: [Function]
    public let data: [Datum]
    /// The module's other types whose C names it.
    public let types: [String]
    /// Whether the module's own types include it, by one of the names.
    public let holdsTheType: Bool

    enum CodingKeys: String, CodingKey {
        case functions, data, types
        case holdsTheType = "holds_the_type"
    }

    public init(functions: [Function], data: [Datum], types: [String], holdsTheType: Bool) {
        self.functions = functions
        self.data = data
        self.types = types
        self.holdsTheType = holdsTheType
    }

    public var isEmpty: Bool { functions.isEmpty && data.isEmpty && types.isEmpty && !holdsTheType }
}

public extension CodeArtifact {
    /// How many lines of C a function's entry quotes, and how much of each.
    private static var quotedLines: Int { 3 }
    private static var quotedCharacters: Int { 160 }

    /// Where this analysis names any of `names`, whole identifiers only: the
    /// name `PPI` is not found in `EFI_PPI_DESCRIPTOR`.
    func typeUses(of names: Set<String>) -> CodeTypeUses {
        func names_(_ text: String?) -> Bool {
            guard let text else { return false }
            return Self.identifiers(in: text).contains { names.contains(String($0)) }
        }
        var found: [CodeTypeUses.Function] = []
        for function in functions {
            let signature = names_(function.signature)
            var lines: [CodeTypeUses.Line] = []
            var count = 0
            if let c = function.c, names_(c) {
                for (index, line) in c.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where names_(String(line)) {
                    count += 1
                    guard lines.count < Self.quotedLines else { continue }
                    let text = line.trimmingCharacters(in: .whitespaces)
                    lines.append(.init(line: index + 1, text: String(text.prefix(Self.quotedCharacters))))
                }
            }
            guard signature || count > 0 else { continue }
            found.append(.init(entry: function.entry.description, name: function.name, inSignature: signature,
                               lines: lines, lineCount: count))
        }
        let data = symbols.filter { names_($0.type) || names_($0.comment) }.map {
            CodeTypeUses.Datum(address: $0.address.description, name: $0.name, type: $0.type)
        }
        let others = types.filter { !names.contains($0.name) && names_($0.c) }.map(\.name)
        return CodeTypeUses(functions: found, data: data, types: others,
                            holdsTheType: types.contains { names.contains($0.name) })
    }

    private static func identifiers(in text: String) -> [Substring] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
