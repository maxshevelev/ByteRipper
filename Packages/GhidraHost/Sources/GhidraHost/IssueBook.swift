import Foundation

/// What agents report about the tools: a call that answered wrong, refused
/// what it should take, or failed — kept on the server, so that a review pair
/// on a Mac with nobody to fix the tools can still say what went wrong, and
/// whoever does fix them reads it with the call that showed it.
///
/// One file in the store's private part, `private/issues.json`: it goes to no
/// client and no mirror. A report is never changed after it is made; an
/// administrator marks it resolved, with a note.
public actor IssueBook {
    public struct Issue: Codable, Equatable, Sendable {
        public let id: String
        public let at: Date
        /// Who reported it, as a lease names its holder: a token's name, or
        /// the server's local MCP.
        public let reporter: String
        /// The tool that showed it, its arguments as the agent sent them,
        /// what came back, and what the agent expected instead.
        public let tool: String
        public let arguments: String?
        public let answer: String?
        public let expected: String
        public let module: String?
        public let note: String?
        public var resolved: Resolution?

        enum CodingKeys: String, CodingKey {
            case id, at, reporter, tool, arguments, answer, expected, module, note, resolved
        }
    }

    public struct Resolution: Codable, Equatable, Sendable {
        public let by: String
        public let at: Date
        public let note: String?
    }

    /// What a client sends: the issue without what the server sets.
    public struct Report: Codable, Equatable, Sendable {
        public var tool: String
        public var arguments: String?
        public var answer: String?
        public var expected: String
        public var module: String?
        public var note: String?

        public init(tool: String, arguments: String? = nil, answer: String? = nil, expected: String,
                    module: String? = nil, note: String? = nil) {
            self.tool = tool
            self.arguments = arguments
            self.answer = answer
            self.expected = expected
            self.module = module
            self.note = note
        }
    }

    /// How much of each text is kept: an answer is cut, not refused, so a
    /// report of an over-long answer still lands.
    public static let textLimit = 16 << 10
    /// How many reports are kept; the oldest resolved go first.
    public static let capacity = 2000

    private let file: URL
    private var issues: [Issue]

    public init(file: URL) {
        self.file = file
        issues = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode([Issue].self, from: $0) } ?? []
    }

    /// The report kept, with its id and time.
    public func report(_ report: Report, by reporter: String, now: Date = Date()) throws -> Issue {
        let tool = report.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = report.expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { throw GhidraHostError(.refused, "name the tool that showed the problem", status: 400) }
        guard !expected.isEmpty else {
            throw GhidraHostError(.refused, "say what was expected instead", status: 400)
        }
        let issue = Issue(id: String(UUID().uuidString.prefix(8)).lowercased(), at: Self.second(now), reporter: reporter,
                          tool: String(tool.prefix(200)), arguments: Self.cut(report.arguments),
                          answer: Self.cut(report.answer), expected: Self.cut(expected) ?? expected,
                          module: report.module.map { String($0.prefix(64)) }, note: Self.cut(report.note),
                          resolved: nil)
        issues.append(issue)
        while issues.count > Self.capacity {
            if let oldest = issues.firstIndex(where: { $0.resolved != nil }) {
                issues.remove(at: oldest)
            } else {
                issues.removeFirst()
            }
        }
        try save()
        return issue
    }

    /// Newest first; open ones only unless `all`.
    public func list(all: Bool = false) -> [Issue] {
        issues.filter { all || $0.resolved == nil }.reversed()
    }

    /// One reporter's reports, open and resolved, newest first: what an
    /// agent reads to learn which of its reports were answered, and how.
    public func mine(_ reporter: String, limit: Int = 50) -> [Issue] {
        Array(issues.filter { $0.reporter == reporter }.reversed().prefix(max(1, limit)))
    }

    /// Resolved with an answer the reporter reads: what was done, or why
    /// nothing changes. A resolution with no answer is refused.
    public func resolve(_ id: String, by: String, note: String?, now: Date = Date()) throws -> Issue {
        guard let index = issues.firstIndex(where: { $0.id == id }) else {
            throw GhidraHostError(.refused, "no issue \(id)", status: 404)
        }
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            throw GhidraHostError(.refused, "say what was done, or why nothing changes: the reporter reads it",
                                  status: 400)
        }
        issues[index].resolved = Resolution(by: by, at: Self.second(now), note: Self.cut(note))
        try save()
        return issues[index]
    }

    /// A time as the file keeps it: ISO 8601, to the second.
    private static func second(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func cut(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count > textLimit else { return text }
        var cut = String(text.utf8.prefix(textLimit)) ?? String(text.prefix(textLimit / 4))
        while cut.utf8.count > textLimit { cut.removeLast() }
        return cut + " … (cut at \(textLimit) bytes)"
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(issues).write(to: file, options: .atomic)
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
