import AgentKit
import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// What the tools refuse before anything reaches a backend, found by the
/// audit of their descriptions: an `id` without `address` linked every
/// match, `clear_code: true` was refused every time, an equate item's
/// unknown key named another operand, a comment item without `text` erased
/// the comment.
final class ToolArgumentChecksTests: XCTestCase {
    private actor Calls {
        var made: [(String, Data)] = []
        func add(_ call: String, _ body: Data) { made.append((call, body)) }
    }

    private struct Recording: GhidraBackendWithoutServer {
        let calls: Calls
        func listModules() async throws -> Data { Data() }
        func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data { Data() }
        func openModule(_ module: SHA256Digest) async throws -> Data { Data() }
        func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data { Data() }
        func previewCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data { Data("{}".utf8) }
        func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
            await calls.add(call, body)
            return Data("{}".utf8)
        }
        func publishModule(_ module: SHA256Digest, by: String, options: GhidraHost.PublishOptions) async throws -> Data {
            Data()
        }
        func publishPreview(_ module: SHA256Digest, takeTypeConflicts: Bool) async throws -> Data { Data() }
        func takeModule(_ module: SHA256Digest) async throws -> Data { Data() }
        func releaseModule(_ module: SHA256Digest, by: String, discard: Bool) async throws -> Data { Data() }
        func library(_ module: SHA256Digest, _ request: GhidraHost.LibraryRequest) async throws -> Data {
            await calls.add("library", Data())
            return Data("{}".utf8)
        }
    }

    private let module = JSONValue.string(String(repeating: "ab", count: 32))

    private func call(_ name: String, _ arguments: [String: JSONValue], calls: Calls) async -> String? {
        let tool = GhidraTools.tools(backend: Recording(calls: calls)).first { $0.name == name }!
        do {
            _ = try await tool.run(AgentCall(tool: name, arguments: AgentArguments(arguments)))
            return nil
        } catch {
            return "\(error)"
        }
    }

    func testAnIdOrAReasonWithoutAnAddressIsRefusedAndNothingIsLinked() async {
        let calls = Calls()
        let refused = await call("ghidra_library_apply", ["module": module, "id": "e1"], calls: calls)
        XCTAssertTrue(refused?.contains("name it by `address`") == true, refused ?? "not refused")
        let reason = await call("ghidra_library_apply", ["module": module, "reason": "why"], calls: calls)
        XCTAssertNotNil(reason)
        let made = await calls.made
        XCTAssertTrue(made.isEmpty, "nothing reached the backend")
    }

    func testClearCodeIsTakenAsTheBooleanTheSchemaSays() async throws {
        let calls = Calls()
        let refused = await call("ghidra_set_data", ["module": module, "address": "0x10", "type": "UINT32",
                                                     "clear_code": true], calls: calls)
        XCTAssertNil(refused)
        let made = await calls.made
        let body = try XCTUnwrap(made.first?.1)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["clear_code"] as? Bool, true)
    }

    func testAnEquateItemIsHeldToItsKeysAndItemsGoWithoutFunctions() async {
        let calls = Calls()
        let slip = await call("ghidra_equate", ["module": module, "name": "MBOX_OFFSET",
                                                "items": [["address": "0x2010", "op": 0]]], calls: calls)
        XCTAssertTrue(slip?.contains("`op`") == true && slip?.contains("`operand`") == true, slip ?? "not refused")
        let both = await call("ghidra_equate", ["module": module, "name": "X", "value": "0x10",
                                                "functions": ["0x100"], "items": [["address": "0x2010"]]], calls: calls)
        XCTAssertTrue(both?.contains("not both") == true, both ?? "not refused")
        let made = await calls.made
        XCTAssertTrue(made.isEmpty)
    }

    func testACommentItemWithoutTextIsRefusedNotAnErasure() async {
        let calls = Calls()
        let slip = await call("ghidra_comment", ["module": module,
                                                 "items": [["address": "0x10", "comment": "Step"]]], calls: calls)
        XCTAssertNotNil(slip)
        let made = await calls.made
        XCTAssertTrue(made.isEmpty, "the comment there was left alone")
    }
}
