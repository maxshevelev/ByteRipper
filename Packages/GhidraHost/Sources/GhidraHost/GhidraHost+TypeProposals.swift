import CodeAnalysis
import Foundation

/// Agents agreeing a replacement of shared definitions (`TypeProposalBook`) —
/// shared types and library registry entries: the host finds what the
/// module's publish would replace, keeps both texts in the proposal, and
/// applies an agreed proposal at the module's next publish.
extension GhidraHost {
    public func typeProposalCall(_ request: TypeProposalBook.Request, holder: String) async throws -> Data {
        guard let book = typeProposals else {
            throw GhidraHostError(.install, "this host keeps no type proposals: there is no analysis server to keep them")
        }
        let caller = TicketBook.Caller(author: request.agent ?? "", holder: holderName(holder))
        func id() throws -> String {
            guard let id = request.id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                throw GhidraHostError(.refused, "name the proposal's `id`, as `ghidra_type_proposals` lists it", status: 400)
            }
            return id
        }
        func encoded(_ proposal: TypeProposalBook.Proposal) throws -> Data {
            try TicketBook.encoder.encode(TypeProposalBook.Listed(proposal))
        }
        switch request.action {
        case .list:
            let rows = await book.list(state: request.state, module: request.module)
            return try TicketBook.encoder.encode(rows.map(TypeProposalBook.Listed.init))
        case .read:
            guard let proposal = await book.proposal(try id()) else {
                throw GhidraHostError(.refused, "no type proposal \(try id())", status: 404)
            }
            return try encoded(proposal)
        case .propose:
            guard let text = request.module, let module = SHA256Digest(hex: text.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw GhidraHostError(.refused, "name the `module`, by the SHA-256 of its bytes", status: 400)
            }
            let draft = try await proposalDraft(module, holder: holder)
            return try encoded(try await book.propose(draft, reason: request.reason ?? "", by: caller))
        case .vote:
            guard let choice = request.choice else {
                throw GhidraHostError(.refused, "give `choice`: agree or object", status: 400)
            }
            return try encoded(try await book.vote(try id(), choice: choice, text: request.text, by: caller))
        case .withdraw:
            return try encoded(try await book.withdraw(try id(), note: request.text, by: caller))
        }
    }

    /// What the module's publish would replace, read from the module in work:
    /// each replaced type as the module defines it and as the shared types
    /// hold it. Only the module's holder proposes: it is the one whose
    /// publish will apply it.
    func proposalDraft(_ module: SHA256Digest, holder: String) async throws -> TypeProposalBook.Draft {
        guard let held = workLease(module), held.holder == holderName(holder) else {
            throw GhidraHostError(.refused, "take the module into work first (`ghidra_take`): only its holder proposes what "
                + "its publish would replace", status: 409)
        }
        // One dry export answers both: the type conflicts in its headers, the
        // registry's offer in the artifact.
        let record = try await owner(of: module)
        let (raw, headers) = try await Self.call(record.port, "POST", "/v1/publish?dry_run=1", timeout: 3600)
        let origins = Self.typeOrigins(headers["x-owner-type-origins"])
        let names = (headers["x-owner-type-conflicts"] ?? "").split(separator: ",").map(String.init)
            .filter { !(origins[$0] ?? "").hasPrefix("withdrawn ") }
        var moduleC: [String: String] = [:]
        var sharedC: [String: String] = [:]
        for name in names {
            let definition = try await typeDefinition(module, name: name)
            moduleC[name] = definition.program
            sharedC[name] = definition.shared
        }
        let language = ((try? JSONSerialization.jsonObject(with: try await read(module, "/v1/hello", holder: holder)))
            as? [String: Any])?["language"] as? String ?? ""
        let offer = try Self.libraryOffer(try await Self.call(record.port, "GET", "/v1/library").data, artifact: raw)
        let entries = try await libraryReplacements(module, raw: raw, offer: offer.proposals,
                                                    reviewed: headers["x-owner-reviewed"] == "true")
        return TypeProposalBook.Draft(module: module.hex, name: try? project(module).state().module.name,
                                      bits: Self.archiveBits(language: language), names: names, moduleC: moduleC,
                                      sharedC: sharedC, origins: origins.filter { names.contains($0.key) },
                                      entries: entries)
    }

    /// The registry entries the module's publish would replace, each with
    /// every field its review changes, as the entry holds it and as the module
    /// offers it: those the registry refuses as a replacement, and those a
    /// link would have to record over a differing review. Read from an export
    /// of the module as it is now; nothing is written.
    func libraryReplacements(_ module: SHA256Digest, raw: Data, offer: [LibraryProposal],
                             reviewed: Bool) async throws -> [String: TypeProposalBook.Entry] {
        var offered = try await Self.withoutLinked(offer, writer: writer)
        guard !offered.isEmpty || !offer.isEmpty else { return [:] }
        let first = try await Self.completions(raw, offer: offer, offered: offered, reviewed: reviewed, take: .none,
                                               writer: writer)
        let linkIDs = first.refused.compactMap(\.entry)
        // Those links taken, to see what the registry says of the rest.
        let probe = LibraryTake.these(Dictionary(linkIDs.map { ($0, "probe") }, uniquingKeysWith: { a, _ in a }))
        let completion = linkIDs.isEmpty ? first
            : try await Self.completions(raw, offer: offer, offered: offered, reviewed: reviewed, take: probe,
                                         writer: writer)
        offered += completion.proposals
        let rev = (try await writer.latestRevision(module: module))?.rev ?? 0
        let would = offered.isEmpty ? nil : try await writer.previewLibraryEntries(
            module: module, rev: rev, by: nil, proposals: offered, take: probe)
        let index = try await writer.readLibraryIndex()
        var found: [String: TypeProposalBook.Entry] = [:]
        if let would, !would.conflicts.isEmpty {
            let fields = try await Self.conflictFields(would.conflicts, offered: offered, writer: writer)
            for conflict in would.conflicts {
                found[conflict.id] = .init(name: conflict.name, proposedName: conflict.proposedName,
                                           heldBy: conflict.heldBy.module.hex, version: conflict.version,
                                           fields: Self.entryFields(fields[conflict.id]))
            }
        }
        for id in linkIDs where found[id] == nil {
            guard let held = index.entries[id],
                  let own = completion.proposals.first(where: { $0.basedOn == id }) else { continue }
            let object = try await writer.readObject(held.entry)
            func fields(_ data: Data) -> [String: Any] {
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            }
            let (before, after) = (fields(object), fields(own.entry))
            let changed = LibraryProposal.changedFields(from: object, to: own.entry)
            found[id] = .init(name: held.name, proposedName: own.name, heldBy: held.source.module.hex,
                              version: held.version,
                              fields: changed.map { .init(field: $0, held: Self.fieldText($0, before[$0]),
                                                           offered: Self.fieldText($0, after[$0])) })
        }
        return found
    }

    static func entryFields(_ rows: [[String: String]]?) -> [TypeProposalBook.Entry.Field] {
        (rows ?? []).map { .init(field: $0["field"] ?? "", held: $0["held"] ?? "", offered: $0["offered"] ?? "") }
    }

    /// The decision an agreed proposal makes for the registry: every entry the
    /// publish would replace is in one of the module's agreed proposals, with
    /// the same fields as the voters read. Nil when there is nothing to
    /// replace, or when any is not covered: then the publish is refused as
    /// before.
    func agreedLibraryTake(_ module: SHA256Digest, raw: Data, offer: [LibraryProposal],
                           reviewed: Bool) async throws -> (reasons: [String: String], proposals: [String])? {
        guard let book = typeProposals else { return nil }
        let agreed = await book.agreed(module: module.hex).filter { !($0.entries ?? [:]).isEmpty }
        guard !agreed.isEmpty else { return nil }
        let now = try await libraryReplacements(module, raw: raw, offer: offer, reviewed: reviewed)
        guard !now.isEmpty else { return nil }
        var reasons: [String: String] = [:]
        var ids: Set<String> = []
        for (id, entry) in now {
            guard let proposal = agreed.first(where: { $0.entries?[id] != nil }),
                  proposal.entries?[id]?.fields == entry.fields else { return nil }
            reasons[id] = Self.takenReason(proposal)
            ids.insert(proposal.id)
        }
        return (reasons, ids.sorted())
    }

    /// The reason an entry's history keeps for a replacement agents agreed.
    static func takenReason(_ proposal: TypeProposalBook.Proposal) -> String {
        let agreed = proposal.decided?.forced == true
            ? "decided by \(proposal.decided?.by ?? "an administrator")"
            : "agreed by " + proposal.agrees.joined(separator: " and ")
        return "\(proposal.reason) (proposal \(proposal.id) by \(proposal.author), \(agreed))"
    }

    /// A type as the module's program and the shared archive's copy beside
    /// the projects hold it, as C; empty where one holds none.
    func typeDefinition(_ module: SHA256Digest, name: String) async throws -> (program: String, shared: String) {
        let record = try await owner(of: module)
        let data = try await Self.call(record.port, "GET", "/v1/type?" + FormQuery.encode(["name": name])).data
        let answer = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((answer["program"] as? [String: Any])?["c"] as? String ?? "",
                (answer["shared"] as? [String: Any])?["c"] as? String ?? "")
    }

    /// The agreed proposals that cover every replacement this publish would
    /// make: each name in one of them, the module still defining it as
    /// proposed and the shared copy still the one the voters read. Nil when
    /// any is not covered; then the publish is refused as before.
    func agreedReplacement(_ module: SHA256Digest, replacements: [String]) async throws -> [String]? {
        guard let book = typeProposals, !replacements.isEmpty else { return nil }
        let agreed = await book.agreed(module: module.hex)
        guard !agreed.isEmpty else { return nil }
        var ids: Set<String> = []
        for name in replacements {
            guard let proposal = agreed.first(where: { $0.names.contains(name) }) else { return nil }
            let now = try await typeDefinition(module, name: name)
            guard now.program == proposal.moduleC[name], now.shared == proposal.sharedC[name] else { return nil }
            ids.insert(proposal.id)
        }
        return ids.sorted()
    }

    /// What a module that uses a replaced definition reads on its ticket.
    static func appliedRemark(_ proposal: TypeProposalBook.Proposal, names: [String], version: Int?) -> String {
        let author = proposal.name ?? proposal.module
        let agreed = proposal.decided?.forced == true
            ? "decided by \(proposal.decided?.by ?? "an administrator")"
            : "agreed by " + proposal.agrees.joined(separator: " and ")
        var what: [String] = []
        if !names.isEmpty {
            what.append("the shared type \(names.joined(separator: ", ")), as the shared types' version "
                + (version.map(String.init) ?? "?"))
        }
        let entries = (proposal.entries ?? [:]).sorted { $0.key < $1.key }
        if !entries.isEmpty {
            what.append("the library registry entry " + entries.map { "\($0.value.name) (\($0.key))" }
                .joined(separator: ", "))
        }
        var text = "Replaced by \(author)'s definition: " + what.joined(separator: "; and ")
            + " (proposal \(proposal.id), \(agreed))."
        if !names.isEmpty {
            text += " This module's program still holds its own old copy, and its stored C was exported with it. "
                + "Before this module's next publish, take the new definition into the program: "
                + "`ghidra_type` with `name` and `take_shared: true`, for each of "
                + names.joined(separator: ", ") + ". Without it the publish reads the old copy as a replacement "
                + "of the shared type and is refused. Then republish (`ghidra_publish`) so the stored C reads the "
                + "new layout."
        }
        return text + " Read this module's uses again (`ghidra_type_definition`, `ghidra_type_uses`, "
            + "`library_registry`): a field, a name or a parameter may have changed."
    }

    /// The proposals a finished publish applied marked so, and told on its
    /// ticket every other module that wrote a replaced definition, whose last
    /// published analysis names a replaced type, or whose links the registry
    /// moved to a replaced entry's new version.
    func noteProposalsApplied(_ ids: [String], module: SHA256Digest, revision: Int?, version: Int?,
                              relinked: [ContentStore.Relinked] = []) async {
        guard let book = typeProposals, !ids.isEmpty else { return }
        try? await book.markApplied(ids, revision: revision, version: version)
        var proposals: [TypeProposalBook.Proposal] = []
        for id in ids { if let proposal = await book.proposal(id) { proposals.append(proposal) } }
        guard let tickets else { return }
        Task.detached { [self] in
            let server = TicketBook.Caller(author: "byteripper-server", holder: "server")
            for proposal in proposals {
                let names = proposal.names.filter { name in
                    !(name.hasPrefix("_") && proposal.names.contains(String(name.dropFirst())))
                }
                var told: Set<String> = [module.hex]
                let text = Self.appliedRemark(proposal, names: names, version: version)
                func tell(_ other: SHA256Digest, revision: Int?, name: String?) async {
                    guard told.insert(other.hex).inserted else { return }
                    var revision = revision, name = name
                    if revision == nil || name == nil, let state = try? await project(other).state() {
                        revision = revision ?? state.published?.rev
                        name = name ?? state.module.name
                    }
                    _ = try? await tickets.add(
                        TicketBook.NewRemark(severity: .misleading, text: text, revision: revision),
                        module: other.hex, name: name, reviewer: nil, by: server)
                }
                // The modules that wrote the shared copies, whether or not
                // their code uses them: their definitions are the ones replaced.
                let writers = Set(proposal.origins.values).union((proposal.entries ?? [:]).values.compactMap(\.heldBy))
                for origin in writers.sorted() {
                    if let other = SHA256Digest(hex: origin.lowercased()) { await tell(other, revision: nil, name: nil) }
                }
                if !(proposal.entries ?? [:]).isEmpty {
                    for row in relinked { await tell(row.module, revision: nil, name: nil) }
                }
                for name in names {
                    guard let data = try? await typeUses(name: name, limit: 1),
                          let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    for row in answer["modules"] as? [[String: Any]] ?? [] {
                        guard let text = row["module"] as? String, let other = SHA256Digest(hex: text) else { continue }
                        await tell(other, revision: row["revision"] as? Int, name: row["name"] as? String)
                    }
                }
            }
        }
    }
}
