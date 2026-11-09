import Foundation

/// Agents agreeing a change to a shared type without the person.
///
/// A publish whose type differs from the shared one in more than an addition
/// is refused. The module's holder may then propose its definitions as the
/// shared ones: the proposal keeps both texts, the module's and the shared
/// one's, and why. Other agents vote. It is agreed once two agents agree —
/// two different names, neither of them the author — and no agent objects;
/// an objection holds it until its author changes the vote. An agreed
/// proposal is applied by the module's next publish, as the shared types'
/// next version, provided the module still defines the types as proposed and
/// the shared ones are still what the proposal saw. An administrator may
/// agree or reject one from the console, whatever the votes.
///
/// Agents are told apart by the name they give, as on the review board: there
/// is no token per agent. The agents of the modules that use the type are not
/// waited for: once a replacement is applied, each such module gets a remark
/// on its ticket.
///
/// One file in the store's private part, `private/type-proposals.json`: it
/// goes to no client and no mirror.
public actor TypeProposalBook {
    public enum State: String, Codable, CaseIterable, Sendable {
        /// Waiting for votes, or held by an objection.
        case open
        /// Two agents agreed and none objects: the module's next publish applies it.
        case agreed
        /// A publish of the module made it the shared types' next version.
        case applied
        /// An administrator rejected it.
        case rejected
        /// Its author took it back.
        case withdrawn

        public var isLive: Bool { self == .open || self == .agreed }
    }

    public enum Choice: String, Codable, CaseIterable, Sendable {
        case agree
        case object
    }

    public struct Vote: Codable, Equatable, Sendable {
        public let agent: String
        public let holder: String
        public let choice: Choice
        public let text: String?
        public let at: Date
    }

    public struct Decision: Codable, Equatable, Sendable {
        public let by: String
        public let at: Date
        public let note: String?
        /// Set when an administrator decided from the console.
        public let forced: Bool?
    }

    public struct Applied: Codable, Equatable, Sendable {
        public let revision: Int?
        public let version: Int?
        public let at: Date
    }

    public struct Proposal: Codable, Equatable, Sendable {
        public let id: String
        public let at: Date
        public let module: String
        public var name: String?
        /// The archive's pointer size, `Ia32` or `X64`.
        public let bits: String
        /// The types the module's publish would replace, a tag beside its typedef.
        public let names: [String]
        /// Each type as the module defines it, and as the shared types hold it.
        public let moduleC: [String: String]
        public let sharedC: [String: String]
        /// The module that wrote each shared copy, as the archive says.
        public let origins: [String: String]
        public let author: String
        public let holder: String
        public let reason: String
        /// Every vote in order; an agent's last one counts.
        public var votes: [Vote]
        public var state: State
        public var decided: Decision?
        public var applied: Applied?

        /// The vote that counts for each agent, by lowercased name.
        public var current: [Vote] {
            var last: [String: Vote] = [:]
            for vote in votes { last[vote.agent.lowercased()] = vote }
            return last.values.sorted { $0.at < $1.at }
        }
        public var agrees: [String] { current.filter { $0.choice == .agree }.map(\.agent) }
        public var objections: [String] { current.filter { $0.choice == .object }.map(\.agent) }

        enum CodingKeys: String, CodingKey {
            case id, at, module, name, bits, names, origins, author, holder, reason, votes, state, decided, applied
            case moduleC = "module_c"
            case sharedC = "shared_c"
        }
    }

    /// A proposal as a reader gets it: the proposal and its counts.
    public struct Listed: Encodable, Sendable {
        public let proposal: Proposal
        public init(_ proposal: Proposal) { self.proposal = proposal }
        public func encode(to encoder: Encoder) throws {
            try proposal.encode(to: encoder)
            var more = encoder.container(keyedBy: Extra.self)
            try more.encode(proposal.agrees, forKey: .agrees)
            try more.encode(proposal.objections, forKey: .objections)
            try more.encode(TypeProposalBook.agreesNeeded, forKey: .needed)
        }
        enum Extra: String, CodingKey { case agrees, objections, needed = "agrees_needed" }
    }

    /// One call, as a tool or a client sends it.
    public struct Request: Codable, Equatable, Sendable {
        public enum Action: String, Codable, Sendable {
            /// Proposals, filtered by `state` and `module`.
            case list
            /// One proposal by `id`.
            case read
            /// The module's replacements proposed, with `reason`.
            case propose
            /// `choice` on proposal `id`, with `text`.
            case vote
            /// Proposal `id` taken back by its author.
            case withdraw
        }
        public var action: Action
        public var agent: String?
        public var module: String?
        public var id: String?
        public var state: String?
        public var choice: Choice?
        public var text: String?
        public var reason: String?

        public init(action: Action, agent: String? = nil, module: String? = nil, id: String? = nil,
                    state: String? = nil, choice: Choice? = nil, text: String? = nil, reason: String? = nil) {
            self.action = action
            self.agent = agent
            self.module = module
            self.id = id
            self.state = state
            self.choice = choice
            self.text = text
            self.reason = reason
        }
    }

    /// What a proposal is made of, as the host found it in the module.
    public struct Draft: Sendable {
        public var module: String
        public var name: String?
        public var bits: String
        public var names: [String]
        public var moduleC: [String: String]
        public var sharedC: [String: String]
        public var origins: [String: String]

        public init(module: String, name: String?, bits: String, names: [String], moduleC: [String: String],
                    sharedC: [String: String], origins: [String: String]) {
            self.module = module
            self.name = name
            self.bits = bits
            self.names = names
            self.moduleC = moduleC
            self.sharedC = sharedC
            self.origins = origins
        }
    }

    /// How many agents other than the author agree before it applies.
    public static let agreesNeeded = 2

    private let file: URL
    private var proposals: [String: Proposal]

    public init(file: URL) {
        self.file = file
        let read = (try? Data(contentsOf: file)).flatMap { try? TicketBook.decoder.decode([Proposal].self, from: $0) } ?? []
        proposals = Dictionary(read.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Reading

    /// Newest first; `state` narrows to one state, `module` to one module.
    public func list(state: String? = nil, module: String? = nil) -> [Proposal] {
        proposals.values.filter { proposal in
            if let state, proposal.state.rawValue != state { return false }
            if let module, proposal.module != module.lowercased() { return false }
            return true
        }.sorted { Self.lastActivity($0) > Self.lastActivity($1) }
    }

    public func proposal(_ id: String) -> Proposal? {
        proposals[id.lowercased()]
    }

    /// The module's agreed proposals: what its next publish may apply.
    public func agreed(module: String) -> [Proposal] {
        proposals.values.filter { $0.module == module.lowercased() && $0.state == .agreed }
    }

    // MARK: Writing

    public func propose(_ draft: Draft, reason: String, by caller: TicketBook.Caller, now: Date = Date()) throws -> Proposal {
        let author = try Self.author(caller.author)
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw refused("say why the shared definition is wrong, with the evidence: the voters read it")
        }
        guard !draft.names.isEmpty else {
            throw refused("this module's publish replaces no shared type: there is nothing to propose", status: 409)
        }
        let module = draft.module.lowercased()
        if let live = proposals.values.first(where: { $0.module == module && $0.state.isLive }) {
            throw refused("proposal \(live.id) for this module is still \(live.state.rawValue): withdraw it first, "
                + "or let it be decided", status: 409)
        }
        let wanted = Set(draft.names)
        if let other = proposals.values.first(where: { $0.state.isLive && $0.bits == draft.bits
            && !wanted.isDisjoint(with: $0.names) }) {
            let shared = wanted.intersection(other.names).sorted().joined(separator: ", ")
            throw refused("proposal \(other.id) of \(other.name ?? other.module) already proposes \(shared): "
                + "vote on it, or wait until it is decided", status: 409)
        }
        let proposal = Proposal(
            id: String(UUID().uuidString.prefix(8)).lowercased(), at: Self.second(now), module: module,
            name: draft.name, bits: draft.bits, names: draft.names.sorted(), moduleC: draft.moduleC,
            sharedC: draft.sharedC, origins: draft.origins, author: author, holder: caller.holder,
            reason: Self.cut(reason) ?? reason, votes: [], state: .open, decided: nil, applied: nil)
        proposals[proposal.id] = proposal
        try save()
        return proposal
    }

    /// An agent's vote. Its author does not vote; an objection says why; an
    /// agent's later vote replaces its earlier one.
    public func vote(_ id: String, choice: Choice, text: String?, by caller: TicketBook.Caller,
                     now: Date = Date()) throws -> Proposal {
        let agent = try Self.author(caller.author)
        guard var proposal = proposals[id.lowercased()] else { throw notFound("no type proposal \(id)") }
        guard proposal.state.isLive else {
            throw refused("proposal \(proposal.id) is \(proposal.state.rawValue): nothing to vote on", status: 409)
        }
        if Self.same(agent, proposal.author) {
            throw refused("\(agent) made this proposal: other agents vote on it", status: 409)
        }
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if choice == .object, (text ?? "").isEmpty {
            throw refused("say why you object, with the evidence: the author and the other voters read it")
        }
        proposal.votes.append(Vote(agent: agent, holder: caller.holder, choice: choice, text: Self.cut(text),
                                   at: Self.second(now)))
        proposal.state = proposal.agrees.count >= Self.agreesNeeded && proposal.objections.isEmpty ? .agreed : .open
        proposals[proposal.id] = proposal
        try save()
        return proposal
    }

    /// Taken back by its author before it is applied.
    public func withdraw(_ id: String, note: String?, by caller: TicketBook.Caller, now: Date = Date()) throws -> Proposal {
        let agent = try Self.author(caller.author)
        guard var proposal = proposals[id.lowercased()] else { throw notFound("no type proposal \(id)") }
        guard proposal.state.isLive else {
            throw refused("proposal \(proposal.id) is \(proposal.state.rawValue) already", status: 409)
        }
        guard Self.same(agent, proposal.author) else {
            throw refused("only its author, \(proposal.author), withdraws a proposal; vote `object` instead", status: 409)
        }
        proposal.state = .withdrawn
        proposal.decided = Decision(by: agent, at: Self.second(now), note: Self.cut(note), forced: nil)
        proposals[proposal.id] = proposal
        try save()
        return proposal
    }

    /// An administrator's decision from the console: agreed or rejected,
    /// whatever the votes say.
    public func force(_ id: String, agree: Bool, note: String?, by: String, now: Date = Date()) throws -> Proposal {
        guard var proposal = proposals[id.lowercased()] else { throw notFound("no type proposal \(id)") }
        guard proposal.state.isLive else {
            throw refused("proposal \(proposal.id) is \(proposal.state.rawValue) already", status: 409)
        }
        proposal.state = agree ? .agreed : .rejected
        proposal.decided = Decision(by: by, at: Self.second(now), note: Self.cut(note), forced: true)
        proposals[proposal.id] = proposal
        try save()
        return proposal
    }

    /// Applied by the module's publish.
    public func markApplied(_ ids: [String], revision: Int?, version: Int?, now: Date = Date()) throws {
        var changed = false
        for id in ids {
            guard var proposal = proposals[id], proposal.state == .agreed else { continue }
            proposal.state = .applied
            proposal.applied = Applied(revision: revision, version: version, at: Self.second(now))
            proposals[id] = proposal
            changed = true
        }
        if changed { try save() }
    }

    // MARK: -

    private static func lastActivity(_ proposal: Proposal) -> Date {
        ([proposal.at, proposal.decided?.at, proposal.applied?.at].compactMap { $0 } + proposal.votes.map(\.at)).max()
            ?? proposal.at
    }

    private static func same(_ author: String, _ other: String) -> Bool {
        author.trimmingCharacters(in: .whitespaces).lowercased() == other.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func author(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw GhidraHostError(.refused, "give `agent`: your own name, e.g. \"Verifier · devex-macbook\" — several "
                + "agents share one token, and the votes are counted by it", status: 400)
        }
        return String(name.prefix(TicketBook.nameLimit))
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

    private static func cut(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let limit = TicketBook.textLimit
        guard text.utf8.count > limit else { return text }
        var cut = String(text.prefix(limit / 4))
        while cut.utf8.count > limit { cut.removeLast() }
        return cut + " … (cut)"
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TicketBook.encoder.encode(proposals.values.sorted { $0.id < $1.id }).write(to: file, options: .atomic)
    }
}
