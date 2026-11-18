import CodeAnalysis
import Foundation

/// The review board on the host: a call names the module, the host adds what
/// it knows of it — its name, its published revision, the agent that took it
/// into work — and the board keeps the rules (`TicketBook`).
extension GhidraHost {
    /// Whether the module has a kept project here or a revision in the store.
    public func holdsModule(_ module: String) async -> Bool {
        guard let digest = SHA256Digest(hex: module.lowercased()) else { return false }
        if project(digest).exists { return true }
        return (try? await writer.latestRevision(module: digest)) != nil
    }

    /// A ticket for a module this server does not hold, taken off the board.
    /// One for a module it holds stays: its review is the board's record.
    public func removeStrayTicket(_ module: String) async throws -> TicketBook.Ticket {
        guard let tickets else {
            throw GhidraHostError(.install, "this host keeps no review board: there is no analysis server to keep it")
        }
        let key = module.trimmingCharacters(in: .whitespaces).lowercased()
        if await holdsModule(key) {
            throw GhidraHostError(.refused, "\(key) is a module this server holds: its ticket stays — close or "
                                  + "open it instead", status: 409)
        }
        return try await tickets.remove(module: key)
    }

    public func ticketCall(_ request: TicketBook.Request, holder: String) async throws -> Data {
        guard let tickets else {
            throw GhidraHostError(.install, "this host keeps no review board: there is no analysis server to keep it")
        }
        let caller = TicketBook.Caller(author: request.agent ?? "", holder: holder)
        let module = request.module?.trimmingCharacters(in: .whitespaces).lowercased()
        func known(_ module: String) -> (name: String?, revision: Int?) {
            guard let digest = SHA256Digest(hex: module) else { return (nil, nil) }
            let state = try? project(digest).state()
            return (state?.module.name, state?.published?.rev)
        }
        func required() throws -> String {
            guard let module, !module.isEmpty else {
                throw GhidraHostError(.refused, "name the `module`, by the SHA-256 of its bytes", status: 400)
            }
            return module
        }
        // A write names a module this server holds: a mistyped SHA-256 made a
        // ticket for no module, closed, with no name and no reviewer.
        func held() async throws -> String {
            let module = try required()
            guard await holdsModule(module) else {
                throw GhidraHostError(.refused, "\(module) is no module this server holds — no project and no "
                                      + "published revision; `ghidra_modules` lists them", status: 404)
            }
            return module
        }
        switch request.action {
        case .list:
            let rows = await tickets.list(state: request.state, module: module, author: request.author)
            return try TicketBook.encoder.encode(rows.map(TicketBook.Listed.init))
        case .read:
            let module = try required()
            guard let ticket = await tickets.ticket(module) else {
                return try TicketBook.encoder.encode(["module": module, "state": "none"])
            }
            return try TicketBook.encoder.encode(TicketBook.Listed(ticket))
        case .add:
            let module = try await held()
            guard var remark = request.remark else {
                throw GhidraHostError(.refused, "give the `remark`: its severity and text", status: 400)
            }
            let facts = known(module)
            if remark.revision == nil { remark.revision = facts.revision }
            let ticket = try await tickets.add(remark, module: module, name: facts.name, reviewer: nil, by: caller)
            return try TicketBook.encoder.encode(TicketBook.Listed(ticket))
        case .reply:
            let module = try await held()
            guard let id = request.id else {
                throw GhidraHostError(.refused, "name the remark's `id`", status: 400)
            }
            let ticket = try await tickets.reply(module: module, remark: id, text: request.text, status: request.status,
                                                 revision: request.revision, by: caller)
            return try TicketBook.encoder.encode(TicketBook.Listed(ticket))
        case .close:
            let module = try await held()
            let ticket = try await tickets.close(module: module, name: known(module).name, reviewer: nil,
                                                 note: request.note, by: caller)
            return try TicketBook.encoder.encode(TicketBook.Listed(ticket))
        case .reviewer:
            let module = try await held()
            let name = request.agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { try await tickets.noteReviewer(module, name: known(module).name, author: name) }
            guard let ticket = await tickets.ticket(module) else {
                return try TicketBook.encoder.encode(["module": module, "state": "none"])
            }
            return try TicketBook.encoder.encode(TicketBook.Listed(ticket))
        }
    }
}
