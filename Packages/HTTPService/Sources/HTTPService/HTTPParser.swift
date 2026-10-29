import Foundation

/// Reads requests out of a connection's bytes as they arrive.
///
/// Pure, so a request split across reads, two requests in one read and every
/// refusal are tested without a socket. A body is read by `Content-Length`
/// only: the server's clients are `URLSession` and the skill, which send a
/// length, and a chunked upload is refused with 411 rather than half-supported.
public struct HTTPParser: Sendable {
    public enum Result: Equatable {
        case needMore
        case request(HTTPRequest)
        case refused(HTTPStatus, String)
        /// What `admit` refused, with the head it was asked about. Its body is
        /// never read: `canContinue` says whether the connection may go on —
        /// only when there was no body to skip.
        case denied(HTTPRequest, HTTPError, canContinue: Bool)
    }

    /// What the server answers about a request once its headers are in.
    public enum Admission: Equatable, Sendable {
        /// Read the body, up to `maxBodyBytes` (nil: the parser's default),
        /// and hand the request on as `principal`'s.
        case admit(maxBodyBytes: Int?, principal: HTTPPrincipal?)
        case refuse(HTTPError)
    }

    public var maxHeaderBytes = 64 * 1024
    public var maxBodyBytes: Int
    /// Asked once the request line and headers are in, with an empty body:
    /// whether to read the body at all, how much of it a route takes, and as
    /// whose (`Design/SERVER_HEADLESS_PLAN.md` §5). A request without a token
    /// is refused here, before the server holds its body. nil admits every
    /// request with the default limit.
    public var admit: (@Sendable (HTTPRequest) -> Admission)?

    private var buffer = Data()
    /// The answer for the request at the front of `buffer`, kept while its
    /// body arrives so `admit` is asked once per request.
    private var admitted: Admission?

    public init(maxBodyBytes: Int, admit: (@Sendable (HTTPRequest) -> Admission)? = nil) {
        self.maxBodyBytes = maxBodyBytes
        self.admit = admit
    }

    public mutating func feed(_ data: Data) {
        buffer.append(data)
    }

    /// The next whole request, if the bytes so far hold one.
    public mutating func next() -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes
                ? .refused(.headersTooLarge, "the request's headers are longer than \(maxHeaderBytes) bytes")
                : .needMore
        }
        guard end.lowerBound - buffer.startIndex <= maxHeaderBytes else {
            return .refused(.headersTooLarge, "the request's headers are longer than \(maxHeaderBytes) bytes")
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .refused(.badRequest, "the request's headers are not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .refused(.badRequest, "not an HTTP/1.x request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .refused(.badRequest, "a header line without a colon")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if let encoding = headers["transfer-encoding"], encoding.lowercased() != "identity" {
            return .refused(.lengthRequired, "send the body with a Content-Length")
        }
        var length = 0
        if let text = headers["content-length"] {
            guard let value = Int(text), value >= 0 else {
                return .refused(.badRequest, "Content-Length is not a number")
            }
            length = value
        }
        let target = String(requestLine[1])
        let (path, query) = Self.split(target)
        guard let path else { return .refused(.badRequest, "the path is not percent-encoded UTF-8") }
        var request = HTTPRequest(method: String(requestLine[0]), path: path, query: query, headers: headers)
        let admission = admitted ?? admit?(request) ?? .admit(maxBodyBytes: nil, principal: nil)
        let bodyStart = end.upperBound
        switch admission {
        case .refuse(let error):
            admitted = nil
            // A refused body is not read: with none to skip the next request
            // can follow, otherwise the connection goes.
            guard length == 0 else { return .denied(request, error, canContinue: false) }
            buffer = Data(buffer[bodyStart...])
            return .denied(request, error, canContinue: true)
        case .admit(let routeLimit, let principal):
            let limit = routeLimit ?? maxBodyBytes
            guard length <= limit else {
                admitted = nil
                return .refused(.payloadTooLarge, "the body is longer than \(limit) bytes")
            }
            guard buffer.endIndex - bodyStart >= length else {
                admitted = admission
                return .needMore
            }
            admitted = nil
            request.body = Data(buffer[bodyStart..<(bodyStart + length)])
            request.principal = principal
            buffer = Data(buffer[(bodyStart + length)...])
            return .request(request)
        }
    }

    static func split(_ target: String) -> (String?, [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var segments: [String] = []
        for segment in parts[0].split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(segment).removingPercentEncoding else { return (nil, [:]) }
            segments.append(decoded)
        }
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(field[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                let value = field.count == 2
                    ? String(field[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                    : ""
                query[name] = value
            }
        }
        return (segments.joined(separator: "/"), query)
    }
}

extension HTTPRequest: Equatable {
    public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
        a.method == b.method && a.path == b.path && a.query == b.query
            && a.headers == b.headers && a.body == b.body && a.parameters == b.parameters
            && a.principal == b.principal
    }
}
