import AgentKit
import XCTest
@testable import ByteRipper

/// What the relay promises a client, and the reason the promise is worth a
/// test: **it outlives the app it talks to**.
///
/// A client starts this process once and keeps it for the whole conversation,
/// and the app may be quit and opened again in the middle of one — running it
/// from Xcode does exactly that. A relay that exited with the app left a client
/// which does not restart a server that exited inside a session (Claude Code
/// does not) with nothing until the person registered the server again. So: the
/// process stays, it answers with the reason while there is no app, it attaches
/// to an app that appears, and it attaches again after that app goes and comes
/// back.
final class AgentRelayTests: XCTestCase {
    private var folder: URL!
    private var relay: Process!
    private var toRelay: FileHandle!
    private var fromRelay: FileHandle!
    private var listener: UnixSocketListener?

    private var socketPath: String { folder.appendingPathComponent("agent.sock").path }

    override func setUpWithError() throws {
        // Short on purpose: a Unix socket path has 104 bytes to live in, and
        // the temporary folder's own path is most of that.
        folder = URL(fileURLWithPath: "/tmp/br-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        relay = Process()
        relay.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(AgentEndpoint.relayName)")
        var environment = ProcessInfo.processInfo.environment
        // A socket of this test's own, and never the launch switch: the relay
        // must not open the app the test is running in.
        environment[AgentEndpoint.environmentKey] = socketPath
        environment[AgentEndpoint.launchKey] = "0"
        relay.environment = environment
        let input = Pipe(), output = Pipe()
        relay.standardInput = input
        relay.standardOutput = output
        relay.standardError = Pipe()
        try relay.run()
        toRelay = input.fileHandleForWriting
        fromRelay = output.fileHandleForReading
        // Read without blocking, so a test that expects no answer does not sit
        // in `read` past its own deadline.
        _ = fcntl(fromRelay.fileDescriptor, F_SETFL, O_NONBLOCK)
    }

    override func tearDownWithError() throws {
        try? toRelay?.close()
        relay?.terminate()
        relay?.waitUntilExit()
        listener?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - The client's side

    private func send(_ id: Int) {
        toRelay.write(Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/list"}"#.utf8 + [0x0A]))
    }

    /// The next line the relay writes, or nil when it writes none in time.
    private func answerFromRelay(timeout: TimeInterval = 10) -> JSONValue? {
        var framer = LineFramer()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let chunk = UnixSocket.readSome(fromRelay.fileDescriptor) {
                for case .message(let line) in framer.append(chunk) {
                    return try? JSONValue.parse(line)
                }
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return nil
    }

    private func reason(_ answer: JSONValue?) -> String? {
        answer?["error"]?["message"]?.stringValue
    }

    // MARK: - The app's side

    /// A stand-in for the app: it listens where the app would, collects what
    /// arrives, answers when told to, and can quit — which closes the socket the
    /// relay is attached to, as the app's exit closes its own.
    private final class FakeApp: @unchecked Sendable {
        private let listener: UnixSocketListener
        private let lock = NSLock()
        private var connection: UnixSocketConnection?
        private var data = Data()

        init(path: String) throws {
            listener = UnixSocketListener(path: path)
            try listener.start { [self] socket in
                lock.lock(); connection = socket; lock.unlock()
                socket.startReading(onData: { [self] chunk in
                    lock.lock(); data.append(chunk); lock.unlock()
                }, onClose: {})
            }
        }

        /// Whether the relay has attached: its connection is the signal, so a
        /// test never sends a request into the window before it.
        var isConnected: Bool {
            lock.lock(); defer { lock.unlock() }
            return connection != nil
        }

        var received: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }

        func answer(_ text: String) {
            lock.lock(); let socket = connection; lock.unlock()
            socket?.write(Data(text.utf8))
        }

        func quit() {
            lock.lock(); let socket = connection; connection = nil; lock.unlock()
            socket?.close()
            listener.stop()
        }
    }

    /// Waits for something the relay brings about, and says what did not
    /// happen when it does not.
    private func waitUntil(_ why: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(condition(), why)
    }

    // MARK: - The tests

    /// No app at all: every request is answered with the reason — and the relay
    /// is still there afterwards, which is the whole point.
    func testWithNoAppEveryRequestIsAnsweredWithTheReason() throws {
        send(1)
        XCTAssertEqual(reason(answerFromRelay()), AgentEndpoint.notStartedMessage)
        send(2)
        XCTAssertEqual(reason(answerFromRelay()), AgentEndpoint.notStartedMessage)
        XCTAssertTrue(relay.isRunning, "the relay stays for the client")
    }

    /// The app appears, and the client's next request goes to it — then the app
    /// goes, and the relay neither exits nor forgets: it answers with the reason
    /// and attaches to the app that comes back.
    func testTheRelayAttachesToAnAppThatComesAndGoes() throws {
        send(1)
        XCTAssertEqual(reason(answerFromRelay()), AgentEndpoint.notStartedMessage)

        let app = try FakeApp(path: socketPath)
        waitUntil("the relay attaches to the app that appeared") { app.isConnected }
        send(2)
        waitUntil("the request reached the app the relay attached to") {
            app.received.contains(#""id":2"#)
        }
        app.answer(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"# + "\n")
        let relayed = answerFromRelay()
        XCTAssertNotNil(relayed?["result"], "the app's answer reached the client")

        // The app quits, and the client is told — not left waiting.
        app.quit()
        var told: String?
        let gone = Date().addingTimeInterval(10)
        while told != AgentEndpoint.notStartedMessage, Date() < gone {
            send(3)
            told = reason(answerFromRelay(timeout: 2))
        }
        XCTAssertEqual(told, AgentEndpoint.notStartedMessage,
                       "with the app gone the client is told, not left waiting")
        XCTAssertTrue(relay.isRunning, "the relay is still the client's server")

        // It comes back, and so does the conversation.
        let again = try FakeApp(path: socketPath)
        waitUntil("the relay attaches to the app that came back") { again.isConnected }
        send(4)
        waitUntil("and the request reaches it") { again.received.contains(#""id":4"#) }
    }
}
