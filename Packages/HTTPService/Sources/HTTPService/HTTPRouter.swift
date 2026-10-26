import Foundation

/// Routes by method and path. A pattern's `:name` segment matches one segment
/// and hands it to the handler as `request.parameters[name]`; a trailing
/// `*name` takes the rest of the path.
///
/// A path that some route matches with another method is answered 405, not
/// 404, so a client calling `PUT` where only `GET` exists hears which mistake
/// it made.
public struct HTTPRouter: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    struct Route: Sendable {
        let method: String
        let pattern: [String]
        let handler: Handler
    }

    private var routes: [Route] = []

    public init() {}

    public mutating func add(_ method: String, _ pattern: String, _ handler: @escaping Handler) {
        routes.append(Route(method: method.uppercased(),
                            pattern: pattern.split(separator: "/").map(String.init),
                            handler: handler))
    }

    /// Every route of `other`, under its own patterns.
    public mutating func merge(_ other: HTTPRouter) {
        routes += other.routes
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let segments = request.segments
        var pathMatched = false
        for route in routes {
            guard let parameters = Self.match(route.pattern, segments) else { continue }
            pathMatched = true
            // HEAD is answered by the GET route, without its body.
            guard route.method == request.method
                    || (request.method == "HEAD" && route.method == "GET") else { continue }
            var matched = request
            matched.parameters = parameters
            do {
                var response = try await route.handler(matched)
                if request.method == "HEAD" {
                    response.headers["content-length"] = String(response.body.count)
                    response.body = Data()
                }
                return response
            } catch let error as HTTPError {
                return .error(error)
            } catch {
                return .error(HTTPError(.internalError, "\(error)"))
            }
        }
        return pathMatched
            ? .error(HTTPError(.methodNotAllowed, "\(request.method) is not served at \(request.path)"))
            : .error(HTTPError(.notFound, "nothing is served at \(request.path)"))
    }

    static func match(_ pattern: [String], _ segments: [String]) -> [String: String]? {
        var parameters: [String: String] = [:]
        for (index, part) in pattern.enumerated() {
            if part.hasPrefix("*") {
                parameters[String(part.dropFirst())] = segments.dropFirst(index).joined(separator: "/")
                return parameters
            }
            guard index < segments.count else { return nil }
            if part.hasPrefix(":") {
                parameters[String(part.dropFirst())] = segments[index]
            } else if part != segments[index] {
                return nil
            }
        }
        return pattern.count == segments.count ? parameters : nil
    }
}
