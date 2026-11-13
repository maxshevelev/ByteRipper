import CodeAnalysis
import Foundation
import GhidraHost
import HTTPService
import ServerConsole

/// The Ghidra role's routes, under `/ghidra/v1` (`Design/SERVER_PLAN.md` §6):
/// a module opened by its bytes, the owner's reads and writes by a closed
/// list, publish and release under the host's lease. No path of the server
/// is ever named in a request or an answer.
enum GhidraRoutes {
    static let prefix = "/ghidra/v1"

    /// The owner's read calls a client may make (`Design/GHIDRA_SHARED_PLAN.md` §7.1).
    static let reads: [String] = ["hello", "functions", "gaps", "function/", "disassembly/", "xrefs", "data", "strings", "review", "type",
                                   "types", "description"]
    /// The owner's write calls, each under the host's lease.
    static let writes: Set<String> = ["rename/function", "rename/label", "create/function", "delete/function", "set/flow",
                                      "merge/functions", "clear/locals", "rename/variable",
                                      "rename/variables", "set/signature", "set/comment", "set/comments",
                                      "set/data", "set/description", "set/code-mode", "redecode", "set/equate",
                                      "function/extend",
                                      "type", "save"]

    /// `ghidra.use` for every route; publish and release write into the store
    /// too, and need `cas.write` beside it (`Design/SERVER_HEADLESS_PLAN.md`
    /// decision 4).
    /// The console's Leases page: the same rows and the same close as the routes.
    static func consoleLeases(_ host: GhidraHost) -> ConsoleLeases {
        ConsoleLeases(list: {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(await host.leaseRows())) ?? Data("[]".utf8)
        }, close: { module, by in
            let digest = try digest(module)
            let closed = try await answer { try await host.closeLease(digest, by: by) }
            return try JSONEncoder().encode(closed)
        }, localHolder: localHolder)
    }

    /// The console's Issues page over the host's reports.
    static func consoleIssues(_ host: GhidraHost) -> ConsoleIssues? {
        guard let book = host.issues else { return nil }
        return ConsoleIssues(list: { all in
            (try? IssueBook.encoder.encode(await book.list(all: all))) ?? Data("[]".utf8)
        }, resolve: { id, by, note in
            let resolved = try await answer { try await book.resolve(id, by: by, note: note) }
            return try IssueBook.encoder.encode(resolved)
        })
    }

    /// The console's Tickets page over the host's review board.
    static func consoleTickets(_ host: GhidraHost) -> ConsoleTickets? {
        guard let book = host.tickets else { return nil }
        return ConsoleTickets(list: {
            (try? TicketBook.encoder.encode(await book.list().map(TicketBook.Listed.init))) ?? Data("[]".utf8)
        }, force: { module, remark, status, close, note, by in
            var value: TicketBook.Status?
            if let status {
                guard let known = TicketBook.Status(rawValue: status) else {
                    throw HTTPError(.badRequest, "no status \(status)")
                }
                value = known
            }
            let ticket = try await answer { try await book.force(module: module, remark: remark, status: value,
                                                                  close: close, note: note, by: by) }
            return try TicketBook.encoder.encode(TicketBook.Listed(ticket))
        }, proposals: host.typeProposals.map { proposals in
            { (try? TicketBook.encoder.encode(await proposals.list().map(TypeProposalBook.Listed.init))) ?? Data("[]".utf8) }
        }, decide: host.typeProposals.map { _ in
            { id, agree, note, by in
                let proposal = try await answer { try await host.decideProposal(id, agree: agree, note: note, by: by) }
                return try TicketBook.encoder.encode(TypeProposalBook.Listed(proposal))
            }
        })
    }

    /// Who holds a module taken on the server's own MCP socket.
    static let localHolder = "local MCP"

    static func routes(host: GhidraHost, kit: ReviewKit? = nil,
                       published: @escaping @Sendable () async -> Void) -> HTTPRouter {
        var router = HTTPRouter()

        // A report about a tool, by whoever the token is; an administrator
        // lists them and marks one resolved (`IssueBook`).
        router.add("POST", "\(prefix)/issues", maxBodyBytes: 256 << 10, access: .rights([.ghidraUse])) { request in
            let report = try request.json(IssueBook.Report.self)
            let data = try await answer { try await host.reportIssue(report, by: holder(request)) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }
        // The token's own reports, open and resolved, with the answers.
        router.add("GET", "\(prefix)/issues/mine", access: .rights([.ghidraUse])) { request in
            let limit = Int(request.query["limit"] ?? "") ?? 50
            let data = try await answer { try await host.myIssues(by: holder(request), limit: min(max(limit, 1), 200)) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }
        // The review board: every call one route, the caller's holder the
        // token's name, the agent's own name in the request (`TicketBook`).
        router.add("POST", "\(prefix)/tickets", maxBodyBytes: 256 << 10, access: .rights([.ghidraUse])) { request in
            let call = try request.json(TicketBook.Request.self)
            let data = try await answer { try await host.ticketCall(call, holder: holder(request)) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }
        // Agents' proposals to replace shared types, and their votes
        // (`TypeProposalBook`): the holder is the token's name.
        router.add("POST", "\(prefix)/type-proposals", maxBodyBytes: 256 << 10, access: .rights([.ghidraUse])) { request in
            let call = try request.json(TypeProposalBook.Request.self)
            let data = try await answer { try await host.typeProposalCall(call, holder: holder(request)) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }
        router.add("GET", "\(prefix)/issues", access: .rights([.admin])) { request in
            guard let book = host.issues else { throw HTTPError(.notFound, "this server keeps no reports") }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"],
                                body: try IssueBook.encoder.encode(await book.list(all: request.query["all"] == "1")))
        }

        // Whether an owner has the module open, and whether that program
        // holds writes the store has not got: what `code_query` answers as
        // `live` and `unpublished_writes`. Asking starts no owner.
        router.add("GET", "\(prefix)/live/:module", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            let unpublished = try await answer { try await host.ownerHasUnpublishedWrites(module) }
            return .json(GhidraLive(live: unpublished != nil, unpublishedWrites: unpublished))
        }

        // The review kit (`ReviewKit`): the manifest, then each file by its
        // path. A server whose folder has no kit says so, and a client then
        // offers its agents nothing.
        router.add("GET", "\(prefix)/kit", access: .rights([.ghidraUse])) { _ in
            guard let kit else { throw HTTPError(.notFound, "this server has no review kit") }
            return .json(kit.manifest)
        }
        router.add("GET", "\(prefix)/kit/*path", access: .rights([.ghidraUse])) { request in
            let path = request.parameters["path"] ?? ""
            guard let text = kit?.texts[path] else { throw HTTPError(.notFound, "\(path) is not a file of the review kit") }
            return .bytes(Data(text.utf8), type: "text/markdown; charset=utf-8")
        }

        router.add("GET", "\(prefix)/modules", access: .rights([.ghidraUse])) { _ in
            .json(await host.summaries())
        }

        // Open a module by its bytes: its project is made the first time —
        // tens of seconds for a large DXE driver — and its owner started.
        router.add("POST", "\(prefix)/modules", access: .rights([.ghidraUse])) { request in
            guard !request.body.isEmpty else { throw HTTPError(.badRequest, "send the module's bytes as the body") }
            let name = request.query["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "module"
            guard name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }) else {
                throw HTTPError(.badRequest, "a module's name is letters, digits, '.', '_' and '-'")
            }
            let phase = try request.query["phase"].map { text -> GhidraHost.Phase in
                guard let phase = GhidraHost.Phase(rawValue: text) else {
                    throw HTTPError(.badRequest, "phase is pei or dxe")
                }
                return phase
            }
            let source = ProjectState.Source(path: nil, document: request.query["document"], node: request.query["node"])
            let state = try await answer {
                try await host.create(module: request.body, name: name, source: source, phase: phase,
                                      uefi: request.query["uefi"] != "0")
            }
            let module = SHA256Digest(data: request.body)
            // The owner's hello, as a host on this Mac answers `ghidra_create`:
            // the program, its functions, `changed`, `writes_lost`, the
            // language patch. What the project adds goes beside it.
            let hello = try await answer { try await host.read(module, "/v1/hello") }
            let opened = try JSONEncoder().encode(Opened(module: module.hex, name: state.module.name, kind: state.module.kind,
                                                         phase: state.module.phase, reviewed: state.reviewed,
                                                         published: state.published))
            var merged = (try? JSONSerialization.jsonObject(with: hello)) as? [String: Any] ?? [:]
            for (key, value) in (try JSONSerialization.jsonObject(with: opened)) as? [String: Any] ?? [:]
            where merged[key] == nil {
                merged[key] = value
            }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"],
                                body: try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]))
        }

        router.add("GET", "\(prefix)/modules/:module/*call", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            let call = request.parameters["call"] ?? ""
            guard reads.contains(where: { $0.hasSuffix("/") ? call.hasPrefix($0) && call.count > $0.count : call == $0 }) else {
                throw HTTPError(.notFound, "\(call) is not a read of the bridge")
            }
            let data = try await answer {
                await host.throughRegistry(try await host.read(module, "/v1/\(call)" + query(request),
                                                               holder: holder(request)),
                                           module: module, call: call)
            }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }

        router.add("POST", "\(prefix)/modules/:module/write/*call", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            let call = request.parameters["call"] ?? ""
            guard writes.contains(call) else { throw HTTPError(.notFound, "\(call) is not a write of the bridge") }
            let data = try await answer {
                try await host.write(module, "/v1/\(call)", body: request.body, holder: holder(request))
            }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }

        router.add("POST", "\(prefix)/modules/:module/preview/*call", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            let call = request.parameters["call"] ?? ""
            guard call == "preview/equate" else { throw HTTPError(.notFound, "\(call) is not a preview of the bridge") }
            let data = try await answer {
                try await host.preview(module, "/v1/\(call)", body: request.body, holder: holder(request))
            }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }

        router.add("POST", "\(prefix)/modules/:module/publish", access: .rights([.ghidraUse, .casWrite])) { request in
            let module = try digest(request.parameters["module"])
            // A shared type or a registry entry is replaced by an agreed
            // proposal alone, which the publish applies; a publish carries no
            // replacement of its own.
            let options = GhidraHost.PublishOptions(entryReasons: Self.entryReasons(request))
            // `dry_run`: what the publish would store, exported and answered —
            // nothing is written, so the store's right is not needed for it.
            if let dryRun = request.query["dry_run"], dryRun != "0", !dryRun.isEmpty {
                let data = try await answer {
                    try await host.preview(module, entryReasons: options.entryReasons, holder: holder(request))
                }
                return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
            }
            let publication = try await answer {
                try await host.publish(module, by: by(request), options: options, holder: holder(request))
            }
            await published()
            return .json(PublishAnswer(publication))
        }

        router.add("POST", "\(prefix)/modules/:module/release", access: .rights([.ghidraUse, .casWrite])) { request in
            let module = try digest(request.parameters["module"])
            let discard = request.query["discard"] == "1"
            guard let publication = try await answer({
                try await host.release(module, by: by(request), holder: holder(request), discard: discard)
            }) else {
                return .json(PublishAnswer(nil))
            }
            await published()
            return .json(PublishAnswer(publication))
        }

        // The module against the library registry: read, applied under the
        // host's lease like any write, an entry declined or read.
        router.add("POST", "\(prefix)/modules/:module/library", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            let asked: GhidraHost.LibraryRequest
            do {
                asked = try JSONDecoder().decode(GhidraHost.LibraryRequest.self, from: request.body)
            } catch {
                throw HTTPError(.badRequest, "the body is {\"action\": \"status\" | \"apply\" | \"decline\" | \"entry\", …}")
            }
            // A citation only adds; a change of the registry itself is a
            // proposal's, applied once agreed.
            let data = try await answer { try await host.library(module, asked, holder: holder(request)) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }

        router.add("POST", "\(prefix)/modules/:module/stop", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            return .json(["stopped": await host.stop(module)])
        }

        // Where each module's stored analysis names a type: a read of the store
        // across modules, so it belongs to no one module and needs no owner.
        router.add("GET", "\(prefix)/type-uses", access: .rights([.ghidraUse])) { request in
            guard let name = request.query["name"], !name.isEmpty else {
                throw HTTPError(.badRequest, "name the type: ?name=")
            }
            let limit = request.query["limit"].flatMap(Int.init) ?? 200
            let data = try await answer { try await host.typeUses(name: name, limit: limit) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }

        // The kept project let go: the owner stopped, the folder and the
        // store's copy of the project moved to the Trash. The revisions, their
        // artifacts and the shared review types stay.
        router.add("DELETE", "\(prefix)/modules/:module", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            let forgotten = try await answer { try await host.forget(module, holder: holder(request)) }
            return .json(forgotten.answer)
        }

        // The module taken into work by the token's holder (stage 2.4): only
        // it writes and publishes until it gives the module back — `release`
        // — or an administrator closes the lease.
        router.add("POST", "\(prefix)/modules/:module/lease", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            return .json(try await answer { try await host.take(module, holder: holder(request)) })
        }

        // Every module in work, and the leases closed and not yet taken again.
        router.add("GET", "\(prefix)/leases", access: .rights([.ghidraUse])) { _ in
            .json(await host.leaseRows())
        }

        // An administrator's close: the holder's unpublished changes go with
        // the working project, and the holder is told at its next call.
        router.add("DELETE", "\(prefix)/leases/:module", access: .rights([.admin])) { request in
            let module = try digest(request.parameters["module"])
            let by = request.principal?.name ?? "an administrator"
            return .json(try await answer { try await host.closeLease(module, by: by) })
        }

        // Answers when the token's lease of the module ends, or after
        // `seconds` (at most 300): a client holding a module keeps one open
        // and hears at once that an administrator closed it.
        router.add("GET", "\(prefix)/leases/:module/wait", access: .rights([.ghidraUse])) { request in
            let module = try digest(request.parameters["module"])
            let seconds = min(300, max(1, request.query["seconds"].flatMap(Int.init) ?? 60))
            return .json(await host.waitForLeaseEnd(module, holder: holder(request), seconds: seconds))
        }
        return router
    }

    /// What a publish carries for the registry: the reasons this review adds
    /// to each entry it moves (`{"entry_reasons": {"<id>": "…"}}`), kept in
    /// the entry's history. An addition, never a replacement.
    static func entryReasons(_ request: HTTPRequest) -> [String: String] {
        let asked = request.body.isEmpty ? nil : try? JSONDecoder().decode(PublishBody.self, from: request.body)
        return asked?.entryReasons ?? [:]
    }

    /// A publish's body: the reasons for the entries it adds to.
    struct PublishBody: Decodable {
        var entryReasons: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case entryReasons = "entry_reasons"
        }
    }

    struct Opened: Codable {
        var module: String
        var name: String
        var kind: String
        var phase: String?
        var reviewed: Bool
        var published: ProjectState.Published?
    }

    nonisolated(unsafe) static var projectsRoot = ServerPaths.projects

    static func hidingPaths(_ text: String) -> String {
        text.replacingOccurrences(of: projectsRoot.path, with: "<projects>")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Who a request holds a module as: its token's name.
    static func holder(_ request: HTTPRequest) -> String {
        request.principal.map { "token \($0.name)" } ?? "an HTTP client"
    }

    static func by(_ request: HTTPRequest) throws -> String {
        let by = request.query["by"] ?? "agent"
        guard by == "agent" || by == "person" else { throw HTTPError(.badRequest, "by is agent or person") }
        return by
    }

    static func digest(_ text: String?) throws -> SHA256Digest {
        guard let text, let digest = SHA256Digest(hex: text) else {
            throw HTTPError(.badRequest, "\(text ?? "nothing") is not a module's SHA-256")
        }
        return digest
    }

    static func query(_ request: HTTPRequest) -> String {
        guard !request.query.isEmpty else { return "" }
        return "?" + FormQuery.encode(request.query)
    }

    /// The host's refusal as the status a client acts on. The server's own
    /// folders are not named to a client: the full words are in the server's
    /// log, and the answer says `<projects>` and `~` instead.
    static func answer<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as GhidraHostError {
            let message = hidingPaths(error.message)
            switch error.kind {
            case .refused:
                throw HTTPError(HTTPStatus(error.status == 0 ? 400 : error.status, "Refused"), message)
            case .project:
                throw HTTPError(error.status == 404 ? .notFound : .unprocessable, message)
            case .install, .owner:
                throw HTTPError(.unavailable, message)
            }
        } catch let error as CodeAnalysisError {
            throw HTTPError(.conflict, error.description)
        }
    }
}
