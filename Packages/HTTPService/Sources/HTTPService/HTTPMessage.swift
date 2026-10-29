import Foundation

/// One request as the server read it: the body is whole, read by its length.
public struct HTTPRequest: Sendable {
    public var method: String
    /// The path without its query, percent-decoded per segment.
    public var path: String
    public var query: [String: String]
    /// Header names in lower case; a repeated header keeps its last value.
    public var headers: [String: String]
    public var body: Data
    /// What the route matched for each `:name` in its pattern.
    public var parameters: [String: String] = [:]
    /// Whose token the request is served on, set by the server once its
    /// authorizer has answered; nil inside a test that calls a route directly.
    public var principal: HTTPPrincipal?

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], body: Data = Data(),
                principal: HTTPPrincipal? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.principal = principal
    }

    public var segments: [String] { path.split(separator: "/").map(String.init) }

    /// The body as JSON, or a 400 to answer with.
    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw HTTPError(.badRequest, "the body is not the JSON expected: \(error)")
        }
    }
}

public struct HTTPStatus: Equatable, Sendable {
    public let code: Int
    public let reason: String

    public init(_ code: Int, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public static let ok = HTTPStatus(200, "OK")
    public static let noContent = HTTPStatus(204, "No Content")
    public static let badRequest = HTTPStatus(400, "Bad Request")
    public static let unauthorized = HTTPStatus(401, "Unauthorized")
    public static let forbidden = HTTPStatus(403, "Forbidden")
    public static let notFound = HTTPStatus(404, "Not Found")
    public static let methodNotAllowed = HTTPStatus(405, "Method Not Allowed")
    public static let conflict = HTTPStatus(409, "Conflict")
    public static let lengthRequired = HTTPStatus(411, "Length Required")
    public static let payloadTooLarge = HTTPStatus(413, "Payload Too Large")
    public static let headersTooLarge = HTTPStatus(431, "Request Header Fields Too Large")
    public static let unprocessable = HTTPStatus(422, "Unprocessable Content")
    public static let internalError = HTTPStatus(500, "Internal Server Error")
    public static let unavailable = HTTPStatus(503, "Service Unavailable")
}

public struct HTTPResponse: Sendable {
    public var status: HTTPStatus
    public var headers: [String: String]
    public var body: Data

    public init(_ status: HTTPStatus = .ok, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Sorted keys, so an answer is the same bytes for the same value.
    public static func json<T: Encodable>(_ value: T, status: HTTPStatus = .ok) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return HTTPResponse(status, headers: ["content-type": "application/json"],
                                body: try encoder.encode(value))
        } catch {
            return .error(HTTPError(.internalError, "cannot encode the answer: \(error)"))
        }
    }

    public static func bytes(_ data: Data, type: String = "application/octet-stream") -> HTTPResponse {
        HTTPResponse(.ok, headers: ["content-type": type], body: data)
    }

    /// `{"error": "…"}`, the shape `byteripper-cas` refuses with — and
    /// `"right"` beside it when the refusal names the right a token lacks, so
    /// a client says which one instead of reading the sentence
    /// (`Design/SERVER_HEADLESS_PLAN.md` decision 4).
    public static func error(_ error: HTTPError) -> HTTPResponse {
        struct Failure: Encodable {
            let error: String
            let right: String?
        }
        return json(Failure(error: error.message, right: error.right?.rawValue), status: error.status)
    }

    /// The bytes on the wire, with `Content-Length` and the connection's fate.
    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status.code) \(status.reason)\r\n"
        var fields = headers
        fields["content-length"] = String(body.count)
        fields["connection"] = keepAlive ? "keep-alive" : "close"
        for name in fields.keys.sorted() {
            head += "\(name): \(fields[name]!)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// A refusal a route throws; the server answers it as `HTTPResponse.error`.
public struct HTTPError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: HTTPStatus
    public let message: String
    /// The right a 403 is about, when a route's access named it: the answer
    /// carries it as a value, so a client names the right to add rather than
    /// reading it out of a sentence.
    public let right: HTTPRight?

    public init(_ status: HTTPStatus, _ message: String, right: HTTPRight? = nil) {
        self.status = status
        self.message = message
        self.right = right
    }

    public var description: String { "\(status.code) \(message)" }
}
