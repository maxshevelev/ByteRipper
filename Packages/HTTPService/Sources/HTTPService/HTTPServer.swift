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
        /// One line per answered request: method, path, status, time.
        public var log: (@Sendable (String) -> Void)?

        public init(host: String = "127.0.0.1", port: UInt16 = 8765, token: String? = nil,
                    maxBodyBytes: Int = 512 * 1024 * 1024, log: (@Sendable (String) -> Void)? = nil) {
            self.host = host
            self.port = port
            self.token = token
            self.maxBodyBytes = maxBodyBytes
            self.log = log
        }

        public var isLoopback: Bool {
            host == "127.0.0.1" || host == "::1" || host == "localhost"
        }
    }

    /// The address a host name stands for, as a literal the listener can bind
    /// to: Network.framework does not resolve a name given as the local
    /// endpoint — it listens on every interface, on a port of its choosing —
    /// so the name is resolved here. IPv4 first, the address a tailnet or a
    /// LAN name is usually meant by.
    public static func resolve(_ host: String) throws -> String {
        if host == "localhost" { return "127.0.0.1" }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        guard status == 0, let first = list else {
            throw StartError.cannotListen("\(host) does not resolve to an address of this Mac")
        }
        defer { freeaddrinfo(first) }
        var found: [String] = []
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                found.append(String(cString: buffer))
            }
            entry = current.pointee.ai_next
        }
        guard let address = found.first(where: { !$0.contains(":") }) ?? found.first else {
            throw StartError.cannotListen("\(host) does not resolve to an address")
        }
        return address
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
    /// The address the listener is bound to, once `start` resolved it.
    public private(set) var boundAddress: String?
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
        let address = try Self.resolve(configuration.host)
        if !Self.isLoopbackAddress(address), (configuration.token ?? "").isEmpty {
            throw StartError.tokenRequired(configuration.host)
        }
        boundAddress = address
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
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
                    let actual = listener.port?.rawValue ?? 0
                    // A listener that did not take the port asked for is not
                    // the server the person started: a client cannot find it.
                    if port.rawValue != 0, actual != port.rawValue {
                        listener.cancel()
                        continuation.resume(throwing: StartError.cannotListen(
                            "asked for port \(port.rawValue), the system gave \(actual)"))
                    } else {
                        continuation.resume(returning: actual)
                    }
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
            configuration.log?("\(request.method) \(request.path) 401")
            send(.error(HTTPError(.unauthorized, "a bearer token is required")),
                 on: connection, keepAlive: keepAlive)
            if keepAlive { receive(on: connection, parser: parser) }
            return
        }
        let router = self.router
        let log = configuration.log
        Task {
            let started = Date()
            let response = await router.handle(request)
            let milliseconds = Int((Date().timeIntervalSince(started) * 1000).rounded())
            log?("\(request.method) \(request.path) \(response.status.code) \(milliseconds) ms")
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

    static func isLoopbackAddress(_ address: String) -> Bool {
        address == "::1" || address.hasPrefix("127.")
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
