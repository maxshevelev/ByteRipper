import CryptoKit
import Foundation
import HTTPService

/// The names the console's cookies go by.
public enum AdminCookie {
    public static let session = "br_admin"
    public static let csrf = "br_csrf"
    public static let header = "x-csrf-token"
}

/// Who is signed in to the console (`Design/SERVER_HEADLESS_PLAN.md` §5): the
/// browser keeps its session cookie for `lifetime`, and the sessions are kept
/// in a file of their own beside `tokens.json`, so stopping the server does
/// not sign the operator out — a restart, or a rebuild, is not a reason to
/// paste an admin token again. What the file holds is the SHA-256 of each
/// session id, never the id itself: a copy of the file cannot sign in. A
/// session ends at sign-out, after `lifetime` without a request, or when the
/// token it signed in with is rotated or revoked.
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

    /// How long a session may go without a request before it ends. A month:
    /// the console is the operator's own, and the alternative is pasting an
    /// admin token every time the server is rebuilt.
    public var lifetime: TimeInterval = 30 * 24 * 3600

    /// How often a touched session's last-seen date reaches the file. The
    /// console asks every second, and a write per request would be a write
    /// per poll.
    public static let persistInterval: TimeInterval = 5 * 60

    private let lock = NSLock()
    /// Keyed by the SHA-256 of the session id, which is also what the file
    /// holds.
    private var sessions: [String: Session] = [:]
    /// nil keeps the sessions in memory: what the package's tests run on.
    private let file: URL?
    private var persisted = Date.distantPast

    public init(file: URL? = nil) {
        self.file = file
        load()
    }

    /// A new session and its CSRF value.
    func start(_ principal: HTTPPrincipal, tokenHash: String) -> (id: String, csrf: String) {
        let id = Self.makeID()
        let csrf = Self.makeID()
        lock.lock()
        sessions[Self.hash(id)] = Session(principal: principal, tokenHash: tokenHash,
                                          csrf: csrf, lastSeen: Date())
        saveLocked()
        lock.unlock()
        return (id, csrf)
    }

    /// The session, touched; nil when it has ended or gone stale.
    public func session(_ id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        expireLocked()
        let key = Self.hash(id)
        guard var session = sessions[key] else { return nil }
        session.lastSeen = Date()
        sessions[key] = session
        touchLocked()
        return session
    }

    public func end(_ id: String) {
        lock.lock()
        sessions[Self.hash(id)] = nil
        saveLocked()
        lock.unlock()
    }

    /// Ends every session of one token — what revoking it does.
    public func end(principal id: String) {
        lock.lock()
        var ended = false
        for (session, value) in sessions where value.principal.id == id {
            sessions[session] = nil
            ended = true
        }
        if ended { saveLocked() }
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
        let before = sessions.count
        for (key, session) in sessions where now.timeIntervalSince(session.lastSeen) > lifetime {
            sessions[key] = nil
        }
        if sessions.count != before { saveLocked() }
    }

    /// A used session's new date goes to the file now and then, not on every
    /// request: the file is a convenience, not a journal.
    private func touchLocked() {
        guard file != nil, Date().timeIntervalSince(persisted) > Self.persistInterval else { return }
        saveLocked()
    }

    // MARK: - The file

    private struct Stored: Codable {
        var version = 1
        var sessions: [Entry]
    }

    /// One session as the file keeps it: no id, only its hash.
    private struct Entry: Codable {
        /// The SHA-256 of the session id, hex.
        var id: String
        var token: String
        var name: String
        var rights: [String]
        var tokenHash: String
        var csrf: String
        var seen: Date
    }

    private func load() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else { return }
        var loaded: [String: Session] = [:]
        for entry in stored.sessions {
            let rights = entry.rights.compactMap(HTTPRight.init(rawValue:))
            guard rights.count == entry.rights.count else { continue }
            loaded[entry.id] = Session(
                principal: HTTPPrincipal(id: entry.token, name: entry.name, rights: Set(rights)),
                tokenHash: entry.tokenHash, csrf: entry.csrf, lastSeen: entry.seen)
        }
        lock.lock()
        sessions = loaded
        expireLocked()
        lock.unlock()
    }

    private func saveLocked() {
        guard let file else { return }
        let stored = Stored(sessions: sessions.map { key, session in
            Entry(id: key, token: session.principal.id, name: session.principal.name,
                  rights: session.principal.rights.map(\.rawValue).sorted(),
                  tokenHash: session.tokenHash, csrf: session.csrf, seen: session.lastSeen)
        }.sorted { $0.seen < $1.seen })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        persisted = Date()
    }

    private static func hash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
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
