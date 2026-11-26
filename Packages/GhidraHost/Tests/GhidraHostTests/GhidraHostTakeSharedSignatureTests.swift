import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Issue d4011ad4: a program holding a function-pointer typedef
/// (`typedef R (*X)(...)`, Ghidra's typedef of `/functions/X *`) takes the
/// shared function signature `X` of the same name: the take answers, and a
/// member declared `X *` is then one pointer to the signature.
final class GhidraHostTakeSharedSignatureTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAFunctionPointerTypedefTakesTheSharedSignature() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count >= 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set to two modules")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostTakeSharedSignature-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "GhidraHostTakeSharedSignatureTests"),
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
        func definition(_ module: SHA256Digest, _ name: String) async throws -> [String: Any] {
            try json(await host.read(module, "/v1/type?name=\(name)"))
        }

        _ = try await type(writer, ["c": "typedef unsigned int TS_HOOK_FUNCTION(unsigned int HookId, void *Data, void *StdHeader);"])
        _ = try await host.publish(writer, by: "agent")

        _ = try await type(reader, ["c": "typedef unsigned int (*TS_HOOK_FUNCTION)(unsigned int HookId, void *Data, void *StdHeader);"])
        _ = try await type(reader, ["c": "typedef struct _TS_HOOK_ELEMENT { unsigned int HookId; TS_HOOK_FUNCTION *Function; TS_HOOK_FUNCTION Direct; } TS_HOOK_ELEMENT;"])
        _ = try await type(reader, ["name": "TS_HOOK_FUNCTION", "take_shared": true])
        let signatureRead = try await definition(reader, "TS_HOOK_FUNCTION")
        let elementRead = try await definition(reader, "TS_HOOK_ELEMENT")
        let signature = try XCTUnwrap(signatureRead["program"] as? [String: Any])
        let element = try XCTUnwrap(elementRead["program"] as? [String: Any])
        let signatureC = signature["c"] as? String ?? ""
        XCTAssertFalse(signatureC.contains("(*"), "the signature, not a pointer typedef: \(signature)")
        XCTAssertTrue(signatureC.contains("HookId"), "the shared prototype: \(signature)")
        XCTAssertEqual(signature["path"] as? String, "/TS_HOOK_FUNCTION", "in the typedef's place: \(signature)")
        XCTAssertEqual(signatureRead["same"] as? Int, 1, "the shared signature: \(signatureRead)")
        let fields = element["fields"] as? [[String: Any]] ?? []
        let types = Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            (field["name"] as? String).map { ($0, field["type"] as? String ?? "") }
        })
        XCTAssertEqual(types["Function"], "TS_HOOK_FUNCTION *", "one pointer to the signature: \(element)")
        XCTAssertEqual(types["Direct"], "TS_HOOK_FUNCTION *", "a member that held the typedef keeps a pointer: \(element)")
    }
}
