import Foundation
import Network

/// The listener: one address, one authorizer, one router.
///
/// Requests on a connection are answered in order, one at a time; a slow
/// handler — a long poll — holds its own connection and nothing else. There is
/// no anonymous mode: every request is served as the principal its authorizer
/// names, on loopback as much as anywhere else
/// (`Design/SERVER_HEADLESS_PLAN.md` §2, decision 3).
public final class HTTPServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        /// 0 lets the system choose; `start` returns the port it chose.
        public var port: UInt16
        public var authorizer: any HTTPAuthorizer
        public var maxBodyBytes: Int
        /// One line per answered request: method, path, status, time.
        public var log: (@Sendable (String) -> Void)?
        /// Every answered request as a value, refusals included: where the
        /// console's REST activity rows come from.
        public var onRequest: (@Sendable (HTTPActivity) -> Void)?
        /// Asked about every request on its headers, before the route and the
        /// authorizer — an open route included: a refusal here is the answer.
        /// Where a check that no route may skip lives, such as the console's
        /// `Host` and `Origin` (`Design/SERVER_HEADLESS_PLAN.md` decision 19).
        public var screen: (@Sendable (HTTPRequest) -> HTTPError?)?

        public init(host: String = "127.0.0.1", port: UInt16 = 8765,
                    authorizer: any HTTPAuthorizer,
                    maxBodyBytes: Int = 512 * 1024 * 1024,
                    log: (@Sendable (String) -> Void)? = nil,
                    onRequest: (@Sendable (HTTPActivity) -> Void)? = nil,
                    screen: (@Sendable (HTTPRequest) -> HTTPError?)? = nil) {
            self.host = host
            self.port = port
            self.authorizer = authorizer
            self.maxBodyBytes = maxBodyBytes
            self.log = log
            self.onRequest = onRequest
            self.screen = screen
        }

        /// One bearer token that opens every route: the package's own tests and
        /// a server of one person. A deployment with `tokens.json` uses
        /// `authorizer:` instead.
        public init(host: String = "127.0.0.1", port: UInt16 = 8765, token: String,
                    maxBodyBytes: Int = 512 * 1024 * 1024,
                    log: (@Sendable (String) -> Void)? = nil,
                    onRequest: (@Sendable (HTTPActivity) -> Void)? = nil) {
            self.init(host: host, port: port, authorizer: StaticAuthorizer(token: token),
                      maxBodyBytes: maxBodyBytes, log: log, onRequest: onRequest)
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
        case cannotListen(String)

        public var description: String {
            switch self {
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
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw StartError.cannotListen("port \(configuration.port)")
        }
        let address = try Self.resolve(configuration.host)
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
        let router = self.router
        let authorizer = configuration.authorizer
        let screen = configuration.screen
        receive(on: connection, parser: HTTPParser(
            maxBodyBytes: configuration.maxBodyBytes,
            admit: { Self.admit($0, router: router, authorizer: authorizer, screen: screen) }))
    }

    /// Who a request is, decided from its headers before its body is read: an
    /// open route asks for nobody, every other path — a route or not, so a
    /// stranger learns nothing of what is served — for a token the authorizer
    /// accepts (`Design/SERVER_HEADLESS_PLAN.md` §5).
    static func admit(_ head: HTTPRequest, router: HTTPRouter, authorizer: any HTTPAuthorizer,
                      screen: (@Sendable (HTTPRequest) -> HTTPError?)? = nil) -> HTTPParser.Admission {
        if let refusal = screen?(head) { return .refuse(refusal) }
        let route = router.route(method: head.method, path: head.path)
        if route?.access == .open {
            return .admit(maxBodyBytes: route?.maxBodyBytes, principal: nil)
        }
        do {
            return .admit(maxBodyBytes: route?.maxBodyBytes, principal: try authorizer.principal(for: head))
        } catch let error as HTTPError {
            return .refuse(error)
        } catch {
            return .refuse(HTTPError(.internalError, "\(error)"))
        }
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
        case .denied(let request, let error, let canContinue):
            report(request, status: error.status, duration: 0)
            let keepAlive = canContinue && request.headers["connection"]?.lowercased() != "close"
            send(.error(error), on: connection, keepAlive: keepAlive)
            if keepAlive { receive(on: connection, parser: parser) }
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
        let router = self.router
        Task {
            let started = Date()
            let response = await router.handle(request)
            self.report(request, status: response.status, duration: Date().timeIntervalSince(started))
            self.queue.async {
                self.send(response, on: connection, keepAlive: keepAlive)
                if keepAlive { self.receive(on: connection, parser: parser) }
            }
        }
    }

    /// One answered request, to the log and to the activity rows.
    private func report(_ request: HTTPRequest, status: HTTPStatus, duration: TimeInterval) {
        let milliseconds = Int((duration * 1000).rounded())
        configuration.log?("\(request.method) \(request.path) \(status.code) \(milliseconds) ms")
        configuration.onRequest?(HTTPActivity(method: request.method, path: request.path, status: status,
                                              duration: duration, principal: request.principal))
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool) {
        connection.send(content: response.serialized(keepAlive: keepAlive),
                        completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
    }

}
