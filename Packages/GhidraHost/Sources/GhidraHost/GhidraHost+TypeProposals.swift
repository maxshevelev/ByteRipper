import CodeAnalysis
import Foundation

/// Agents agreeing a replacement of shared types (`TypeProposalBook`): the
/// host finds what the module's publish would replace, keeps both texts in
/// the proposal, and applies an agreed proposal at the module's next publish.
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
            throw GhidraHostError(.refused, "take the module into work first (`ghidra_take`): only its holder proposes "
                + "the types its publish would replace", status: 409)
        }
        let preview = (try JSONSerialization.jsonObject(with: try await self.preview(module, holder: holder))
            as? [String: Any]) ?? [:]
        let origins = preview["type_conflict_origins"] as? [String: String] ?? [:]
        let names = (preview["type_conflicts"] as? [String] ?? []).filter { !(origins[$0] ?? "").hasPrefix("withdrawn ") }
        var moduleC: [String: String] = [:]
        var sharedC: [String: String] = [:]
        for name in names {
            let definition = try await typeDefinition(module, name: name)
            moduleC[name] = definition.program
            sharedC[name] = definition.shared
        }
        let language = ((try? JSONSerialization.jsonObject(with: try await read(module, "/v1/hello", holder: holder)))
            as? [String: Any])?["language"] as? String ?? ""
        return TypeProposalBook.Draft(module: module.hex, name: try? project(module).state().module.name,
                                      bits: Self.archiveBits(language: language), names: names, moduleC: moduleC,
                                      sharedC: sharedC, origins: origins.filter { names.contains($0.key) })
    }

    /// A type as the module's program and the shared archive's copy beside
    /// the projects hold it, as C; empty where one holds none.
    func typeDefinition(_ module: SHA256Digest, name: String) async throws -> (program: String, shared: String) {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "name", value: name)]
        let record = try await owner(of: module)
        let data = try await Self.call(record.port, "GET", "/v1/type?" + (query.percentEncodedQuery ?? "")).data
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

    /// What a module that uses a replaced type reads on its ticket.
    static func appliedRemark(_ proposal: TypeProposalBook.Proposal, names: [String], version: Int?) -> String {
        let types = names.joined(separator: ", ")
        let author = proposal.name ?? proposal.module
        let number = version.map(String.init) ?? "?"
        let agreed = proposal.decided?.forced == true
            ? "decided by \(proposal.decided?.by ?? "an administrator")"
            : "agreed by " + proposal.agrees.joined(separator: " and ")
        return "The shared type \(types) was replaced by \(author)'s definition, as the shared types' version "
            + "\(number) (type proposal \(proposal.id), \(agreed)). Read this module's uses of it again "
            + "(`ghidra_type_definition`, `ghidra_type_uses`): a field may have moved or been renamed."
    }

    /// The proposals a finished publish applied marked so, and told on its
    /// ticket every other module that wrote the shared copy or whose last
    /// published analysis names a replaced type. The second reads every module's artifact: it runs on its own.
    func noteProposalsApplied(_ ids: [String], module: SHA256Digest, revision: Int?, version: Int?) async {
        guard let book = typeProposals, !ids.isEmpty else { return }
        try? await book.markApplied(ids, revision: revision, version: version)
        var proposals: [TypeProposalBook.Proposal] = []
        for id in ids { if let proposal = await book.proposal(id) { proposals.append(proposal) } }
        guard let tickets else { return }
        Task.detached { [self] in
            for proposal in proposals {
                let names = proposal.names.filter { name in
                    !(name.hasPrefix("_") && proposal.names.contains(String(name.dropFirst())))
                }
                var told: Set<String> = [module.hex]
                let text = Self.appliedRemark(proposal, names: names, version: version)
                let server = TicketBook.Caller(author: "byteripper-server", holder: "server")
                // The module that wrote the shared copy, whether or not its
                // code uses the type: its definition is the one replaced.
                for origin in Set(proposal.origins.values).sorted() {
                    guard let writer = SHA256Digest(hex: origin.lowercased()), told.insert(writer.hex).inserted else {
                        continue
                    }
                    let state = try? await project(writer).state()
                    _ = try? await tickets.add(
                        TicketBook.NewRemark(severity: .misleading, text: text, revision: state?.published?.rev),
                        module: writer.hex, name: state?.module.name, reviewer: nil, by: server)
                }
                for name in names {
                    guard let data = try? await typeUses(name: name, limit: 1),
                          let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    for row in answer["modules"] as? [[String: Any]] ?? [] {
                        guard let other = row["module"] as? String, told.insert(other).inserted else { continue }
                        _ = try? await tickets.add(
                            TicketBook.NewRemark(severity: .misleading, text: text, revision: row["revision"] as? Int),
                            module: other, name: row["name"] as? String, reviewer: nil, by: server)
                    }
                }
            }
        }
    }
}
