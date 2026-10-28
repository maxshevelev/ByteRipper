import CodeAnalysis
import Foundation
import GhidraHost
import HTTPService

/// The Ghidra role's routes, under `/ghidra/v1` (`Design/SERVER_PLAN.md` §6):
/// a module opened by its bytes, the owner's reads and writes by a closed
/// list, publish and release under the host's lease. No path of the server
/// is ever named in a request or an answer.
enum GhidraRoutes {
    static let prefix = "/ghidra/v1"

    /// The owner's read calls a client may make (`Design/GHIDRA_SHARED_PLAN.md` §7.1).
    static let reads: [String] = ["hello", "functions", "function/", "disassembly/", "xrefs", "data", "strings", "review", "type",
                                   "description"]
    /// The owner's write calls, each under the host's lease.
    static let writes: Set<String> = ["rename/function", "rename/label", "create/function", "rename/variable", "set/signature", "set/comment",
                                      "set/data", "set/description", "set/code-mode", "set/equate", "type", "save"]

    static func routes(host: GhidraHost, published: @escaping @Sendable () async -> Void) -> HTTPRouter {
        var router = HTTPRouter()

        router.add("GET", "\(prefix)/modules") { _ in
            .json(await host.summaries())
        }

        // Open a module by its bytes: its project is made the first time —
        // tens of seconds for a large DXE driver — and its owner started.
        router.add("POST", "\(prefix)/modules") { request in
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
            _ = try await answer { try await host.read(module, "/v1/hello") }
            return .json(Opened(module: module.hex, name: state.module.name, kind: state.module.kind,
                                phase: state.module.phase, reviewed: state.reviewed, published: state.published))
        }

        router.add("GET", "\(prefix)/modules/:module/*call") { request in
            let module = try digest(request.parameters["module"])
            let call = request.parameters["call"] ?? ""
            guard reads.contains(where: { $0.hasSuffix("/") ? call.hasPrefix($0) && call.count > $0.count : call == $0 }) else {
                throw HTTPError(.notFound, "\(call) is not a read of the bridge")
            }
            let data = try await answer { try await host.read(module, "/v1/\(call)" + query(request)) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }

        router.add("POST", "\(prefix)/modules/:module/write/*call") { request in
            let module = try digest(request.parameters["module"])
            let call = request.parameters["call"] ?? ""
            guard writes.contains(call) else { throw HTTPError(.notFound, "\(call) is not a write of the bridge") }
            let data = try await answer { try await host.write(module, "/v1/\(call)", body: request.body) }
            return HTTPResponse(.ok, headers: ["content-type": "application/json"], body: data)
        }

        router.add("POST", "\(prefix)/modules/:module/publish") { request in
            let module = try digest(request.parameters["module"])
            let publication = try await answer { try await host.publish(module, by: by(request)) }
            await published()
            return .json(Published(manifest: publication.manifest, typeConflicts: publication.typeConflicts))
        }

        router.add("POST", "\(prefix)/modules/:module/release") { request in
            let module = try digest(request.parameters["module"])
            guard let publication = try await answer({ try await host.release(module, by: by(request)) }) else {
                return .json(Published(manifest: nil, typeConflicts: []))
            }
            await published()
            return .json(Published(manifest: publication.manifest, typeConflicts: publication.typeConflicts))
        }

        router.add("POST", "\(prefix)/modules/:module/stop") { request in
            let module = try digest(request.parameters["module"])
            return .json(["stopped": await host.stop(module)])
        }
        return router
    }

    struct Opened: Codable {
        var module: String
        var name: String
        var kind: String
        var phase: String?
        var reviewed: Bool
        var published: ProjectState.Published?
    }

    struct Published: Codable {
        var manifest: AnalysisManifest?
        var typeConflicts: [String]

        private enum CodingKeys: String, CodingKey {
            case manifest
            case typeConflicts = "type_conflicts"
        }
    }

    nonisolated(unsafe) static var projectsRoot = GhidraHost.defaultProjectsRoot

    static func hidingPaths(_ text: String) -> String {
        text.replacingOccurrences(of: projectsRoot.path, with: "<projects>")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
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
        var components = URLComponents()
        components.queryItems = request.query.keys.sorted().map { URLQueryItem(name: $0, value: request.query[$0]) }
        return "?" + (components.percentEncodedQuery ?? "")
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
