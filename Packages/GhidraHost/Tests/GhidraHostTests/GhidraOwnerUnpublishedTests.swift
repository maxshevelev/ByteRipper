import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// `ghidra_unpublished`: the owner's journal of writes since the last publish,
/// by function and `module`, kept across an owner restart and emptied by a
/// publish. A project from `GHIDRA_TYPE_MODULE` in a temporary folder.
final class GhidraOwnerUnpublishedTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func post(_ path: String, _ object: [String: Any]) async throws {
        try await host.take(module)
        _ = try await host.write(module, path, body: try JSONSerialization.data(withJSONObject: object))
    }

    private func groups(_ query: String = "") async throws -> [[String: Any]] {
        try json(await host.read(module, "/v1/unpublished" + query))["groups"] as? [[String: Any]] ?? []
    }

    func testTheJournalListsTheWritesByFunctionKeepsThemAcrossARestartAndAPublishEmptiesIt() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerUnpublished-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerUnpublishedTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(module)
        let none = try await groups(); XCTAssertEqual(none.count, 0, "\(none)")

        let entries = (try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? [])
            .compactMap { $0["entry"] as? String }
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        let (first, second) = (entries[0], entries[1])
        try await post("/v1/rename/function", ["address": first, "name": "UnpublishedProbeOne"])
        try await post("/v1/set/comment", ["address": first, "kind": "plate", "text": "probe"])
        try await post("/v1/set/comment", ["address": second, "kind": "plate", "text": "probe"])
        try await post("/v1/type", ["c": "typedef struct _UNPUBLISHED_PROBE { unsigned int Size; } UNPUBLISHED_PROBE;"])

        func check() async throws {
            let listed = try await groups()
            XCTAssertEqual(listed.count, 3, "\(listed)")
            let one = try XCTUnwrap(listed.first { $0["entry"] as? String == first }, "\(listed)")
            XCTAssertEqual(one["name"] as? String, "UnpublishedProbeOne")
            XCTAssertEqual(one["writes"] as? [String: Int], ["rename_function": 1, "set_comment": 1])
            let two = try XCTUnwrap(listed.first { $0["entry"] as? String == second }, "\(listed)")
            XCTAssertEqual(two["writes"] as? [String: Int], ["set_comment": 1])
            let types = try XCTUnwrap(listed.first { $0["module"] as? Bool == true }, "\(listed)")
            XCTAssertEqual(types["writes"] as? [String: Int], ["type": 1])
            let only = try await groups("?function=\(second)")
            XCTAssertEqual(only.count, 1)
            XCTAssertEqual(only.first?["entry"] as? String, second)
        }
        try await check()
        await host.stop(module)
        try await check()

        _ = try await host.publish(module, by: "agent")
        let after = try await groups(); XCTAssertEqual(after.count, 0, "\(after)")
    }
}
