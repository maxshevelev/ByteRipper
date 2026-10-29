import Foundation

/// A right a token may carry. The names are the server's vocabulary
/// (`Design/SERVER_HEADLESS_PLAN.md` §2, decision 4); they live beside the
/// principal, because that is what a route checks them on.
public enum HTTPRight: String, CaseIterable, Codable, Sendable, Hashable {
    case casRead = "cas.read"
    case casWrite = "cas.write"
    case ghidraUse = "ghidra.use"
    case admin = "admin"
}

/// Who is behind a request: a token of the server's `tokens.json`, or the
/// console session that token signed in.
public struct HTTPPrincipal: Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var rights: Set<HTTPRight>

    public init(id: String, name: String, rights: Set<HTTPRight>) {
        self.id = id
        self.name = name
        self.rights = rights
    }

    /// `admin` carries every other right with it: it is the operator's, and
    /// `token add --name admin --rights admin` has to be enough
    /// (`Design/SERVER_HEADLESS_PLAN.md` decision 17).
    public func allows(_ right: HTTPRight) -> Bool {
        rights.contains(right) || rights.contains(.admin)
    }

    /// Refuses with a 403 that names the right, so the app can say which one
    /// is missing instead of reporting a network failure (decision 4).
    public func require(_ right: HTTPRight) throws {
        try require([right])
    }

    /// Refuses with a 403 that names every right the token lacks at once — a
    /// publish needs two, and an operator adding them one refusal at a time
    /// would go round twice.
    public func require(_ rights: Set<HTTPRight>) throws {
        let missing = rights.filter { !allows($0) }.sorted { $0.rawValue < $1.rawValue }
        guard missing.isEmpty else {
            let names = missing.map(\.rawValue)
            let message = missing.count == 1
                ? "this token has no \(names[0]) right"
                : "this token has none of the rights \(names.joined(separator: ", "))"
            throw HTTPError(.forbidden, message, rights: missing)
        }
    }

    /// Every right: what a test server runs on.
    public static func all(id: String = "test", name: String = "test") -> HTTPPrincipal {
        HTTPPrincipal(id: id, name: name, rights: Set(HTTPRight.allCases))
    }
}

/// Who a route lets in (`Design/SERVER_HEADLESS_PLAN.md` §5).
public enum HTTPAccess: Equatable, Sendable {
    /// No token: the console's sign-in page and nothing else. The request
    /// reaches the route with no principal.
    case open
    /// Any token the authorizer accepts.
    case token
    /// A token carrying every one of these rights; a missing one is a 403
    /// that names it.
    case rights(Set<HTTPRight>)
}

/// Turns a request into the principal it may be served as, or the refusal to
/// answer it with. The server has no anonymous mode: `HTTPServer` will not
/// start without one, on any address (`Design/SERVER_HEADLESS_PLAN.md`
/// decision 3).
///
/// It is asked once the request line and headers are in, before the body is
/// read — `request.body` is empty — so a request without a token is refused
/// before the server holds a byte of what it sends. Synchronous for the same
/// reason: the parser asks it in the middle of reading.
public protocol HTTPAuthorizer: Sendable {
    func principal(for request: HTTPRequest) throws -> HTTPPrincipal
}

/// One bearer token that opens everything — the package's own tests, and a
/// server whose single token is held in the configuration.
public struct StaticAuthorizer: HTTPAuthorizer {
    public let token: String
    public let granted: HTTPPrincipal

    public init(token: String, principal: HTTPPrincipal = .all()) {
        self.token = token
        self.granted = principal
    }

    public func principal(for request: HTTPRequest) throws -> HTTPPrincipal {
        guard HTTPBearer.matches(request.headers["authorization"], token: token) else {
            throw HTTPError(.unauthorized, "a bearer token is required")
        }
        return granted
    }
}

/// The `Authorization: Bearer` header: read, and compared in a time that says
/// nothing about how much of a guess was right.
public enum HTTPBearer {
    /// The secret a header carries, or nil when it is not a bearer header.
    /// The scheme's name is matched in any case (RFC 7235 §2.1).
    public static func token(_ header: String?) -> String? {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
        let secret = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return secret.isEmpty ? nil : secret
    }

    public static func matches(_ header: String?, token: String) -> Bool {
        guard let given = Self.token(header) else { return false }
        return equal(given, token)
    }

    /// Every byte is compared whatever the first difference made.
    public static func equal(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8)
        let b = Array(expected.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }
}

/// One request as the server's activity rows see it: what was asked, what is
/// answered so far, how long it takes and whose token asked. The server
/// reports a request twice — when it starts and when it is answered — under
/// one `id`, so a console can show a call while the tool is still working on
/// it. The console's REST activity and nothing else is built from these —
/// the server keeps no history (`Design/SERVER_HEADLESS_PLAN.md` §2,
/// decisions 6 and §8).
public struct HTTPActivity: Sendable {
    public enum Phase: Sendable, Equatable {
        /// The route is still working: `status` and `duration` say nothing.
        case started
        case finished
    }

    /// The call the two reports share.
    public let id: UUID
    public let method: String
    public let path: String
    public let phase: Phase
    public let started: Date
    /// nil while the request is still running.
    public let status: HTTPStatus?
    /// Zero while the request is still running.
    public let duration: TimeInterval
    /// nil when the request was refused before a principal was known.
    public let principal: HTTPPrincipal?
    /// The client's address as the listener sees it, when it has one.
    public let peer: String?

    public init(id: UUID = UUID(), method: String, path: String, phase: Phase = .finished,
                started: Date = Date(), status: HTTPStatus? = nil, duration: TimeInterval = 0,
                principal: HTTPPrincipal?, peer: String? = nil) {
        self.id = id
        self.method = method
        self.path = path
        self.phase = phase
        self.started = started
        self.status = status
        self.duration = duration
        self.principal = principal
        self.peer = peer
    }
}
