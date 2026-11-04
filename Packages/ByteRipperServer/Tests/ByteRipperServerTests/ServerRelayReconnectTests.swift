import AgentKit
import Foundation
import ServerRelay
import XCTest

/// The relay against a server that goes and comes back, on a socket of the
/// test's own. The server is a small one of the test's: what is under test is
/// what reaches it and what reaches the client.
final class ServerRelayReconnectTests: XCTestCase {
    /// Answers each request `{"method": …, "connection": n}`, except `hold`,
    /// which it never answers, and records what each connection received.
    private final class Server: @unchecked Sendable {
        let listener: UnixSocketListener
        let connection: Int
        private let lock = NSLock()
        private var open: [UnixSocketConnection] = []
        private var received: [JSONValue] = []

        init(path: String, connection: Int) throws {
            listener = UnixSocketListener(path: path)
            self.connection = connection
            try listener.start { [self] client in
                lock.withLock { open.append(client) }
                var framer = LineFramer()
                client.startReading(onData: { [self] chunk in
                    for case .message(let line) in framer.append(chunk) {
                        guard let message = try? JSONValue.parse(line) else { continue }
                        lock.withLock { received.append(message) }
                        guard let id = message["id"], let method = message["method"]?.stringValue, method != "hold" else { continue }
                        let answer: JSONValue = ["jsonrpc": "2.0", "id": id,
                                                 "result": ["method": .string(method), "connection": .int(Int64(self.connection))]]
                        client.write(answer.encoded() + Data([0x0A]))
                    }
                }, onClose: {})
            }
        }

        var messages: [JSONValue] { lock.withLock { received } }

        func stop() {
            listener.stop()
            lock.withLock { open.forEach { $0.close() } }
        }
    }

    /// The client's end: writes to the relay's stdin, reads its stdout.
    private final class Client {
        let input: Int32, output: Int32
        private var framer = LineFramer()
        private var ready: [JSONValue] = []
        private(set) var seen: [JSONValue] = []

        init(input: Int32, output: Int32) {
            self.input = input
            self.output = output
        }

        func send(_ message: JSONValue) {
            XCTAssertTrue(UnixSocket.writeAll(input, message.encoded() + Data([0x0A])))
        }

        func request(_ id: Int64, _ method: String, _ params: JSONValue = .object([:])) {
            send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
        }

        func next(file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
            let limit = Date(timeIntervalSinceNow: 15)
            while ready.isEmpty {
                var ask = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                let left = Int32(max(0, limit.timeIntervalSinceNow) * 1000)
                guard poll(&ask, 1, left) > 0, let chunk = UnixSocket.readSome(output) else {
                    XCTFail("no answer from the relay", file: file, line: line)
                    throw CocoaError(.fileReadUnknown)
                }
                for case .message(let line) in framer.append(chunk) {
                    let message = try JSONValue.parse(line)
                    seen.append(message)
                    ready.append(message)
                }
            }
            return ready.removeFirst()
        }
    }

    private var path = ""
    private var pipes: [Int32] = []

    override func setUp() {
        path = "/tmp/br-relay-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        pipes.forEach { Darwin.close($0) }
        unlink(path)
    }

    /// Starts a relay on pipes. The result says how it ended.
    private func start() -> (Client, XCTestExpectation, () -> Int32) {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&input), 0)
        XCTAssertEqual(pipe(&output), 0)
        pipes += [input[0], output[1], output[0]]
        let ended = expectation(description: "the relay ended")
        let code = Code()
        let path = path, reads = input[0], writes = output[1]
        Thread.detachNewThread {
            code.value = ServerRelay.run(path: path, input: reads, output: writes, firstDelay: 0.05, longestDelay: 0.2)
            ended.fulfill()
        }
        return (Client(input: input[1], output: output[0]), ended, { code.value })
    }

    private final class Code: @unchecked Sendable { var value: Int32 = -1 }

    /// Asks until a connected relay answers, as a client's next call does.
    private func callUntilAnswered(_ client: Client, from first: Int64) throws -> JSONValue {
        var id = first
        for _ in 0..<200 {
            client.request(id, "tools/list")
            let answer = try client.next()
            if answer["result"] != nil { return answer }
            XCTAssertEqual(answer["error"]?["message"]?.stringValue, ServerRelay.restarting)
            id += 1
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw CocoaError(.fileReadUnknown)
    }

    /// The server goes with a call running and comes back: the client keeps its
    /// stdio, the running call and those made meanwhile are answered, and the
    /// next one reaches the new server, which has heard the client's opening.
    func testARestartCostsTheRunningCallAndNotTheConnection() throws {
        let first = try Server(path: path, connection: 1)
        let (client, ended, code) = start()
        let params: JSONValue = ["protocolVersion": "2025-06-18", "clientInfo": ["name": "tester"]]
        client.request(1, "initialize", params)
        XCTAssertEqual(try client.next()["result"]?["connection"], 1)
        client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        client.request(2, "tools/list")
        XCTAssertEqual(try client.next()["id"], 2)

        client.request(3, "hold")
        // Delivered before the server goes: the call is running when it does.
        for _ in 0..<500 where !first.messages.contains(where: { $0["method"]?.stringValue == "hold" }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        first.stop()
        let cut = try client.next()
        XCTAssertEqual(cut["id"], 3)
        XCTAssertEqual(cut["error"]?["message"]?.stringValue, ServerRelay.restarting)

        client.request(4, "tools/list")
        let down = try client.next()
        XCTAssertEqual(down["id"], 4)
        XCTAssertEqual(down["error"]?["message"]?.stringValue, ServerRelay.restarting)

        let second = try Server(path: path, connection: 2)
        defer { second.stop() }
        let answer = try callUntilAnswered(client, from: 5)
        XCTAssertEqual(answer["result"]?["connection"], 2)

        let heard = second.messages
        XCTAssertEqual(heard.first?["method"]?.stringValue, "initialize", "\(heard)")
        XCTAssertEqual(heard.first?["params"], params)
        XCTAssertEqual(heard.dropFirst().first?["method"]?.stringValue, "notifications/initialized", "\(heard)")
        XCTAssertFalse(client.seen.contains { $0["id"]?.stringValue?.hasPrefix("byteripper-relay") == true },
                       "the answer to the relay's own initialize stays with it")

        Darwin.close(client.input)
        second.stop()
        wait(for: [ended], timeout: 15)
        XCTAssertEqual(code(), 0)
    }

    /// A server that comes up after the client started is reached; a client of
    /// the stateless protocol said no opening, so none is said for it.
    func testAServerThatStartsLaterIsReachedWithNoOpeningOfItsOwn() throws {
        let (client, ended, code) = start()
        client.request(1, "tools/list")
        XCTAssertEqual(try client.next()["error"]?["message"]?.stringValue, ServerRelay.unavailable)
        let server = try Server(path: path, connection: 1)
        defer { server.stop() }
        var answer = JSONValue.null
        for id in Int64(2)..<400 {
            client.request(id, "tools/list")
            answer = try client.next()
            if answer["result"] != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(answer["result"]?["connection"], 1)
        XCTAssertFalse(server.messages.contains { $0["method"]?.stringValue == "initialize" })
        Darwin.close(client.input)
        server.stop()
        wait(for: [ended], timeout: 15)
        XCTAssertEqual(code(), 0)
    }
}
