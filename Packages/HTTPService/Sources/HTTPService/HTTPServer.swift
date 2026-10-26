import Foundation
import Network

/// The listener: one address, one optional bearer token, one router.
///
/// Requests on a connection are answered in order, one at a time; a slow
/// handler — a long poll — holds its own connection and nothing else. A
/// non-loopback address without a token is refused at `start`, because the
/// server's only guard on a network is the token (`Design/SERVER_PLAN.md` §1).
public final class HTTPServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        /// 0 lets the system choose; `start` returns the port it chose.
        public var port: UInt16
        public var token: String?
        public var maxBodyBytes: Int

        public init(host: String = "127.0.0.1", port: UInt16 = 8765, token: String? = nil,
                    maxBodyBytes: Int = 512 * 1024 * 1024) {
            self.host = host
            self.port = port
            self.token = token
            self.maxBodyBytes = maxBodyBytes
        }

        public var isLoopback: Bool {
            host == "127.0.0.1" || host == "::1" || host == "localhost"
        }
    }

    public enum StartError: Error, Equatable, CustomStringConvertible {
        case tokenRequired(String)
        case cannotListen(String)

        public var description: String {
            switch self {
            case .tokenRequired(let host):
                return "listening on \(host) needs a token: only loopback may go without one"
            case .cannotListen(let reason):
                return "cannot listen: \(reason)"
            }
        }
    }

    public let configuration: Configuration
    private let router: HTTPRouter
    private let queue = DispatchQueue(label: "HTTPServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(configuration: Configuration, router: HTTPRouter) {
        self.configuration = configuration
        self.router = router
    }

    /// Listens, and returns the port it listens on.
    @discardableResult
    public func start() async throws -> UInt16 {
        if !configuration.isLoopback, (configuration.token ?? "").isEmpty {
            throw StartError.tokenRequired(configuration.host)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw StartError.cannotListen("port \(configuration.port)")
        }
        let host = configuration.host == "localhost" ? "127.0.0.1" : configuration.host
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError.cannotListen("\(error)")
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The handler runs on `queue`, which is serial: the flag needs no lock.
            final class Once: @unchecked Sendable { var resumed = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.resumed else { return }
                switch state {
                case .ready:
                    once.resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.resumed = true
                    continuation.resume(throwing: StartError.cannotListen("\(error)"))
                case .cancelled:
                    once.resumed = true
                    continuation.resume(throwing: StartError.cannotListen("cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, parser: HTTPParser(maxBodyBytes: configuration.maxBodyBytes))
    }

    private func receive(on connection: NWConnection, parser: HTTPParser) {
        var parser = parser
        switch parser.next() {
        case .request(let request):
            answer(request, on: connection, parser: parser)
            return
        case .refused(let status, let message):
            send(.error(HTTPError(status, message)), on: connection, keepAlive: false)
            return
        case .needMore:
            break
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { parser.feed(data) }
            if error != nil || (isComplete && (data ?? Data()).isEmpty) {
                connection.cancel()
                return
            }
            self.receive(on: connection, parser: parser)
        }
    }

    private func answer(_ request: HTTPRequest, on connection: NWConnection, parser: HTTPParser) {
        let keepAlive = request.headers["connection"]?.lowercased() != "close"
        if let token = configuration.token, !token.isEmpty,
           !Self.authorized(request.headers["authorization"], token: token) {
            send(.error(HTTPError(.unauthorized, "a bearer token is required")),
                 on: connection, keepAlive: keepAlive)
            if keepAlive { receive(on: connection, parser: parser) }
            return
        }
        let router = self.router
        Task {
            let response = await router.handle(request)
            self.queue.async {
                self.send(response, on: connection, keepAlive: keepAlive)
                if keepAlive { self.receive(on: connection, parser: parser) }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool) {
        connection.send(content: response.serialized(keepAlive: keepAlive),
                        completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
    }

    /// Compares every byte whatever the first difference, so the time an
    /// answer takes says nothing about how much of a guess was right.
    static func authorized(_ header: String?, token: String) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(token.utf8)
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for index in 0..<max(given.count, expected.count) {
            let a = index < given.count ? given[index] : 0
            let b = index < expected.count ? expected[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}
