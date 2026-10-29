import AgentKit
import DumpHost
import Foundation
import HTTPService
import ServerAuth
import ServerMCP

/// The web console at `/admin` (`Design/SERVER_HEADLESS_PLAN.md` §8): the
/// documents, the activity, the tokens and the status, behind a session an
/// admin token signs in.
///
/// The shell — the page, its stylesheet and its script — holds no data and is
/// `.open`, named page by page so it can never answer for `/admin/api/*`.
/// Everything it shows comes from `/admin/api/*`, which needs the session
/// (and, to change anything, its CSRF token: `ServerAuthorizer`). `Host` and
/// `Origin` are checked before any of it, by `ConsoleNames` on admission.
public struct Console: Sendable {
    public let registry: DocumentRegistry
    public let tokens: TokenStore
    public let authorizer: ServerAuthorizer
    public let gate: SignInGate
    public let rest: RESTActivity
    public let mcp: ServerActivity?
    public let status: @Sendable () async -> ConsoleStatus
    let assets: ConsoleAssets

    public init(registry: DocumentRegistry, tokens: TokenStore, authorizer: ServerAuthorizer,
                gate: SignInGate = SignInGate(), rest: RESTActivity, mcp: ServerActivity?,
                status: @escaping @Sendable () async -> ConsoleStatus) throws {
        self.registry = registry
        self.tokens = tokens
        self.authorizer = authorizer
        self.gate = gate
        self.rest = rest
        self.mcp = mcp
        self.status = status
        assets = try ConsoleAssets.load()
    }

    /// The pages the shell answers, each by name (§5): a pattern such as
    /// `/admin/*page` would answer the API's GETs too.
    public static let pages = ["/admin", "/admin/login", "/admin/documents", "/admin/activity",
                               "/admin/tokens", "/admin/status"]

    public func routes(uploadLimit: UInt64) -> HTTPRouter {
        var router = HTTPRouter()
        func add(_ method: String, _ path: String, access: HTTPAccess = .rights([.admin]), maxBodyBytes: Int? = nil,
                 _ handler: @escaping HTTPRouter.Handler) {
            router.add(method, path, maxBodyBytes: maxBodyBytes, access: access) { request in
                do {
                    return Self.secured(try await handler(request))
                } catch {
                    // What the console refuses carries its headers too. A
                    // request no session admits never gets here: the
                    // authorizer answers it before any route, in the
                    // server's own shape.
                    return Self.secured(.error(error as? HTTPError
                        ?? HTTPError(.internalError, "\(error)")))
                }
            }
        }
        let assets = self.assets

        // The shell.
        for page in Self.pages {
            add("GET", page, access: .open) { _ in assets.page }
        }
        for name in assets.files.keys.sorted() {
            add("GET", "/admin/assets/\(name)", access: .open) { _ in assets.files[name]! }
        }

        // Signing in and out.
        add("POST", "/admin/login", access: .open, maxBodyBytes: 4096) { request in try await signIn(request) }
        add("POST", "/admin/logout") { request in signOut(request) }
        add("GET", "/admin/api/session") { request in
            Self.json(["name": .string(request.principal?.name ?? ""), "token": .string(request.principal?.id ?? "")])
        }

        // Documents.
        let registry = self.registry
        add("GET", "/admin/api/documents") { _ in Self.json(await Self.documents(registry)) }
        add("POST", "/admin/api/documents") { request in
            struct Opening: Decodable {
                let path: String
                let name: String?
            }
            let opening = try request.json(Opening.self)
            let path = opening.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { throw HTTPError(.badRequest, "give the dump's path") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let name = opening.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = try await Self.refusing { try await registry.open(path: url, name: name?.isEmpty == false ? name : nil) }
            return Self.json(["id": .string(id)])
        }
        add("POST", "/admin/api/uploads", maxBodyBytes: Int(clamping: uploadLimit)) { request in
            let name = (request.query["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw HTTPError(.badRequest, "give the upload a name: ?name=") }
            guard !request.body.isEmpty else { throw HTTPError(.badRequest, "the upload is empty") }
            let id = try await Self.refusing { try await registry.upload(request.body, name: String(name.prefix(200))) }
            return Self.json(["id": .string(id)])
        }
        add("POST", "/admin/api/documents/:id/reopen") { request in
            let id = request.parameters["id"] ?? ""
            try await Self.refusing { try await registry.reopen(id) }
            return Self.json(["id": .string(id)])
        }
        add("POST", "/admin/api/documents/:id/close") { request in
            let id = request.parameters["id"] ?? ""
            try await Self.refusing { try await MainActor.run { try registry.close(id) } }
            return Self.json(["id": .string(id)])
        }
        add("POST", "/admin/api/documents/:id/forget") { request in
            let id = request.parameters["id"] ?? ""
            try await Self.refusing { try await MainActor.run { try registry.forget(id) } }
            return Self.json(["id": .string(id)])
        }
        add("DELETE", "/admin/api/documents/:id") { request in
            let id = request.parameters["id"] ?? ""
            try await Self.refusing { try await MainActor.run { try registry.delete(id) } }
            return Self.json(["id": .string(id)])
        }
        add("PUT", "/admin/api/documents/order") { request in
            struct Order: Decodable { let ids: [String] }
            let order = try request.json(Order.self)
            try await Self.refusing { try await MainActor.run { try registry.reorder(order.ids) } }
            return Self.json(["ids": .array(order.ids.map { .string($0) })])
        }

        // Activity.
        let rest = self.rest
        let mcp = self.mcp
        add("GET", "/admin/api/activity") { _ in
            let agents = await MainActor.run { mcp?.listed ?? [] }
            return Self.json([
                "mcp": .array(agents.map(Self.agent)),
                "rest": .array(rest.listed.map(Self.client))
            ])
        }

        // Tokens.
        add("GET", "/admin/api/tokens") { request in Self.json(tokenList(yours: request.principal?.id)) }
        add("POST", "/admin/api/tokens") { request in try makeToken(request) }
        add("POST", "/admin/api/tokens/:id/rotate") { request in try rotate(request) }
        add("POST", "/admin/api/tokens/:id/revoke") { request in try revoke(request) }

        // Status.
        let status = self.status
        let sessions = authorizer.sessions
        add("GET", "/admin/api/status") { _ in
            let now = await status()
            let held = await MainActor.run { () -> (DumpLimits, Int, Int, UInt64) in
                let open = registry.rows.compactMap(\.host)
                return (registry.limits, open.count, registry.rows.count - open.count,
                        open.reduce(0) { $0 + $1.contentSize })
            }
            return Self.json(now.json(limits: held.0, sessions: sessions.count,
                                      documents: (held.1, held.2, held.3)))
        }
        return router
    }

    // MARK: - Signing in

    private func signIn(_ request: HTTPRequest) async throws -> HTTPResponse {
        let secret = Self.secret(in: request)
        guard !secret.isEmpty else { throw HTTPError(.badRequest, "give the admin token") }
        let authorizer = self.authorizer
        let tokens = self.tokens
        let session = try await gate.attempt { try authorizer.signIn(secret: secret) }
        let name = tokens.principal(for: secret)?.name ?? ""
        var response = Self.json(["name": .string(name)])
        response.cookies = [
            "\(AdminCookie.session)=\(session.id); Path=/admin; HttpOnly; SameSite=Strict",
            "\(AdminCookie.csrf)=\(session.csrf); Path=/admin; SameSite=Strict"
        ]
        return response
    }

    private func signOut(_ request: HTTPRequest) -> HTTPResponse {
        if let id = ServerAuthorizer.cookie(AdminCookie.session, in: request.headers) {
            authorizer.sessions.end(id)
        }
        var response = Self.json(["signed_out": true])
        response.cookies = [
            "\(AdminCookie.session)=; Path=/admin; HttpOnly; SameSite=Strict; Max-Age=0",
            "\(AdminCookie.csrf)=; Path=/admin; SameSite=Strict; Max-Age=0"
        ]
        return response
    }

    /// The token a sign-in sends: JSON `{"token": …}` from the page, or a
    /// form's `token=…`.
    static func secret(in request: HTTPRequest) -> String {
        if request.headers["content-type"]?.hasPrefix("application/json") == true {
            struct SignIn: Decodable { let token: String }
            return (try? JSONDecoder().decode(SignIn.self, from: request.body).token)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let form = String(decoding: request.body, as: UTF8.self)
        for pair in form.split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard field.count == 2, field[0] == "token" else { continue }
            return (String(field[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Tokens

    private func tokenList(yours: String?) -> JSONValue {
        let listed = tokens.all().sorted { a, b in
            a.revoked != b.revoked ? !a.revoked : a.created < b.created
        }
        return [
            "tokens": .array(listed.map { token in
                var members: [String: JSONValue] = [
                    "id": .string(token.id),
                    "name": .string(token.name),
                    "rights": .array(token.rights.map { .string($0.rawValue) }),
                    "created": .string(Self.date(token.created)),
                    "revoked": .bool(token.revoked),
                    "yours": .bool(token.id == yours)
                ]
                if let used = token.lastUsed { members["last_used"] = .string(Self.date(used)) }
                return .object(members)
            }),
            "presets": .object(Dictionary(uniqueKeysWithValues: TokenPreset.allCases.map { preset in
                (preset.rawValue, JSONValue.array(preset.rights.map(\.rawValue).sorted().map { .string($0) }))
            })),
            "rights": .array(HTTPRight.allCases.map { .string($0.rawValue) })
        ]
    }

    private func makeToken(_ request: HTTPRequest) throws -> HTTPResponse {
        struct Making: Decodable {
            let name: String
            let preset: String?
            let rights: [String]?
        }
        let making = try request.json(Making.self)
        var rights: Set<HTTPRight>
        if let preset = making.preset {
            guard let known = TokenPreset(rawValue: preset) else {
                throw HTTPError(.badRequest, "no preset \(preset): \(TokenPreset.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            rights = known.rights
        } else {
            rights = []
            for name in making.rights ?? [] {
                guard let right = HTTPRight(rawValue: name) else {
                    throw HTTPError(.badRequest, "no right \(name): \(TokenPreset.rightNames)")
                }
                rights.insert(right)
            }
        }
        let made = try Self.refusing { try tokens.add(name: making.name, rights: rights) }
        return Self.json(["id": .string(made.token.id), "name": .string(made.token.name), "secret": .string(made.secret)])
    }

    private func rotate(_ request: HTTPRequest) throws -> HTTPResponse {
        let id = request.parameters["id"] ?? ""
        let secret = try Self.refusing { try tokens.rotate(id) }
        // A session signed in with the old secret ends at its next request
        // (`ServerAuthorizer`); the page is told when that is its own.
        return Self.json(["id": .string(id), "secret": .string(secret),
                          "signed_out": .bool(request.principal?.id == id)])
    }

    private func revoke(_ request: HTTPRequest) throws -> HTTPResponse {
        let id = request.parameters["id"] ?? ""
        let others = tokens.all().filter { $0.id != id && !$0.revoked && $0.granted.contains(.admin) }
        if others.isEmpty, tokens.all().contains(where: { $0.id == id && !$0.revoked && $0.granted.contains(.admin) }) {
            throw HTTPError(.conflict, "this is the last admin token: the console and the next start need one. "
                + "Make another admin token first.")
        }
        try Self.refusing { try tokens.revoke(id) }
        authorizer.sessions.end(principal: id)
        return Self.json(["id": .string(id), "signed_out": .bool(request.principal?.id == id)])
    }

    // MARK: - Shapes

    @MainActor
    static func documents(_ registry: DocumentRegistry) -> JSONValue {
        let absent = Set(registry.absentRoots.map(\.path))
        let open = registry.rows.compactMap(\.host)
        return [
            "documents": .array(registry.rows.map(document)),
            "roots": .array(registry.dumpRoots.map { root in
                ["path": .string(root.path), "present": .bool(!absent.contains(root.path))]
            }),
            "uploads": .string(registry.uploads.path),
            "limits": [
                "documents": .count(registry.limits.documents),
                "open_bytes": .uint(registry.limits.openBytes),
                "upload_bytes": .uint(registry.limits.uploadBytes)
            ],
            "used": [
                "documents": .count(open.count),
                "bytes": .uint(open.reduce(0) { $0 + $1.contentSize })
            ]
        ]
    }

    @MainActor
    static func document(_ row: DocumentRegistry.Row) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(row.id),
            "name": .string(row.name),
            "path": .string(row.path.path),
            "uploaded": .bool(row.uploaded),
            "sha256": .string(row.sha256),
            "version": .count(row.version)
        ]
        switch row.state {
        case .open(let host):
            members["state"] = "open"
            members["size"] = .uint(host.contentSize)
            if let disk = host.diskState() { members["disk"] = .string(disk.rawValue) }
        case .missing(let reason):
            members["state"] = "missing"
            members["reason"] = .string(reason.message)
            if let size = row.stamp?.size { members["size"] = .uint(size) }
        }
        return .object(members)
    }

    static func agent(_ row: ServerActivity.Row) -> JSONValue {
        var members: [String: JSONValue] = [
            "number": .count(row.number),
            "started": .string(date(row.started)),
            "spoke": .bool(row.spoke),
            "calls": .count(row.calls),
            "errors": .count(row.errors),
            "open": .bool(row.isOpen)
        ]
        if let about = row.about { members["client"] = .string(about) }
        if let tool = row.lastTool { members["last_tool"] = .string(tool) }
        if let call = row.lastCall { members["last_call"] = .string(date(call)) }
        if let finished = row.finished { members["finished"] = .string(date(finished)) }
        return .object(members)
    }

    static func client(_ row: RESTActivity.Row) -> JSONValue {
        [
            "token": .string(row.token),
            "name": .string(row.name),
            "requests": .count(row.requests),
            "refused": .count(row.refused),
            "last_seen": .string(date(row.lastSeen)),
            "last": .string("\(row.lastMethod) \(row.lastPath)"),
            "last_status": .count(row.lastStatus)
        ]
    }

    static func date(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func json(_ value: JSONValue, status: HTTPStatus = .ok) -> HTTPResponse {
        HTTPResponse(status, headers: ["content-type": "application/json"], body: value.encoded())
    }

    /// What every console answer carries: no framing, no sniffing, no
    /// referrer, nothing kept, and a page that runs only its own script.
    static func secured(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        response.headers["cache-control"] = "no-store"
        response.headers["x-content-type-options"] = "nosniff"
        response.headers["x-frame-options"] = "DENY"
        response.headers["referrer-policy"] = "no-referrer"
        response.headers["content-security-policy"] = "default-src 'none'; script-src 'self'; style-src 'self'; "
            + "img-src 'self' data:; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        return response
    }

    /// A registry's or a token store's refusal as the operator's 422 — or a
    /// 409 for a name already taken.
    static func refusing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as DocumentRegistry.Failure {
            throw HTTPError(.unprocessable, failure.description)
        } catch let failure as TokenStore.Failure {
            if case .duplicateName = failure { throw HTTPError(.conflict, failure.description) }
            throw HTTPError(.unprocessable, failure.description)
        }
    }

    static func refusing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as DocumentRegistry.Failure {
            throw HTTPError(.unprocessable, failure.description)
        } catch let failure as TokenStore.Failure {
            if case .duplicateName = failure { throw HTTPError(.conflict, failure.description) }
            throw HTTPError(.unprocessable, failure.description)
        }
    }
}

/// The shell's files, read from the target's resources once, at start: a
/// missing one stops the server rather than serving a broken page.
struct ConsoleAssets: Sendable {
    let page: HTTPResponse
    let files: [String: HTTPResponse]

    static let types = [
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "png": "image/png"
    ]

    static func load(bundle: Bundle = .module) throws -> ConsoleAssets {
        func read(_ name: String) throws -> Data {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let url = bundle.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Console"),
                  let data = try? Data(contentsOf: url) else {
                throw HTTPError(.internalError, "the console's \(name) is not in \(bundle.bundlePath)")
            }
            return data
        }
        var files: [String: HTTPResponse] = [:]
        for name in ["console.css", "console.js", "icon.png"] {
            let type = types[String(name.split(separator: ".").last!)]!
            files[name] = HTTPResponse(.ok, headers: ["content-type": type], body: try read(name))
        }
        let page = HTTPResponse(.ok, headers: ["content-type": "text/html; charset=utf-8"], body: try read("index.html"))
        return ConsoleAssets(page: page, files: files)
    }
}
