import Foundation

/// The review board: what a verifying agent finds wrong in a module's review,
/// kept on the server so the agent that reviews the module reads it, wherever
/// it runs. One ticket per module; each remark in it has its own author, its
/// own status and its own thread of replies.
///
/// The ticket says whether the module's review is closed. A verifier closes
/// it once no remark in it is still to be dealt with, and only a verifier
/// other than the agent that took the module into work (`reviewer`); a new
/// remark opens it again, a closed module included. Remarks stay open across
/// revisions until a verifier marks them verified. An administrator may set
/// any status from the console.
///
/// Who wrote what is the agent's own name — "Review Manager", "Verifier ·
/// devex-macbook" — beside the holder that carried the call (a token's name,
/// or the server's local MCP), since several agents share one holder.
///
/// One file in the store's private part, `private/tickets.json`: it goes to
/// no client and no mirror.
public actor TicketBook {
    public enum Severity: String, Codable, CaseIterable, Sendable {
        /// The review says something the code does not do.
        case wrong
        /// True, but a reader is led to a wrong idea.
        case misleading
        /// A name, a comment's wording, a typo.
        case cosmetic
    }

    public enum Status: String, Codable, CaseIterable, Sendable {
        /// Raised, not yet dealt with.
        case open
        /// The reviewer replied without changing the review.
        case answered
        /// The reviewer says it is put right, in a revision it names.
        case fixed
        /// The reviewer says it stays as it is, and why.
        case wontfix = "wont_fix"
        /// A verifier read the fix, or accepted the answer.
        case verified

        /// Still holds the ticket open.
        public var blocksClosing: Bool { self == .open || self == .answered || self == .fixed }
    }

    public struct Reply: Codable, Equatable, Sendable {
        public let at: Date
        public let author: String
        public let holder: String
        public let text: String?
        /// The status this reply set, if it set one.
        public let status: Status?
        /// The revision a fix is in.
        public let revision: Int?
    }

    public struct Remark: Codable, Equatable, Sendable {
        public let id: String
        public let at: Date
        public let author: String
        public let holder: String
        /// The module's published revision the remark was raised against.
        public let revision: Int?
        public let function: String?
        public let address: String?
        public let severity: Severity
        public let text: String
        public var status: Status
        public var thread: [Reply]
    }

    public struct Closing: Codable, Equatable, Sendable {
        public let by: String
        public let holder: String
        public let at: Date
        public let note: String?
        /// Set when an administrator closed it from the console.
        public let forced: Bool?
    }

    public struct Ticket: Codable, Equatable, Sendable {
        public let module: String
        public var name: String?
        public let opened: Date
        /// The agent that took the module into work last: it may not close
        /// its own ticket or verify a remark on its own review.
        public var reviewer: String?
        public var remarks: [Remark]
        public var closed: Closing?

        /// "closed", "open" (a remark holds it open), "settled" (remarks, none
        /// holding it), or "none": no remark yet and never closed — a ticket
        /// that only knows its reviewer, listed nowhere.
        public var state: String {
            if closed != nil { return "closed" }
            if remarks.isEmpty { return "none" }
            return remarks.contains { $0.status.blocksClosing } ? "open" : "settled"
        }
        public var openRemarks: Int { remarks.filter { $0.status.blocksClosing }.count }

        enum CodingKeys: String, CodingKey {
            case module, name, opened, reviewer, remarks, closed
        }
    }

    /// What a ticket looks like to a reader: the ticket, its state and how
    /// many remarks still hold it open.
    public struct Listed: Encodable, Sendable {
        public let ticket: Ticket
        public init(_ ticket: Ticket) { self.ticket = ticket }
        public func encode(to encoder: Encoder) throws {
            try ticket.encode(to: encoder)
            var more = encoder.container(keyedBy: Extra.self)
            try more.encode(ticket.state, forKey: .state)
            try more.encode(ticket.openRemarks, forKey: .openRemarks)
        }
        enum Extra: String, CodingKey { case state, openRemarks = "open_remarks" }
    }

    /// A remark as a client sends it.
    public struct NewRemark: Codable, Equatable, Sendable {
        public var severity: Severity
        public var text: String
        public var function: String?
        public var address: String?
        public var revision: Int?

        public init(severity: Severity, text: String, function: String? = nil, address: String? = nil,
                    revision: Int? = nil) {
            self.severity = severity
            self.text = text
            self.function = function
            self.address = address
            self.revision = revision
        }
    }

    /// One call on the board, as a tool or a client sends it.
    public struct Request: Codable, Equatable, Sendable {
        public enum Action: String, Codable, Sendable {
            /// Tickets, filtered by `state`, `module` or `author`.
            case list
            /// One module's ticket, with every remark and its thread.
            case read
            /// A remark added (`remark`).
            case add
            /// A reply in remark `id`'s thread, and its `status` if given.
            case reply
            /// The ticket closed (`note`).
            case close
            /// `agent` took the module into work: it is the reviewer.
            case reviewer
        }
        public var action: Action
        public var agent: String?
        public var module: String?
        public var state: String?
        public var author: String?
        public var remark: NewRemark?
        public var id: String?
        public var text: String?
        public var status: Status?
        public var revision: Int?
        public var note: String?

        public init(action: Action, agent: String? = nil, module: String? = nil, state: String? = nil,
                    author: String? = nil, remark: NewRemark? = nil, id: String? = nil, text: String? = nil,
                    status: Status? = nil, revision: Int? = nil, note: String? = nil) {
            self.action = action
            self.agent = agent
            self.module = module
            self.state = state
            self.author = author
            self.remark = remark
            self.id = id
            self.text = text
            self.status = status
            self.revision = revision
            self.note = note
        }
    }

    /// Who a call is from: the agent's own name and the holder that carried it.
    public struct Caller: Equatable, Sendable {
        public let author: String
        public let holder: String
        public init(author: String, holder: String) {
            self.author = author
            self.holder = holder
        }
    }

    public static let textLimit = 16 << 10
    public static let nameLimit = 120

    private let file: URL
    private var tickets: [String: Ticket]

    public init(file: URL) {
        self.file = file
        let read = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode([Ticket].self, from: $0) } ?? []
        tickets = Dictionary(read.map { ($0.module, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Reading

    /// Newest activity first. `state` is "open", "settled", "closed" or nil
    /// for all; `module` and `author` narrow it further.
    public func list(state: String? = nil, module: String? = nil, author: String? = nil) -> [Ticket] {
        tickets.values.filter { ticket in
            if let state, ticket.state != state { return false }
            if state == nil, ticket.state == "none" { return false }
            if let module, ticket.module != module.lowercased() { return false }
            if let author {
                let name = author.lowercased()
                guard ticket.remarks.contains(where: { $0.author.lowercased() == name
                    || $0.thread.contains { $0.author.lowercased() == name } })
                    || ticket.reviewer?.lowercased() == name else { return false }
            }
            return true
        }.sorted { Self.lastActivity($0) > Self.lastActivity($1) }
    }

    public func ticket(_ module: String) -> Ticket? {
        tickets[module.lowercased()]
    }

    // MARK: Writing

    /// Notes which agent took the module into work, so it is not the one to
    /// close the ticket; a module with no ticket gets an empty one to keep it.
    public func noteReviewer(_ module: String, name: String?, author: String, now: Date = Date()) throws {
        let key = try Self.module(module)
        var ticket = tickets[key] ?? Ticket(module: key, name: name, opened: Self.second(now), reviewer: nil,
                                            remarks: [], closed: nil)
        ticket.reviewer = String(author.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        if let name { ticket.name = name }
        tickets[key] = ticket
        try save()
    }

    /// A remark added to the module's ticket, the ticket made if there is
    /// none and opened again if it was closed.
    public func add(_ remark: NewRemark, module: String, name: String?, reviewer: String?, by caller: Caller,
                    now: Date = Date()) throws -> Ticket {
        let key = try Self.module(module)
        let author = try Self.author(caller.author)
        let text = remark.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw refused("say what is wrong") }
        var ticket = tickets[key] ?? Ticket(module: key, name: name, opened: Self.second(now), reviewer: reviewer,
                                            remarks: [], closed: nil)
        if let name { ticket.name = name }
        if ticket.reviewer == nil { ticket.reviewer = reviewer }
        ticket.remarks.append(Remark(
            id: String(UUID().uuidString.prefix(8)).lowercased(), at: Self.second(now), author: author,
            holder: caller.holder, revision: remark.revision, function: Self.cut(remark.function, 200),
            address: Self.cut(remark.address, 40), severity: remark.severity, text: Self.cut(text) ?? text,
            status: .open, thread: []))
        ticket.closed = nil
        tickets[key] = ticket
        try save()
        return ticket
    }

    /// A reply in a remark's thread, setting its status if `status` is given.
    /// The reviewer may answer, fix or decline; only another agent verifies a
    /// remark or opens it again.
    public func reply(module: String, remark id: String, text: String?, status: Status?, revision: Int?,
                      by caller: Caller, now: Date = Date()) throws -> Ticket {
        let key = try Self.module(module)
        let author = try Self.author(caller.author)
        guard var ticket = tickets[key] else { throw notFound("no ticket for module \(key)") }
        guard let index = ticket.remarks.firstIndex(where: { $0.id == id }) else {
            throw notFound("no remark \(id) in the ticket of \(ticket.name ?? key)")
        }
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status != nil || !(text ?? "").isEmpty else { throw refused("give a reply, a status, or both") }
        if let status {
            switch status {
            case .verified, .open:
                if Self.same(author, ticket.reviewer) {
                    throw refused("\(author) took this module into work: another agent verifies a remark on its review "
                        + "or opens it again", status: 409)
                }
            case .wontfix, .answered:
                guard !(text ?? "").isEmpty else { throw refused("say why, in the reply: the verifier reads it") }
            case .fixed:
                break
            }
        }
        ticket.remarks[index].thread.append(Reply(at: Self.second(now), author: author, holder: caller.holder,
                                                  text: Self.cut(text), status: status, revision: revision))
        if let status { ticket.remarks[index].status = status }
        if ticket.remarks[index].status.blocksClosing { ticket.closed = nil }
        tickets[key] = ticket
        try save()
        return ticket
    }

    /// Closed by a verifier: refused while a remark still holds it open, and
    /// to the agent that took the module into work. A module with no ticket
    /// gets one, closed with no remarks: its review was checked and found
    /// right.
    public func close(module: String, name: String?, reviewer: String?, note: String?, by caller: Caller,
                      now: Date = Date()) throws -> Ticket {
        let key = try Self.module(module)
        let author = try Self.author(caller.author)
        var ticket = tickets[key] ?? Ticket(module: key, name: name, opened: Self.second(now), reviewer: reviewer,
                                            remarks: [], closed: nil)
        if ticket.reviewer == nil { ticket.reviewer = reviewer }
        if Self.same(author, ticket.reviewer) {
            throw refused("\(author) took this module into work: another agent closes its ticket", status: 409)
        }
        let holding = ticket.remarks.filter { $0.status.blocksClosing }
        guard holding.isEmpty else {
            throw refused("\(holding.count) remark(s) still open, answered or fixed and not verified: "
                + holding.prefix(10).map { "\($0.id) (\($0.status.rawValue))" }.joined(separator: ", "), status: 409)
        }
        if let name { ticket.name = name }
        ticket.closed = Closing(by: author, holder: caller.holder, at: Self.second(now),
                                note: Self.cut(note?.trimmingCharacters(in: .whitespacesAndNewlines)), forced: nil)
        tickets[key] = ticket
        try save()
        return ticket
    }

    /// An administrator's say from the console: a remark's status, or the
    /// whole ticket closed or opened, whatever the remarks hold.
    public func force(module: String, remark id: String?, status: Status?, close: Bool?, note: String?,
                      by: String, now: Date = Date()) throws -> Ticket {
        let key = try Self.module(module)
        guard var ticket = tickets[key] else { throw notFound("no ticket for module \(key)") }
        let note = Self.cut(note?.trimmingCharacters(in: .whitespacesAndNewlines))
        if let id {
            guard let status else { throw refused("give the remark's status") }
            guard let index = ticket.remarks.firstIndex(where: { $0.id == id }) else {
                throw notFound("no remark \(id)")
            }
            ticket.remarks[index].thread.append(Reply(at: Self.second(now), author: by, holder: "console",
                                                      text: note, status: status, revision: nil))
            ticket.remarks[index].status = status
            if status.blocksClosing { ticket.closed = nil }
        }
        if let close {
            ticket.closed = close
                ? Closing(by: by, holder: "console", at: Self.second(now), note: note, forced: true)
                : nil
        }
        guard id != nil || close != nil else { throw refused("give a remark's status, or close or open the ticket") }
        tickets[key] = ticket
        try save()
        return ticket
    }

    // MARK: -

    private static func lastActivity(_ ticket: Ticket) -> Date {
        ([ticket.opened, ticket.closed?.at].compactMap { $0 }
            + ticket.remarks.flatMap { [$0.at] + $0.thread.map(\.at) }).max() ?? ticket.opened
    }

    private static func same(_ author: String, _ other: String?) -> Bool {
        guard let other else { return false }
        return author.trimmingCharacters(in: .whitespaces).lowercased() == other.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func module(_ text: String) throws -> String {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard key.count == 64, key.allSatisfy(\.isHexDigit) else {
            throw GhidraHostError(.refused, "a module is named by the SHA-256 of its bytes, 64 hex digits", status: 400)
        }
        return key
    }

    private static func author(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw GhidraHostError(.refused, "give `agent`: your own name, e.g. \"Verifier · devex-macbook\" — several "
                + "agents share one token, and the board tells them apart by it", status: 400)
        }
        return String(name.prefix(nameLimit))
    }

    private func refused(_ text: String, status: Int = 400) -> GhidraHostError {
        GhidraHostError(.refused, text, status: status)
    }

    private func notFound(_ text: String) -> GhidraHostError {
        GhidraHostError(.refused, text, status: 404)
    }

    private static func second(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func cut(_ text: String?, _ limit: Int = textLimit) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count > limit else { return text }
        var cut = String(text.utf8.prefix(limit)) ?? String(text.prefix(limit / 4))
        while cut.utf8.count > limit { cut.removeLast() }
        return cut + " … (cut at \(limit) bytes)"
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(tickets.values.sorted { $0.module < $1.module }).write(to: file, options: .atomic)
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
