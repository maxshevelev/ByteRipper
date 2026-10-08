import AgentKit
import XCTest
@testable import ByteRipper

/// A client of the agent service in memory: lines of JSON in, lines out, and
/// a tool's answer handed back as the JSON it was — what the agent tests drive
/// the service with instead of a socket.
@MainActor
final class AgentTestClient {
    private let wire = Wire()
    private let connection: AgentConnection
    private var nextID = 1

    init(_ service: AgentService) {
        let wire = self.wire
        connection = service.connect(send: { wire.send($0) })
    }

    /// Calls `tool` and returns its answer: the JSON a tool answered with, or
    /// the sentence it refused with as `.string`, marked by `isError`.
    func call(_ tool: String, _ arguments: JSONValue = .object([:]),
              file: StaticString = #filePath, line: UInt = #line) async throws -> (answer: JSONValue, isError: Bool) {
        let id = nextID
        nextID += 1
        let request: JSONValue = ["jsonrpc": "2.0", "id": .count(id), "method": "tools/call",
                                  "params": ["name": .string(tool), "arguments": arguments]]
        await connection.receive(request.encoded() + Data("\n".utf8))
        await connection.waitUntilIdle()
        let response = try XCTUnwrap(wire.messages.first { $0["id"] == .count(id) }, file: file, line: line)
        let result = try XCTUnwrap(response["result"], "\(response)", file: file, line: line)
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue, file: file, line: line)
        let isError = result["isError"] == true
        return (isError ? .string(text) : try JSONValue.parse(Data(text.utf8)), isError)
    }

    /// Calls `tool` and fails the test if it refused.
    func answer(_ tool: String, _ arguments: JSONValue = .object([:]),
                file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let (answer, isError) = try await call(tool, arguments, file: file, line: line)
        XCTAssertFalse(isError, "\(tool) refused: \(answer)", file: file, line: line)
        return answer
    }

    /// Everything the service wrote, parsed.
    var messages: [JSONValue] { wire.messages }

    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [JSONValue] = []

        func send(_ data: Data) {
            guard let value = try? JSONValue.parse(data.dropLast()) else { return }
            lock.withLock { written.append(value) }
        }

        var messages: [JSONValue] { lock.withLock { written } }
    }
}
