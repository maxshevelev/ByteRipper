import AgentKit
import Foundation

/// `byteripper-server relay`: what an agent's client launches to reach the
/// server's local MCP (`Design/SERVER_HEADLESS_PLAN.md` §7, decision 13).
///
/// The client speaks MCP over this process's stdin and stdout; the server
/// speaks it on `<Server>/mcp.sock`. The relay copies the messages between the
/// two and outlives the server: when the socket goes it keeps stdio open,
/// answers what it cannot deliver, and connects again, so a restart costs a
/// session its running calls and not its tools. It ends when the client closes
/// stdin. It imports `AgentKit` and no role of the server, which is what keeps
/// the mode from starting a listener, a store or a Ghidra host.
public enum ServerRelay {
    /// What the client is told when there has been no socket to talk to: the
    /// server is not running, or listens elsewhere.
    public static let unavailable = "No byteripper-server answers on the MCP socket: start it, or pass "
        + "--mcp-socket the path it listens on."

    /// What the client is told once a connection has gone. A call running when
    /// it went may have finished, so the words do not say to simply repeat it.
    public static let restarting = "The connection to byteripper-server dropped, and the relay is connecting again. "
        + "A call that was running may or may not have finished: read before repeating a write."

    /// Runs until the client closes its stdin or stops reading. Answers 1 when
    /// no server was ever reached, otherwise 0.
    public static func run(path: String, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
                           firstDelay: TimeInterval = 0.25, longestDelay: TimeInterval = 5) -> Int32 {
        let relay = Relay(output: output)
        let upstream = Thread { relay.readClient(input) }
        upstream.name = "byteripper-server relay"
        upstream.start()

        var delay = firstDelay
        var told = false
        var reached = false
        while true {
            if let socket = try? UnixSocket.connect(to: path) {
                reached = true
                delay = firstDelay
                guard relay.serve(socket) else { return 0 }
            } else if !reached, !told {
                told = true
                FileHandle.standardError.write(Data(("\(unavailable) (\(path))\n").utf8))
            }
            if relay.waitForClientToClose(seconds: delay) { return reached ? 0 : 1 }
            delay = min(delay * 2, longestDelay)
        }
    }
}

/// The two directions and what they share. State is under `state`; each stream
/// has its own lock for writing, so a client's large request blocked on a full
/// socket never stops the answers that would empty it.
private final class Relay: @unchecked Sendable {
    /// A longer line than this is dropped by the framer: far above what either
    /// end sends, and a bound on what a broken peer costs.
    private static let longestLine = 256 << 20

    private let output: Int32
    private let state = NSCondition()
    private let writingOutput = NSLock()
    private let writingSocket = NSLock()

    private var socket: Int32?
    private var everConnected = false
    private var clientClosed = false
    /// The requests sent on this connection with no answer yet, by encoded id.
    private var running: [Data: JSONValue] = [:]
    /// What this client said to open its session, said again on a new
    /// connection. A client of the stateless protocol says neither.
    private var opening: JSONValue?
    private var opened: Data?
    private var replays = 0

    init(output: Int32) {
        self.output = output
    }

    // MARK: Client to server

    func readClient(_ input: Int32) {
        var framer = LineFramer(maxLineBytes: Self.longestLine)
        while let chunk = UnixSocket.readSome(input) {
            for case .message(let line) in framer.append(chunk) { forward(line) }
        }
        state.lock()
        clientClosed = true
        // The half-close tells the server the client is done; its last answers
        // still come, and then the socket ends.
        if let socket { shutdown(socket, SHUT_WR) }
        state.broadcast()
        state.unlock()
    }

    private func forward(_ line: Data) {
        let message = try? JSONValue.parse(line)
        let id = message?["method"] == nil ? nil : message?["id"].flatMap { $0.isNull ? nil : $0 }

        state.lock()
        if message?["method"]?.stringValue == "initialize" { opening = message?["params"] }
        if message?["method"]?.stringValue == "notifications/initialized" { opened = line }
        let target = socket
        if target != nil, let id { running[id.encoded()] = id }
        let wasConnected = everConnected
        state.unlock()

        guard let target else {
            if let id { answerError(id, wasConnected ? ServerRelay.restarting : ServerRelay.unavailable) }
            return
        }
        writingSocket.lock()
        let written = UnixSocket.writeAll(target, line + Data([0x0A]))
        writingSocket.unlock()
        guard !written, let id else { return }
        // The socket went under this write. The reader answers what is running
        // when it sees that, unless this one comes off first; one answer either way.
        state.lock()
        let mine = running.removeValue(forKey: id.encoded()) != nil
        state.unlock()
        if mine { answerError(id, ServerRelay.restarting) }
    }

    // MARK: Server to client

    /// Serves one connection to its end. False when the client has stopped
    /// reading, which ends the relay.
    func serve(_ socket: Int32) -> Bool {
        state.lock()
        let opening = self.opening, opened = self.opened
        replays += 1
        let replayed = "byteripper-relay-initialize-\(replays)"
        state.unlock()
        var hello = Data()
        if let opening {
            let again: JSONValue = ["jsonrpc": "2.0", "id": .string(replayed), "method": "initialize", "params": opening]
            hello.append(again.encoded() + Data([0x0A]))
        }
        if let opened { hello.append(opened + Data([0x0A])) }
        // Sent before the socket is published: nothing of the client's can come
        // ahead of it. The server answers `initialize` on the spot, in order.
        guard UnixSocket.writeAll(socket, hello) else {
            Darwin.close(socket)
            return true
        }

        state.lock()
        self.socket = socket
        everConnected = true
        if clientClosed { shutdown(socket, SHUT_WR) }
        state.unlock()

        var reading = true
        var framer = LineFramer(maxLineBytes: Self.longestLine)
        loop: while let chunk = UnixSocket.readSome(socket) {
            for case .message(let line) in framer.append(chunk) {
                let message = try? JSONValue.parse(line)
                if let id = message?["id"], message?["method"] == nil {
                    if id.stringValue == replayed { continue }
                    state.lock()
                    running[id.encoded()] = nil
                    state.unlock()
                }
                guard writeToClient(line + Data([0x0A])) else {
                    reading = false
                    break loop
                }
            }
        }

        state.lock()
        self.socket = nil
        let unanswered = Array(running.values)
        running = [:]
        state.unlock()
        // Wakes a write blocked on this socket; the lock then says it has left,
        // so the descriptor's number cannot go to anyone else under it.
        shutdown(socket, SHUT_RDWR)
        writingSocket.lock()
        Darwin.close(socket)
        writingSocket.unlock()
        guard reading else { return false }
        for id in unanswered { answerError(id, ServerRelay.restarting) }
        return true
    }

    /// Waits up to `seconds`, sooner if the client closes. True when it has.
    func waitForClientToClose(seconds: TimeInterval) -> Bool {
        let limit = Date(timeIntervalSinceNow: seconds)
        state.lock()
        defer { state.unlock() }
        while !clientClosed {
            if !state.wait(until: limit) { break }
        }
        return clientClosed
    }

    private func answerError(_ id: JSONValue, _ text: String) {
        let answer: JSONValue = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .int(MCPProtocol.ErrorCode.internalError), "message": .string(text)]
        ]
        _ = writeToClient(answer.encoded() + Data([0x0A]))
    }

    private func writeToClient(_ data: Data) -> Bool {
        writingOutput.lock()
        defer { writingOutput.unlock() }
        return UnixSocket.writeAll(output, data)
    }
}
