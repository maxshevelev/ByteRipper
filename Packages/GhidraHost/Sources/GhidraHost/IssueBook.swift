import Foundation

/// What agents report about the tools: a call that answered wrong, refused
/// what it should take, or failed — kept on the server, so that a review pair
/// on a Mac with nobody to fix the tools can still say what went wrong, and
/// whoever does fix them reads it with the call that showed it.
///
/// One file in the store's private part, `private/issues.json`: it goes to no
/// client and no mirror. What the reporter wrote is never changed after it is
/// made; an administrator moves the report through its statuses, each step
/// kept with who took it and when, and the reporter confirms the fix or
/// sends it back.
public actor IssueBook {
    /// Where a report stands, in the order a fix goes through them.
    public enum Status: String, Codable, CaseIterable, Sendable {
        /// Reported; nobody has looked at it yet.
        case new
        /// The cause is being looked for.
        case investigating
        /// It cannot be made to happen without more from the reporter.
        case waitingForData = "waiting_for_data"
        /// The cause is known; the test that shows it and the fix are written.
        case fixing
        /// The suites run and the package is built and checked.
        case testing
        /// The package waits on the go-ahead to install it.
        case awaitingGo = "awaiting_go"
        /// Approved, and held until the server can be restarted.
        case awaitingWindow = "awaiting_window"
        /// Installed; checked on the live server next.
        case deployed
        /// Checked on the live server and answered: the reporter confirms it,
        /// or sends it back.
        case awaitingConfirmation = "awaiting_confirmation"
        /// Confirmed by the reporter, or closed by an administrator.
        case resolved
        /// Not a defect, or not to be changed; answered with why.
        case noChange = "no_change"

        /// No more work follows: it leaves the open list.
        public var isClosed: Bool { self == .resolved || self == .noChange }
        /// The reporter is told something here, so it needs a note.
        var needsNote: Bool { self == .awaitingConfirmation || self == .noChange || self == .waitingForData }
    }

    /// One step of a report's way: what it became, who moved it and when,
    /// what they said, and for an install the build.
    public struct StatusChange: Codable, Equatable, Sendable {
        public let status: Status
        public let by: String
        public let at: Date
        public let note: String?
        public let build: String?
    }

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
        /// The answer the reporter reads: what was fixed and in which build,
        /// or why nothing changes. Set when the report is answered, cleared
        /// when it is taken up again.
        public var resolved: Resolution?
        public var status: Status
        /// Every status it was moved to, oldest first; empty for a report
        /// from before statuses.
        public var history: [StatusChange]

        enum CodingKeys: String, CodingKey {
            case id, at, reporter, tool, arguments, answer, expected, module, note, resolved, status, history
        }

        init(id: String, at: Date, reporter: String, tool: String, arguments: String?, answer: String?,
             expected: String, module: String?, note: String?) {
            self.id = id
            self.at = at
            self.reporter = reporter
            self.tool = tool
            self.arguments = arguments
            self.answer = answer
            self.expected = expected
            self.module = module
            self.note = note
            resolved = nil
            status = .new
            history = []
        }

        /// A report from before statuses reads as new, or resolved when it
        /// was answered then.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            at = try container.decode(Date.self, forKey: .at)
            reporter = try container.decode(String.self, forKey: .reporter)
            tool = try container.decode(String.self, forKey: .tool)
            arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
            answer = try container.decodeIfPresent(String.self, forKey: .answer)
            expected = try container.decode(String.self, forKey: .expected)
            module = try container.decodeIfPresent(String.self, forKey: .module)
            note = try container.decodeIfPresent(String.self, forKey: .note)
            resolved = try container.decodeIfPresent(Resolution.self, forKey: .resolved)
            status = try container.decodeIfPresent(Status.self, forKey: .status) ?? (resolved == nil ? .new : .resolved)
            history = try container.decodeIfPresent([StatusChange].self, forKey: .history) ?? []
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

    /// What a reporter sends to confirm a fix, or to send it back.
    public struct Confirmation: Codable, Equatable, Sendable {
        public var works: Bool
        public var note: String?

        public init(works: Bool, note: String? = nil) {
            self.works = works
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
                          module: report.module.map { String($0.prefix(64)) }, note: Self.cut(report.note))
        issues.append(issue)
        while issues.count > Self.capacity {
            if let oldest = issues.firstIndex(where: { $0.status.isClosed }) {
                issues.remove(at: oldest)
            } else {
                issues.removeFirst()
            }
        }
        try save()
        return issue
    }

    /// Newest first; open ones only unless `all` — a report waiting on its
    /// reporter's confirmation is still open.
    public func list(all: Bool = false) -> [Issue] {
        issues.filter { all || !$0.status.isClosed }.reversed()
    }

    /// One reporter's reports, open and resolved, newest first: what an
    /// agent reads to learn which of its reports were answered, and how.
    public func mine(_ reporter: String, limit: Int = 50) -> [Issue] {
        Array(issues.filter { $0.reporter == reporter }.reversed().prefix(max(1, limit)))
    }

    /// Answered: what was done, which the reporter now confirms or sends
    /// back. An answer with no note is refused.
    public func resolve(_ id: String, by: String, note: String?, now: Date = Date()) throws -> Issue {
        try setStatus(id, .awaitingConfirmation, by: by, note: note, now: now)
    }

    /// An administrator's step: the report moved to `status`. A status that
    /// tells the reporter something — answered, nothing changes, more data
    /// wanted — needs a note; answered or nothing changes is the answer the
    /// reporter reads, and any status before them takes the answer back.
    public func setStatus(_ id: String, _ status: Status, by: String, note: String?, build: String? = nil,
                          now: Date = Date()) throws -> Issue {
        let index = try position(id)
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if status.needsNote, note == nil {
            throw GhidraHostError(.refused, status == .waitingForData
                ? "say what is wanted from the reporter: the reporter reads it"
                : "say what was done, or why nothing changes: the reporter reads it", status: 400)
        }
        let at = Self.second(now)
        switch status {
        case .awaitingConfirmation, .noChange:
            issues[index].resolved = Resolution(by: by, at: at, note: Self.cut(note))
        case .resolved:
            if issues[index].resolved == nil {
                issues[index].resolved = Resolution(by: by, at: at, note: Self.cut(note))
            }
        default:
            issues[index].resolved = nil
        }
        issues[index].status = status
        issues[index].history.append(StatusChange(status: status, by: by, at: at, note: Self.cut(note),
                                                  build: build?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty))
        try save()
        return issues[index]
    }

    /// The reporter's answer to a fix: it works, and the report is resolved;
    /// or it does not, said in `note`, and the report is looked at again.
    /// Only the reporter, and only a report waiting on its confirmation.
    public func confirm(_ id: String, by reporter: String, works: Bool, note: String?,
                        now: Date = Date()) throws -> Issue {
        let index = try position(id)
        guard issues[index].reporter == reporter else {
            throw GhidraHostError(.refused, "only its reporter, \(issues[index].reporter), confirms report \(id)",
                                  status: 403)
        }
        guard issues[index].status == .awaitingConfirmation else {
            throw GhidraHostError(.refused, "report \(id) is \(issues[index].status.rawValue), not waiting on "
                + "your confirmation: confirm it once ghidra_issues says awaiting_confirmation", status: 409)
        }
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard works || note != nil else {
            throw GhidraHostError(.refused, "say what still goes wrong: the call, its arguments and what came back",
                                  status: 400)
        }
        let status: Status = works ? .resolved : .investigating
        if !works { issues[index].resolved = nil }
        issues[index].status = status
        issues[index].history.append(StatusChange(status: status, by: reporter, at: Self.second(now),
                                                  note: Self.cut(note), build: nil))
        try save()
        return issues[index]
    }

    private func position(_ id: String) throws -> Int {
        guard let index = issues.firstIndex(where: { $0.id == id }) else {
            throw GhidraHostError(.refused, "no issue \(id)", status: 404)
        }
        return index
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
