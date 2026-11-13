import CodeAnalysis
import Foundation

/// Agents agreeing a change to a shared definition without the person: a
/// shared type, or an entry of the library registry.
///
/// A publish whose type differs from the shared one, or whose review of a
/// library function differs from the registry entry's, in more than an
/// addition is refused. The module's holder may then propose its definitions
/// as the shared ones: the proposal keeps both texts — the module's and the
/// shared one's, for an entry each changed field — and why. Other agents vote. It is agreed once two agents agree —
/// two different names, neither of them the author — and no agent objects;
/// an objection holds it until its author changes the vote. An agreed
/// proposal is applied by the module's next publish, as the shared types'
/// next version and each entry's next version, provided the module still
/// defines them as proposed and the shared ones are still what the proposal
/// saw. An administrator may
/// agree or reject one from the console, whatever the votes.
///
/// Agents are told apart by the name they give, as on the review board: there
/// is no token per agent. The agents of the modules that use the type are not
/// waited for: once a replacement is applied, each such module gets a remark
/// on its ticket.
///
/// A change of the registry itself — an entry taken out, a body restored, a
/// body split off as an entry of its own — is proposed and voted the same
/// way. It carries no module's text, so nothing waits for a publish: the
/// server applies it the moment it is agreed.
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

    /// A registry entry the module's publish would replace: every field its
    /// review changes, as the entry holds it and as the module offers it.
    public struct Entry: Codable, Equatable, Sendable {
        public struct Field: Codable, Equatable, Sendable {
            public let field: String
            public let held: String
            public let offered: String

            public init(field: String, held: String, offered: String) {
                self.field = field
                self.held = held
                self.offered = offered
            }
        }

        /// The entry's name, and the one the module's review gives it.
        public let name: String
        public let proposedName: String?
        /// The module whose review the entry's current version is.
        public let heldBy: String?
        public let version: Int?
        public let fields: [Field]

        public init(name: String, proposedName: String?, heldBy: String?, version: Int?, fields: [Field]) {
            self.name = name
            self.proposedName = proposedName
            self.heldBy = heldBy
            self.version = version
            self.fields = fields
        }

        enum CodingKeys: String, CodingKey {
            case name, version, fields
            case proposedName = "proposed_name"
            case heldBy = "held_by"
        }
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
        /// The registry entries the module's publish would replace, by id.
        public let entries: [String: Entry]?
        /// A change of the registry itself, applied once agreed; `module` is
        /// where the review found it.
        public let change: LibraryChange?
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
            case id, at, module, name, bits, names, origins, entries, change, author, holder, reason, votes, state
            case decided, applied
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

    /// A proposal in a size an agent's answer holds: the types it would
    /// replace by name, and each registry entry by id with the names of the
    /// fields it changes and their size — `entry` reads one in full.
    public struct Summary: Encodable, Sendable {
        public let proposal: Proposal
        /// The types' C too: they are a type's lines, not a function's.
        public let withTypes: Bool
        public init(_ proposal: Proposal, withTypes: Bool = false) {
            self.proposal = proposal
            self.withTypes = withTypes
        }

        struct EntryRow: Encodable {
            let id: String
            let name: String
            let proposedName: String?
            let heldBy: String?
            let version: Int?
            let fields: [String]
            /// The bytes of the held and offered texts together.
            let bytes: Int
            enum CodingKeys: String, CodingKey {
                case id, name, version, fields, bytes
                case proposedName = "proposed_name"
                case heldBy = "held_by"
            }
        }

        enum Keys: String, CodingKey {
            case id, at, module, name, bits, names, origins, entries, change, author, holder, reason, votes, state
            case decided, applied, agrees, objections
            case moduleC = "module_c"
            case sharedC = "shared_c"
            case needed = "agrees_needed"
        }

        public func encode(to encoder: Encoder) throws {
            var out = encoder.container(keyedBy: Keys.self)
            try out.encode(proposal.id, forKey: .id)
            try out.encode(proposal.at, forKey: .at)
            try out.encode(proposal.module, forKey: .module)
            try out.encodeIfPresent(proposal.name, forKey: .name)
            try out.encode(proposal.bits, forKey: .bits)
            try out.encode(proposal.names, forKey: .names)
            try out.encode(proposal.origins, forKey: .origins)
            if withTypes {
                try out.encode(proposal.moduleC, forKey: .moduleC)
                try out.encode(proposal.sharedC, forKey: .sharedC)
            }
            if let entries = proposal.entries {
                try out.encode(entries.keys.sorted().map { id -> EntryRow in
                    let entry = entries[id]!
                    return EntryRow(id: id, name: entry.name, proposedName: entry.proposedName, heldBy: entry.heldBy,
                                    version: entry.version, fields: entry.fields.map(\.field),
                                    bytes: entry.fields.reduce(0) { $0 + $1.held.utf8.count + $1.offered.utf8.count })
                }, forKey: .entries)
            }
            try out.encodeIfPresent(proposal.change, forKey: .change)
            try out.encode(proposal.author, forKey: .author)
            try out.encode(proposal.holder, forKey: .holder)
            try out.encode(proposal.reason, forKey: .reason)
            try out.encode(proposal.votes, forKey: .votes)
            try out.encode(proposal.state, forKey: .state)
            try out.encodeIfPresent(proposal.decided, forKey: .decided)
            try out.encodeIfPresent(proposal.applied, forKey: .applied)
            try out.encode(proposal.agrees, forKey: .agrees)
            try out.encode(proposal.objections, forKey: .objections)
            try out.encode(TypeProposalBook.agreesNeeded, forKey: .needed)
        }
    }

    /// One call, as a tool or a client sends it.
    public struct Request: Codable, Equatable, Sendable {
        /// How much of a proposal an answer carries. Nil is all of it, as the
        /// console reads it.
        public enum View: String, Codable, Sendable {
            /// `Summary`: the list, and the answer to a propose or a vote.
            case summary
            /// One proposal: its types' C, its entries summarized.
            case proposal
        }
        public enum Action: String, Codable, Sendable {
            /// Proposals, filtered by `state` and `module`.
            case list
            /// One proposal by `id`.
            case read
            /// The module's replacements proposed, with `reason` — or, with
            /// `change`, a change of the registry itself.
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
        public var view: View?
        /// With `id`: one registry entry of the proposal, in full.
        public var entry: String?
        /// With `propose`: an entry taken out, a body restored or split off.
        public var change: LibraryChange?

        public init(action: Action, agent: String? = nil, module: String? = nil, id: String? = nil,
                    state: String? = nil, choice: Choice? = nil, text: String? = nil, reason: String? = nil,
                    view: View? = nil, entry: String? = nil, change: LibraryChange? = nil) {
            self.change = change
            self.action = action
            self.agent = agent
            self.module = module
            self.id = id
            self.state = state
            self.choice = choice
            self.text = text
            self.reason = reason
            self.view = view
            self.entry = entry
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
        public var entries: [String: Entry]
        public var change: LibraryChange?

        public init(module: String, name: String?, bits: String, names: [String], moduleC: [String: String],
                    sharedC: [String: String], origins: [String: String], entries: [String: Entry] = [:],
                    change: LibraryChange? = nil) {
            self.change = change
            self.module = module
            self.name = name
            self.bits = bits
            self.names = names
            self.moduleC = moduleC
            self.sharedC = sharedC
            self.origins = origins
            self.entries = entries
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
        let module = draft.module.lowercased()
        if let change = draft.change {
            return try proposeChange(change, draft: draft, module: module, reason: reason, author: author,
                                     caller: caller, now: now)
        }
        guard !draft.names.isEmpty || !draft.entries.isEmpty else {
            throw refused("this module's publish replaces no shared type and no registry entry: there is nothing to "
                + "propose", status: 409)
        }
        if let live = proposals.values.first(where: { $0.module == module && $0.state.isLive && $0.change == nil }) {
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
        let entries = Set(draft.entries.keys)
        if let other = proposals.values.first(where: { $0.state.isLive
            && !entries.isDisjoint(with: ($0.entries ?? [:]).keys) }) {
            let shared = entries.intersection((other.entries ?? [:]).keys).sorted().joined(separator: ", ")
            throw refused("proposal \(other.id) of \(other.name ?? other.module) already proposes the registry "
                + "entries \(shared): vote on it, or wait until it is decided", status: 409)
        }
        let proposal = Proposal(
            id: String(UUID().uuidString.prefix(8)).lowercased(), at: Self.second(now), module: module,
            name: draft.name, bits: draft.bits, names: draft.names.sorted(), moduleC: draft.moduleC,
            sharedC: draft.sharedC, origins: draft.origins,
            entries: draft.entries.isEmpty ? nil : draft.entries, change: nil, author: author, holder: caller.holder,
            reason: Self.cut(reason) ?? reason, votes: [], state: .open, decided: nil, applied: nil)
        proposals[proposal.id] = proposal
        try save()
        return proposal
    }

    /// A change of the registry proposed: one live proposal per entry or body.
    private func proposeChange(_ change: LibraryChange, draft: Draft, module: String, reason: String, author: String,
                               caller: TicketBook.Caller, now: Date) throws -> Proposal {
        let touched = Set([change.id, change.body].compactMap { $0 })
        if let other = proposals.values.first(where: { proposal in
            guard proposal.state.isLive, let held = proposal.change else { return false }
            return !touched.isDisjoint(with: [held.id, held.body].compactMap { $0 })
        }) {
            throw refused("proposal \(other.id) already proposes a change of \(touched.sorted().joined(separator: ", ")): "
                + "vote on it, or wait until it is decided", status: 409)
        }
        let proposal = Proposal(
            id: String(UUID().uuidString.prefix(8)).lowercased(), at: Self.second(now), module: module,
            name: draft.name, bits: draft.bits, names: [], moduleC: [:], sharedC: [:], origins: [:],
            entries: nil, change: change, author: author, holder: caller.holder,
            reason: Self.cut(reason) ?? reason, votes: [], state: .open, decided: nil, applied: nil)
        proposals[proposal.id] = proposal
        try save()
        return proposal
    }

    /// An agreed change the registry could not take: closed, saying why.
    public func notApplied(_ id: String, note: String, now: Date = Date()) throws -> Proposal? {
        guard var proposal = proposals[id.lowercased()], proposal.state == .agreed else { return nil }
        proposal.state = .rejected
        proposal.decided = Decision(by: "byteripper-server", at: Self.second(now),
                                    note: Self.cut("not applied: " + note), forced: nil)
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
