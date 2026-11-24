import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Issue 78ba6eb8: a function typedef defined again by name, in a program that
/// holds it as the wrapper `typedef X X;` over `/functions/X`, is the
/// prototype afterwards, in the program and as the definition reads it.
final class GhidraHostFunctionTypedefWrapperTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAFunctionTypedefDefinedAgainReadsAsItsPrototype() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count >= 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set to two modules")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostFunctionTypedefWrapper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "GhidraHostFunctionTypedefWrapperTests"),
                              writer: store)
        let first = try Data(contentsOf: URL(fileURLWithPath: String(paths[0])))
        let second = try Data(contentsOf: URL(fileURLWithPath: String(paths[1])))
        let writer = SHA256Digest(data: first), reader = SHA256Digest(data: second)
        _ = try await host.createCached(module: first, name: "Writer")
        _ = try await host.createCached(module: second, name: "Reader")
        defer { Task { await host.stop(writer); await host.stop(reader) } }
        func type(_ module: SHA256Digest, _ body: [String: Any]) async throws -> [String: Any] {
            try await host.take(module)
            return try json(await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: body)))
        }
        func definition(_ module: SHA256Digest) async throws -> [String: Any] {
            try json(await host.read(module, "/v1/type?name=WRAP_GET_SIZE"))
        }

        _ = try await type(writer, ["c": "typedef unsigned int WRAP_GET_SIZE(void *This, unsigned int *Size);"])
        // What the archive holds from before ddb578ae: the wrapper over the definition.
        let wrapped = try await type(writer, ["c": "typedef WRAP_GET_SIZE WRAP_GET_SIZE;"])
        _ = try await type(writer, ["c": "typedef struct _WRAP_SIZE_PPI { WRAP_GET_SIZE *GetSize; } WRAP_SIZE_PPI;"])
        _ = try await host.publish(writer, by: "agent")
        _ = try await type(reader, ["name": "WRAP_SIZE_PPI", "take_shared": true])
        let before = try await definition(reader)

        _ = try await type(reader, ["c": "typedef unsigned int WRAP_GET_SIZE(void *This, unsigned long long *Size);"])
        let after = try await definition(reader)
        let program = try XCTUnwrap(after["program"] as? [String: Any])
        let c = program["c"] as? String ?? ""
        XCTAssertTrue(c.contains("("), "the prototype, not `typedef X X;`: \(after)")
        XCTAssertTrue(c.contains("ulonglong"), "the new prototype: \(after)")
    }
}
