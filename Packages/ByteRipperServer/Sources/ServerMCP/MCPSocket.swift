import AgentKit
import Foundation

/// The local MCP over a Unix socket (`Design/SERVER_HEADLESS_PLAN.md` §7,
/// decision 13): a file in the server's own folder, the directory 0700 and
/// the socket 0600. The operator's agent reaches it through
/// `byteripper-server relay`; the file system is the authentication, exactly
/// as on the app's socket — no port, no token, nothing from the network.
@MainActor
public final class MCPSocket {
    public let path: String
    public let server: AgentServer
    public let activity = ServerActivity()
    private var listener: UnixSocketListener?
    private var connections: [ObjectIdentifier: UnixSocketConnection] = [:]
    private var nextNumber = 1

    public init(path: String, server: AgentServer) {
        self.path = path
        self.server = server
    }

    public var isListening: Bool { listener != nil }

    public func start() throws {
        guard listener == nil else { return }
        let listener = UnixSocketListener(path: path)
        try listener.start { [weak self] socket in
            Task { @MainActor in self?.adopt(socket) }
        }
        self.listener = listener
    }

    /// Stops listening and drops every connection: the clients' relays end
    /// and start again when they next need the server.
    public func stop() {
        listener?.stop()
        listener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    private func adopt(_ socket: UnixSocketConnection) {
        guard listener != nil else {
            socket.close()
            return
        }
        let key = ObjectIdentifier(socket)
        connections[key] = socket
        let number = nextNumber
        nextNumber += 1
        let about = socket.peerPID.map(Self.about)
        activity.opened(number: number, about: about)
        let activity = self.activity
        let connection = AgentConnection(
            server: server,
            connection: AgentConnectionTag(number: number, about: about),
            send: { socket.write($0) },
            observer: { record in
                Task { @MainActor in activity.finished(record, connection: number) }
            },
            onFirstMessage: {
                Task { @MainActor in activity.spoke(number) }
            },
            onCallStarted: { record in
                Task { @MainActor in activity.started(record, connection: number) }
            })
        // One consumer, in order: the chunks of a stream must reach the
        // framer in the order they were read.
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        Task {
            for await chunk in chunks { await connection.receive(chunk) }
            await connection.close()
        }
        socket.startReading(onData: { feed.yield($0) }, onClose: { [weak self] in
            feed.finish()
            Task { @MainActor in
                self?.connections[key] = nil
                self?.activity.closed(number)
            }
        })
    }

    /// What is behind a connection: the relay a client started, and its
    /// parent, as the app names them.
    static func about(_ pid: pid_t) -> String {
        let peer = AgentPeer.of(relayPID: pid)
        guard let client = peer.clientPID else { return "PID \(pid)" }
        return "\(peer.clientName ?? "?"), PID \(client)"
    }
}
