import Foundation
import HTTPService

/// The names the console's cookies go by.
public enum AdminCookie {
    public static let session = "br_admin"
    public static let csrf = "br_csrf"
    public static let header = "x-csrf-token"
}

/// Who is signed in to the console, in memory only: the server keeps no
/// history and writes no session anywhere (`Design/SERVER_HEADLESS_PLAN.md`
/// §2, decision 6). A session ends at sign-out, after `lifetime` without a
/// request, or when the server stops.
public final class AdminSessions: @unchecked Sendable {
    public struct Session: Sendable {
        public let principal: HTTPPrincipal
        /// The hash of the secret the session signed in with: a rotation
        /// changes it, and the session ends with the old secret.
        public let tokenHash: String
        /// The value the CSRF cookie and the `X-CSRF-Token` header must both
        /// carry.
        public let csrf: String
        public var lastSeen: Date
    }

    public var lifetime: TimeInterval = 12 * 3600

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    public init() {}

    /// A new session and its CSRF value.
    func start(_ principal: HTTPPrincipal, tokenHash: String) -> (id: String, csrf: String) {
        let id = Self.makeID()
        let csrf = Self.makeID()
        lock.lock()
        sessions[id] = Session(principal: principal, tokenHash: tokenHash, csrf: csrf, lastSeen: Date())
        lock.unlock()
        return (id, csrf)
    }

    /// The session, touched; nil when it has ended or gone stale.
    public func session(_ id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        guard var session = sessions[id] else { return nil }
        session.lastSeen = Date()
        sessions[id] = session
        return session
    }

    public func end(_ id: String) {
        lock.lock()
        sessions[id] = nil
        lock.unlock()
    }

    /// Ends every session of one token — what revoking it does.
    public func end(principal id: String) {
        lock.lock()
        for (session, value) in sessions where value.principal.id == id {
            sessions[session] = nil
        }
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        return sessions.count
    }

    private func expireLocked() {
        let now = Date()
        for (id, session) in sessions where now.timeIntervalSince(session.lastSeen) > lifetime {
            sessions[id] = nil
        }
    }

    private static func makeID() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The server's door: a bearer token on any path, a console cookie **only**
/// under `/admin`, and a CSRF check on every console request a browser could
/// be tricked into making (`Design/SERVER_HEADLESS_PLAN.md` §5).
///
/// A cookie session is deliberately powerless outside `/admin`: the browser
/// carries it to whatever the address serves, and a signed-in console must not
/// turn into an open store or Ghidra.
public final class ServerAuthorizer: HTTPAuthorizer, @unchecked Sendable {
    public let tokens: TokenStore
    public let sessions: AdminSessions

    public init(tokens: TokenStore, sessions: AdminSessions = AdminSessions()) {
        self.tokens = tokens
        self.sessions = sessions
    }

    /// Signs in to the console with a token's secret: a session for an admin
    /// token, nothing for any other (`Design/SERVER_HEADLESS_PLAN.md` §5).
    /// The sign-in route is the one open route; this is what it calls.
    public func signIn(secret: String) throws -> (id: String, csrf: String) {
        guard let principal = tokens.principal(for: secret) else {
            throw HTTPError(.unauthorized, "that is not a token of this server")
        }
        try principal.require(.admin)
        return sessions.start(principal, tokenHash: TokenStore.hash(secret))
    }

    public func principal(for request: HTTPRequest) throws -> HTTPPrincipal {
        if let secret = HTTPBearer.token(request.headers["authorization"]) {
            guard let principal = tokens.principal(for: secret) else {
                throw HTTPError(.unauthorized, "the bearer token is not one of this server's")
            }
            return principal
        }
        guard Self.isConsole(request.path) else {
            throw HTTPError(.unauthorized, "a bearer token is required")
        }
        guard let id = Self.cookie(AdminCookie.session, in: request.headers),
              let session = sessions.session(id) else {
            throw HTTPError(.unauthorized, "sign in at /admin/login")
        }
        // A revocation or a rotation reaches the sessions the old secret
        // signed in, not only the next request that carries it: a secret is
        // rotated because it got out.
        guard tokens.isCurrent(id: session.principal.id, hash: session.tokenHash) else {
            sessions.end(id)
            throw HTTPError(.unauthorized, "the token this session signed in with was revoked or rotated")
        }
        if !Self.isSafe(request.method) {
            let given = request.headers[AdminCookie.header]
            let fromCookie = Self.cookie(AdminCookie.csrf, in: request.headers)
            guard let given, let fromCookie,
                  HTTPBearer.equal(given, session.csrf), HTTPBearer.equal(fromCookie, session.csrf) else {
                throw HTTPError(.forbidden, "the console's form needs its CSRF token")
            }
        }
        return session.principal
    }

    public static func isConsole(_ path: String) -> Bool {
        path == "/admin" || path.hasPrefix("/admin/")
    }

    /// The methods that change nothing: GET, HEAD and a CORS preflight's
    /// OPTIONS, none of which a console route answers with a change.
    public static func isSafe(_ method: String) -> Bool {
        method == "GET" || method == "HEAD" || method == "OPTIONS"
    }

    public static func cookie(_ name: String, in headers: [String: String]) -> String? {
        guard let header = headers["cookie"] else { return nil }
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let equals = piece.firstIndex(of: "=") else { continue }
            if piece[..<equals] == name { return String(piece[piece.index(after: equals)...]) }
        }
        return nil
    }
}
