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
        guard allows(right) else {
            throw HTTPError(.forbidden, "this token has no \(right.rawValue) right")
        }
    }

    /// Every right: what a test server runs on.
    public static func all(id: String = "test", name: String = "test") -> HTTPPrincipal {
        HTTPPrincipal(id: id, name: name, rights: Set(HTTPRight.allCases))
    }
}

/// Turns a request into the principal it may be served as, or the refusal to
/// answer it with. The server has no anonymous mode: `HTTPServer` will not
/// start without one, on any address (`Design/SERVER_HEADLESS_PLAN.md`
/// decision 3).
public protocol HTTPAuthorizer: Sendable {
    func principal(for request: HTTPRequest) async throws -> HTTPPrincipal
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

    public func principal(for request: HTTPRequest) async throws -> HTTPPrincipal {
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
    public static func token(_ header: String?) -> String? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        return String(header.dropFirst("Bearer ".count))
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

/// One answered request as the server's activity rows see it: what was asked,
/// what was answered, how long it took and whose token asked. The console's
/// REST activity and nothing else is built from these — the server keeps no
/// history (`Design/SERVER_HEADLESS_PLAN.md` §2, decisions 6 and §8).
public struct HTTPActivity: Sendable {
    public let method: String
    public let path: String
    public let status: HTTPStatus
    public let duration: TimeInterval
    /// nil when the request was refused before a principal was known.
    public let principal: HTTPPrincipal?

    public init(method: String, path: String, status: HTTPStatus,
                duration: TimeInterval, principal: HTTPPrincipal?) {
        self.method = method
        self.path = path
        self.status = status
        self.duration = duration
        self.principal = principal
    }
}
