import XCTest
@testable import AgentKit

/// What the server wrote, one parsed message per line, and the calls the log
/// heard about.
private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [JSONValue] = []
    private var records: [AgentCallRecord] = []
    private var starts: [AgentCallRecord] = []
    private var badLines = 0

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        // Exactly one newline, at the end: the framing every client relies on.
        guard data.last == 0x0A, data.dropLast().firstIndex(of: 0x0A) == nil,
              let value = try? JSONValue.parse(data.dropLast()) else {
            badLines += 1
            return
        }
        written.append(value)
    }

    func record(_ record: AgentCallRecord) {
        lock.lock()
        defer { lock.unlock() }
        records.append(record)
    }

    func callStarted(_ record: AgentCallRecord) {
        lock.lock()
        defer { lock.unlock() }
        starts.append(record)
    }

    var started: [AgentCallRecord] { lock.withLock { starts } }
    var messages: [JSONValue] { lock.withLock { written } }
    var calls: [AgentCallRecord] { lock.withLock { records } }
    var malformed: Int { lock.withLock { badLines } }
}

/// Opens when told to; what a slow tool waits on.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class AgentConnectionTests: XCTestCase {
    private let info = AgentServerInfo(name: "ByteRipper", version: "1.0")

    private var echo: AgentTool {
        AgentTool(
            name: "echo",
            description: "Says back what it is given.",
            inputSchema: AgentSchema.object(["text": AgentSchema.string("What to say.")], required: ["text"])
        ) { call in
            .json(["said": .string(try call.arguments.string("text"))])
        }
    }

    private func connection(
        tools: [AgentTool]? = nil, limits: AgentServer.Limits = .init()
    ) -> (AgentConnection, Wire) {
        let wire = Wire()
        let server = AgentServer(
            info: info, instructions: "Ask about the dump.", tools: tools ?? [echo], limits: limits)
        let connection = AgentConnection(
            server: server, send: { wire.send($0) }, observer: { wire.record($0) },
            onCallStarted: { wire.callStarted($0) })
        return (connection, wire)
    }

    private func send(_ connection: AgentConnection, _ lines: String...) async {
        for line in lines { await connection.receive(Data((line + "\n").utf8)) }
        await connection.waitUntilIdle()
    }

    private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"test-client","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}"#

    // MARK: - The legacy handshake

    /// The order a handshake-era client opens with: `initialize`, the
    /// `initialized` notification, the list, a call. The shape follows the
    /// 2025-06-18 schema; the transcript a real client writes is checked
    /// against the app in stage 2, where there is a socket to record it on.
    func testALegacyClientShakesHandsListsAndCalls() async throws {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{}},"clientInfo":{"name":"claude-code","version":"2.1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)

        let messages = wire.messages
        XCTAssertEqual(messages.count, 3, "the notification is not answered")
        XCTAssertEqual(messages[0], ["jsonrpc": "2.0", "id": 0, "result": [
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "ByteRipper", "version": "1.0"],
            "instructions": "Ask about the dump."
        ]])
        let tools = try XCTUnwrap(messages[1]["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.map { $0["name"] }, ["echo"])
        XCTAssertEqual(tools[0]["annotations"]?["readOnlyHint"], true)
        XCTAssertEqual(tools[0]["inputSchema"]?["required"], ["text"])
        XCTAssertNil(messages[1]["result"]?["resultType"], "a legacy result carries no resultType")
        XCTAssertNil(messages[1]["result"]?["ttlMs"], "nor a cache hint")
        XCTAssertEqual(messages[2], ["jsonrpc": "2.0", "id": 2, "result": [
            "content": [["type": "text", "text": #"{"said":"hi"}"#]], "isError": false
        ]])
        XCTAssertEqual(wire.malformed, 0)
        let clientName = await connection.clientName
        XCTAssertEqual(clientName, "claude-code")
    }

    func testAnUnknownLegacyVersionIsAnsweredWithTheNewestOne() async {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2023-01-01","capabilities":{},"clientInfo":{"name":"old","version":"0"}}}"#)
        XCTAssertEqual(wire.messages.first?["result"]?["protocolVersion"], "2025-11-25")
    }

    // MARK: - The modern era

    func testAModernClientDiscoversListsAndCallsWithoutAHandshake() async throws {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"l","method":"tools/list","params":{\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"},\#(modernMeta)}}"#)

        let messages = wire.messages
        XCTAssertEqual(messages.count, 3)
        let discover = try XCTUnwrap(messages[0]["result"])
        XCTAssertEqual(discover["resultType"], "complete")
        XCTAssertEqual(discover["supportedVersions"],
                       ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        XCTAssertEqual(discover["capabilities"], ["tools": .object([:])])
        XCTAssertEqual(discover["instructions"], "Ask about the dump.")
        XCTAssertEqual(discover["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"], "ByteRipper")

        XCTAssertEqual(messages[1]["result"]?["resultType"], "complete")
        XCTAssertEqual(messages[1]["result"]?["tools"]?.arrayValue?.count, 1)
        // Required on both: a client that validates refuses the list without
        // them, and is then left with no tools.
        for result in [discover, try XCTUnwrap(messages[1]["result"])] {
            XCTAssertEqual(result["ttlMs"], 300_000)
            XCTAssertEqual(result["cacheScope"], "public")
        }

        XCTAssertEqual(messages[2]["id"], "c")
        XCTAssertEqual(messages[2]["result"]?["resultType"], "complete")
        XCTAssertEqual(messages[2]["result"]?["content"], [["type": "text", "text": #"{"said":"hi"}"#]])
        XCTAssertEqual(wire.calls.first?.client, "test-client")
    }

    func testAModernRequestForAnUnknownVersionListsTheOnesSpoken() async {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#)
        XCTAssertEqual(wire.messages.first?["error"]?["code"], -32022)
        XCTAssertEqual(wire.messages.first?["error"]?["data"]?["requested"], "2099-01-01")
        XCTAssertEqual(wire.messages.first?["error"]?["data"]?["supported"]?.arrayValue?.first, "2026-07-28")
    }

    func testAModernRequestWithoutCapabilitiesIsMalformed() async {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#)
        XCTAssertEqual(wire.messages.first?["error"]?["code"], -32602)
    }

    // MARK: - Errors

    func testAnUnknownToolIsAProtocolErrorAndAToolsOwnFailureIsAnAnswer() async {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        let messages = wire.messages
        XCTAssertEqual(messages[0]["error"]?["code"], -32602)
        XCTAssertEqual(messages[0]["error"]?["message"], "Unknown tool: nope")
        XCTAssertEqual(messages[1]["result"], [
            "content": [["type": "text", "text": "Argument `text` is required."]], "isError": true
        ])
        XCTAssertEqual(wire.calls.map(\.outcome), [.toolError("Argument `text` is required.")])
    }

    func testWhatIsNotARequestIsAnsweredWithTheRightCode() async {
        let (connection, wire) = connection()
        await send(connection,
            "{not json",
            #"[1,2]"#,
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":"x"}"#)
        XCTAssertEqual(wire.messages.map { $0["error"]?["code"] }, [-32700, -32600, -32601, -32600, -32602])
        XCTAssertEqual(wire.messages.map { $0["id"] }, [.null, .null, 1, .null, 2])
    }

    func testAResponseAndANotificationAreNeverAnswered() async {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":9,"result":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}"#)
        XCTAssertEqual(wire.messages, [])
    }

    func testPingIsAnswered() async {
        let (connection, wire) = connection()
        await send(connection, #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        XCTAssertEqual(wire.messages, [["jsonrpc": "2.0", "id": "p", "result": .object([:])]])
    }

    func testALineOverTheBoundIsRefusedAndTheConnectionGoesOn() async {
        let (connection, wire) = connection(limits: .init(maxLineBytes: 64))
        await send(connection,
            #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"padding":"\#(String(repeating: "x", count: 100))"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual(wire.messages.map { $0["error"]?["code"] }, [-32600, nil])
        XCTAssertEqual(wire.messages.last?["id"], 2)
    }

    // MARK: - Bounds

    func testAnAnswerOverTheBoundIsNotSentAndTheModelIsToldWhy() async throws {
        let big = AgentTool(name: "big", description: "Too much.") { _ in
            .text(String(repeating: "a", count: 2000))
        }
        let (connection, wire) = connection(tools: [big], limits: .init(maxAnswerBytes: 1000))
        await send(connection, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"big"}}"#)
        let result = try XCTUnwrap(wire.messages.first?["result"])
        XCTAssertEqual(result["isError"], true)
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.hasPrefix("The answer is 2000 bytes, over the 1000-byte bound"), text)
        XCTAssertEqual(wire.calls.first?.outcome, .overBound)
        XCTAssertEqual(wire.calls.first?.answerBytes, 2000)
    }

    // MARK: - Calls that take time

    /// A slow call does not hold up what comes after it.
    func testAPingIsAnsweredWhileACallIsStillRunning() async throws {
        let gate = Gate()
        let slow = AgentTool(name: "slow", description: "Waits.") { _ in
            await gate.wait()
            return .text("done")
        }
        let (connection, wire) = connection(tools: [slow])
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"# + "\n").utf8))
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n").utf8))
        XCTAssertEqual(wire.messages.map { $0["id"] }, [2])
        await gate.release()
        await connection.waitUntilIdle()
        XCTAssertEqual(wire.messages.map { $0["id"] }, [2, 1])
    }

    /// A log can show what the tool is busy with: the call is reported when it
    /// starts, as running, and again under the same id when it ends.
    func testACallIsReportedWhenItStartsAndAgainWhenItEnds() async throws {
        let gate = Gate()
        let slow = AgentTool(name: "slow", description: "Waits.",
                             inputSchema: AgentSchema.object(["n": AgentSchema.integer("Anything.")])) { _ in
            await gate.wait()
            return .text("done")
        }
        let (connection, wire) = connection(tools: [slow])
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{"n":1}}}"# + "\n").utf8))

        let running = try XCTUnwrap(wire.started.first)
        XCTAssertEqual(wire.started.count, 1)
        XCTAssertEqual(running.tool, "slow")
        XCTAssertEqual(running.arguments, ["n": 1])
        XCTAssertTrue(running.isRunning)
        XCTAssertTrue(wire.calls.isEmpty, "nothing is finished yet")

        await gate.release()
        await connection.waitUntilIdle()
        let finished = try XCTUnwrap(wire.calls.first)
        XCTAssertEqual(wire.calls.count, 1)
        XCTAssertEqual(finished.id, running.id, "the finished record replaces the running one")
        XCTAssertEqual(finished.outcome, .answered)
        XCTAssertEqual(finished.started, running.started)
    }

    func testACancelledCallIsStoppedAndNeverAnswered() async throws {
        let started = Gate()
        let slow = AgentTool(name: "slow", description: "Waits until cancelled.") { _ in
            await started.release()
            try await Task.sleep(for: .seconds(60))
            return .text("too late")
        }
        let (connection, wire) = connection(tools: [slow])
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":{"name":"slow"}}"# + "\n").utf8))
        await started.wait()
        await send(connection, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"s","reason":"user"}}"#)
        XCTAssertEqual(wire.messages, [])
        XCTAssertEqual(wire.calls.map(\.outcome), [.cancelled])
    }

    func testACallStillRunningWhenTheClientGoesIsNotAnswered() async throws {
        let gate = Gate()
        let slow = AgentTool(name: "slow", description: "Waits.") { _ in
            await gate.wait()
            return .text("nobody listening")
        }
        let (connection, wire) = connection(tools: [slow])
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"# + "\n").utf8))
        await connection.close()
        await gate.release()
        await send(connection, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(wire.messages, [])
    }

    /// Progress goes out only when asked for, carries the client's token, and
    /// never goes backwards.
    func testProgressIsReportedWithTheTokenAndOnlyForwards() async throws {
        let counting = AgentTool(name: "count", description: "Counts.") { call in
            await call.progress(1, 3, "one")
            await call.progress(2, 3, nil)
            await call.progress(2, 3, "again")
            await call.progress(1, 3, "backwards")
            await call.progress(3, 3, "done")
            return .text("ok")
        }
        let (connection, wire) = connection(tools: [counting])
        await send(connection,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"count","_meta":{"progressToken":"t1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"count"}}"#)
        let progress = wire.messages.filter { $0["method"] == "notifications/progress" }
        XCTAssertEqual(progress.map { $0["params"]?["progress"]?.doubleValue }, [1, 2, 3])
        XCTAssertEqual(progress.map { $0["params"]?["progressToken"] }, ["t1", "t1", "t1"])
        XCTAssertEqual(progress.first?["params"]?["message"], "one")
        XCTAssertNil(progress[1]["params"]?["message"])
        XCTAssertEqual(wire.messages.filter { $0["result"] != nil }.count, 2)
    }

    func testAStringIdAndAnIntegerIdAreTwoRequests() async {
        let (connection, wire) = connection()
        await send(connection,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"a"}}}"#,
            #"{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"echo","arguments":{"text":"b"}}}"#)
        XCTAssertEqual(Set(wire.messages.compactMap { $0["id"]?.jsonText }), ["1", #""1""#])
    }
}
