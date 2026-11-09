import AgentKit
import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// `ghidra_rename_variable` with `items`: an item carrying a key the tool does
/// not take is refused before anything is written, naming the key and the
/// keys an item takes — a `new_name` dropped without a word left the name
/// unwritten under an ok answer (issue 21ad3546).
final class RenameVariableItemsTests: XCTestCase {
    private actor Writes {
        var calls: [(String, Data)] = []
        func add(_ call: String, _ body: Data) { calls.append((call, body)) }
    }

    private struct Recording: GhidraBackend {
        let writes: Writes
        func listModules() async throws -> Data { Data() }
        func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data { Data() }
        func openModule(_ module: SHA256Digest) async throws -> Data { Data() }
        func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data { Data() }
        func previewCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data { Data() }
        func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
            await writes.add(call, body)
            return Data("{}".utf8)
        }
        func publishModule(_ module: SHA256Digest, by: String, options: GhidraHost.PublishOptions) async throws -> Data {
            Data()
        }
        func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data { Data() }
        func takeModule(_ module: SHA256Digest) async throws -> Data { Data() }
        func releaseModule(_ module: SHA256Digest, by: String, discard: Bool) async throws -> Data { Data() }
        func library(_ module: SHA256Digest, _ request: GhidraHost.LibraryRequest) async throws -> Data { Data() }
    }

    private func run(_ items: [JSONValue], writes: Writes) async throws {
        let tool = try XCTUnwrap(GhidraTools.tools(backend: Recording(writes: writes))
            .first { $0.name == "ghidra_rename_variable" })
        let arguments = AgentArguments([
            "module": .string(String(repeating: "ab", count: 32)),
            "function": .string("0x9A19159"),
            "items": .array(items)
        ])
        _ = try await tool.run(AgentCall(tool: tool.name, arguments: arguments))
    }

    func testAnItemWithAKeyTheToolDoesNotTakeIsRefusedAndNothingIsWritten() async throws {
        let writes = Writes()
        do {
            try await run([
                .object(["storage": .string("Stack[-0x10]:8"), "name": .string("Idtr"), "type": .string("IA32_DESCRIPTOR")]),
                .object(["storage": .string("EAX:4"), "first_use": .string("0x9A1915F"), "new_name": .string("PcdPpi")])
            ], writes: writes)
            XCTFail("an unknown key went through")
        } catch {
            let said = "\(error)"
            XCTAssertTrue(said.contains("Item 1") && said.contains("`new_name`") && said.contains("`name`"), said)
        }
        let none = await writes.calls.isEmpty
        XCTAssertTrue(none, "nothing is written, the good item included")

        try await run([.object(["storage": .string("EAX:4"), "first_use": .string("0x9A1915F"),
                                "name": .string("PcdPpi")])], writes: writes)
        let calls = await writes.calls
        XCTAssertEqual(calls.map(\.0), ["rename/variables"])
    }
}
