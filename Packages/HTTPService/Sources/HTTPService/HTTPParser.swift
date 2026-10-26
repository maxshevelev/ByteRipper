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
    }

    public var maxHeaderBytes = 64 * 1024
    public var maxBodyBytes: Int

    private var buffer = Data()

    public init(maxBodyBytes: Int) {
        self.maxBodyBytes = maxBodyBytes
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
        guard length <= maxBodyBytes else {
            return .refused(.payloadTooLarge, "the body is longer than \(maxBodyBytes) bytes")
        }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .needMore }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])

        let target = String(requestLine[1])
        let (path, query) = Self.split(target)
        guard let path else { return .refused(.badRequest, "the path is not percent-encoded UTF-8") }
        return .request(HTTPRequest(method: String(requestLine[0]), path: path, query: query,
                                    headers: headers, body: body))
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
    }
}
