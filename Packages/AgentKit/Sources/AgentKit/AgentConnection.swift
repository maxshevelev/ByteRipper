import Foundation

/// One client, from the bytes it sends to the bytes it is sent.
///
/// The transport — a socket in the app, a pipe in a test — hands every chunk
/// it reads to `receive` and writes whatever `send` is given; everything
/// between is here: the framing, which era a request belongs to, the answer,
/// and the calls still running. Nothing here knows what the transport is,
/// which is what lets `swift test` drive a whole conversation as lines.
///
/// A tool call runs as a task of its own, so a survey that takes a minute does
/// not hold up a `ping` or a second call behind it; everything else is
/// answered in the order it arrived. A call the client cancels is told to stop
/// and is never answered, as the protocol requires.
public actor AgentConnection {
    public let server: AgentServer
    private let send: @Sendable (Data) -> Void
    private let observer: @Sendable (AgentCallRecord) -> Void

    private var framer: LineFramer
    /// The version an `initialize` agreed on. Nil until a legacy client
    /// shakes hands; a modern client never does.
    private(set) var legacyVersion: String?
    /// What the client called itself — in `initialize`, or in the `_meta` of
    /// its latest modern request.
    private(set) var clientName: String?
    private var inFlight: [RequestKey: InFlight] = [:]
    /// Calls that were cancelled and have not stopped yet. Nobody will hear
    /// their answer, but they are still work in progress, and
    /// `waitUntilIdle` must wait for them like any other.
    private var stopping: [Task<Void, Never>] = []
    private var closed = false

    private struct InFlight {
        let task: Task<Void, Never>
        let progressToken: JSONValue?
        var lastProgress: Double?
    }

    /// `send` is given one message at a time, a complete line with its
    /// newline. `observer` hears about every tool call once it is over.
    public init(
        server: AgentServer,
        send: @escaping @Sendable (Data) -> Void,
        observer: @escaping @Sendable (AgentCallRecord) -> Void = { _ in }
    ) {
        self.server = server
        self.send = send
        self.observer = observer
        self.framer = LineFramer(maxLineBytes: server.limits.maxLineBytes)
    }

    /// The next piece of what the client wrote.
    public func receive(_ chunk: Data) {
        guard !closed else { return }
        for line in framer.append(chunk) {
            switch line {
            case .message(let data):
                handle(data)
            case .tooLong:
                write(RPCMessage.error(id: .null, RPCError(
                    code: MCPProtocol.ErrorCode.invalidRequest,
                    message: "Message longer than \(server.limits.maxLineBytes) bytes")))
            }
        }
    }

    /// The client has gone. Every call still running is told to stop, and
    /// nothing more is written.
    public func close() {
        closed = true
        for entry in inFlight.values {
            entry.task.cancel()
            stopping.append(entry.task)
        }
        inFlight.removeAll()
    }

    /// Returns once no tool call is running. For a test, and for a transport
    /// that wants to finish what it was asked before it closes.
    public func waitUntilIdle() async {
        while let task = inFlight.values.first?.task ?? stopping.first {
            await task.value
            stopping.removeAll { $0 == task }
        }
    }

    // MARK: - One message

    private func handle(_ data: Data) {
        guard let message = try? JSONValue.parse(data) else {
            write(RPCMessage.error(id: .null, RPCError(code: MCPProtocol.ErrorCode.parseError, message: "Parse error")))
            return
        }
        guard case .object(let members) = message, members["jsonrpc"] == "2.0" else {
            write(RPCMessage.error(id: .null, RPCError(
                code: MCPProtocol.ErrorCode.invalidRequest, message: "Not a JSON-RPC 2.0 message")))
            return
        }
        guard let method = members["method"]?.stringValue else {
            // A response. The server sends no requests, so there is nothing
            // it could be a response to, and a response is never answered.
            if members["result"] != nil || members["error"] != nil { return }
            write(RPCMessage.error(id: members["id"] ?? .null, RPCError(
                code: MCPProtocol.ErrorCode.invalidRequest, message: "No method")))
            return
        }
        let params = members["params"] ?? .object([:])
        guard let id = members["id"] else {
            handleNotification(method, params: params)
            return
        }
        guard let key = RequestKey(id) else {
            write(RPCMessage.error(id: .null, RPCError(
                code: MCPProtocol.ErrorCode.invalidRequest, message: "The id must be a string or an integer")))
            return
        }
        guard params.objectValue != nil else {
            write(RPCMessage.error(id: id, .invalidParams("params must be an object")))
            return
        }
        do {
            try handleRequest(method, id: id, key: key, params: params)
        } catch let error as RPCError {
            write(RPCMessage.error(id: id, error))
        } catch {
            write(RPCMessage.error(id: id, RPCError(code: MCPProtocol.ErrorCode.internalError, message: "\(error)")))
        }
    }

    private func handleNotification(_ method: String, params: JSONValue) {
        switch method {
        case "notifications/cancelled":
            guard let id = params["requestId"], let key = RequestKey(id),
                  let entry = inFlight.removeValue(forKey: key) else { return }
            // Removed first: whatever the task does from here, its answer
            // finds no entry and is not written.
            entry.task.cancel()
            stopping.append(entry.task)
        default:
            // `notifications/initialized` says nothing this server waits
            // for; anything else is not addressed to it.
            break
        }
    }

    private func handleRequest(_ method: String, id: JSONValue, key: RequestKey, params: JSONValue) throws {
        let era: MCPEra
        if let version = params["_meta"]?[MCPProtocol.Meta.protocolVersion] {
            era = try modernEra(version: version, meta: params["_meta"] ?? .null)
        } else if method == "initialize" {
            write(RPCMessage.result(id: id, try initialize(params)))
            return
        } else {
            // No handshake and no `_meta`: a legacy client that skipped
            // `initialize`, or one that sent it on an earlier connection.
            // Served rather than refused — the specification asks clients
            // not to do it, and refusing would help nobody.
            era = .legacy(version: legacyVersion ?? MCPProtocol.legacyVersions[0])
        }

        switch method {
        case "server/discover":
            write(RPCMessage.result(id: id, wrap(discovery(), era: era, cacheable: true)))
        case "ping":
            write(RPCMessage.result(id: id, wrap(.object([:]), era: era)))
        case "tools/list":
            let tools = JSONValue.array(server.tools.map(\.listing))
            write(RPCMessage.result(id: id, wrap(["tools": tools], era: era, cacheable: true)))
        case "tools/call":
            try startCall(id: id, key: key, params: params, era: era)
        default:
            throw RPCError(code: MCPProtocol.ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    // MARK: - Eras

    private func modernEra(version: JSONValue, meta: JSONValue) throws -> MCPEra {
        guard let version = version.stringValue else {
            throw RPCError.invalidParams("\(MCPProtocol.Meta.protocolVersion) must be a string")
        }
        guard MCPProtocol.modernVersions.contains(version) else {
            throw RPCError(
                code: MCPProtocol.ErrorCode.unsupportedProtocolVersion,
                message: "Unsupported protocol version",
                data: ["supported": .array(MCPProtocol.supportedVersions.map { .string($0) }),
                       "requested": .string(version)])
        }
        guard meta[MCPProtocol.Meta.clientCapabilities]?.objectValue != nil else {
            throw RPCError.invalidParams("\(MCPProtocol.Meta.clientCapabilities) is required")
        }
        if let name = meta[MCPProtocol.Meta.clientInfo]?["name"]?.stringValue { clientName = name }
        return .modern(version: version)
    }

    private func initialize(_ params: JSONValue) throws -> JSONValue {
        guard let requested = params["protocolVersion"]?.stringValue else {
            throw RPCError.invalidParams("protocolVersion is required")
        }
        // The client's version when it is one this server speaks; otherwise
        // the newest one it does, and the client decides whether that will
        // do — the handshake's rule.
        let agreed = MCPProtocol.legacyVersions.contains(requested) ? requested : MCPProtocol.legacyVersions[0]
        legacyVersion = agreed
        clientName = params["clientInfo"]?["name"]?.stringValue
        var result: [String: JSONValue] = [
            "protocolVersion": .string(agreed),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": server.info.json
        ]
        if let instructions = server.instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    private func discovery() -> JSONValue {
        var result: [String: JSONValue] = [
            "supportedVersions": .array(MCPProtocol.supportedVersions.map { .string($0) }),
            "capabilities": ["tools": .object([:])]
        ]
        if let instructions = server.instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    /// A result as its era writes it: a modern one says what kind of result
    /// it is and who sent it, because the client holds nothing from earlier
    /// to know either by; a legacy one is left as the handshake versions
    /// define it.
    ///
    /// A modern `server/discover` and `tools/list` must also say how long the
    /// answer may be kept and by whom — the specification requires it, and a
    /// client that validates the result refuses one without (Claude Code
    /// 2.1.292 does, and then has no tools). The list does not change while
    /// the app runs, and is the same for whoever asks.
    private func wrap(_ result: JSONValue, era: MCPEra, cacheable: Bool = false) -> JSONValue {
        guard case .modern = era, case .object(var members) = result else { return result }
        members["resultType"] = "complete"
        members["_meta"] = [MCPProtocol.Meta.serverInfo: server.info.json]
        if cacheable {
            members["ttlMs"] = .int(MCPProtocol.listTTLMilliseconds)
            members["cacheScope"] = "public"
        }
        return .object(members)
    }

    // MARK: - Tool calls

    private func startCall(id: JSONValue, key: RequestKey, params: JSONValue, era: MCPEra) throws {
        guard let name = params["name"]?.stringValue else {
            throw RPCError.invalidParams("name is required")
        }
        guard let tool = server.tool(named: name) else {
            throw RPCError.invalidParams("Unknown tool: \(name)")
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let members)?: arguments = members
        default: throw RPCError.invalidParams("arguments must be an object")
        }
        guard inFlight[key] == nil else {
            throw RPCError(code: MCPProtocol.ErrorCode.invalidRequest, message: "A request with this id is still running")
        }

        let call = AgentCall(tool: name, arguments: AgentArguments(arguments, answerBound: server.limits.maxAnswerBytes)) { [weak self] progress, total, message in
            await self?.reportProgress(key, progress: progress, total: total, message: message)
        }
        let client = clientName
        let task = Task { [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            let outcome: CallOutcome
            do {
                outcome = .answer(try await tool.run(call))
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as AgentToolError {
                outcome = .toolError(error.message)
            } catch {
                outcome = .toolError("The tool failed: \(error)")
            }
            await self?.finishCall(
                id: id, key: key, era: era, outcome: outcome,
                record: (client, name, .object(arguments), clock.now - started))
        }
        inFlight[key] = InFlight(task: task, progressToken: params["_meta"]?[MCPProtocol.Meta.progressToken])
    }

    private enum CallOutcome {
        case answer(AgentAnswer)
        case toolError(String)
        case cancelled
    }

    private func finishCall(
        id: JSONValue, key: RequestKey, era: MCPEra, outcome: CallOutcome,
        record: (client: String?, tool: String, arguments: JSONValue, duration: Duration)
    ) {
        func log(_ outcome: AgentCallRecord.Outcome, bytes: Int) {
            observer(AgentCallRecord(
                client: record.client, tool: record.tool, arguments: record.arguments,
                duration: record.duration, finished: Date(), answerBytes: bytes, outcome: outcome))
        }
        // Gone from the table means the client cancelled it, or went: either
        // way nobody is waiting, and the protocol forbids writing to them
        // about it.
        guard inFlight.removeValue(forKey: key) != nil, !closed else {
            log(.cancelled, bytes: 0)
            return
        }
        let text: String
        let isError: Bool
        switch outcome {
        case .answer(let answer):
            let answerText = answer.text
            let size = answerText.utf8.count
            if size > server.limits.maxAnswerBytes {
                text = "The answer is \(size) bytes, over the \(server.limits.maxAnswerBytes)-byte bound, "
                    + "and was not sent. Ask for less: a lower `limit`, a narrower range, "
                    + "or one node instead of its parent."
                isError = true
                log(.overBound, bytes: size)
            } else {
                text = answerText
                isError = false
                log(.answered, bytes: size)
            }
        case .toolError(let message):
            text = message
            isError = true
            log(.toolError(message), bytes: message.utf8.count)
        case .cancelled:
            // The tool stopped itself with a cancellation nobody asked for —
            // a bug in the tool, but the client is still owed an answer.
            text = "The call was cancelled before it finished."
            isError = true
            log(.toolError(text), bytes: text.utf8.count)
        }
        write(RPCMessage.result(id: id, wrap(toolResult(text, isError: isError), era: era)))
    }

    private func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    private func reportProgress(_ key: RequestKey, progress: Double, total: Double?, message: String?) {
        guard !closed, var entry = inFlight[key], let token = entry.progressToken else { return }
        if let last = entry.lastProgress, progress <= last { return }
        entry.lastProgress = progress
        inFlight[key] = entry
        var params: [String: JSONValue] = ["progressToken": token, "progress": .double(progress)]
        if let total { params["total"] = .double(total) }
        if let message { params["message"] = .string(message) }
        write(RPCMessage.notification("notifications/progress", .object(params)))
    }

    // MARK: - Writing

    private func write(_ message: JSONValue) {
        guard !closed else { return }
        var data = message.encoded()
        data.append(0x0A)
        send(data)
    }
}

/// A request id as a dictionary key: JSON-RPC allows a string or an integer,
/// and `1` and `"1"` are two different requests.
private enum RequestKey: Hashable {
    case int(Int64)
    case string(String)

    init?(_ id: JSONValue) {
        switch id {
        case .int(let value): self = .int(value)
        case .string(let value): self = .string(value)
        default: return nil
        }
    }
}
