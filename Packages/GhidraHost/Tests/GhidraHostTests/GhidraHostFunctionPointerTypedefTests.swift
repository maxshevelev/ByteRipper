import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Issue 07cb5e92: `typedef R (*X)(...)` is a pointer typedef over the
/// function definition `/functions/X`, never a typedef of a pointer to
/// itself; a member declared `X *` points at that typedef.
final class GhidraHostFunctionPointerTypedefTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAFunctionPointerTypedefIsAPointerToItsSignature() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":").first else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostFunctionPointerTypedef-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "GhidraHostFunctionPointerTypedefTests"),
                              writer: store)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: String(path)))
        let module = SHA256Digest(data: bytes)
        _ = try await host.createCached(module: bytes, name: "Module")
        defer { Task { await host.stop(module) } }
        func type(_ body: [String: Any]) async throws -> [String: Any] {
            try await host.take(module)
            return try json(await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: body)))
        }
        func program(_ name: String) async throws -> [String: Any] {
            let read = try json(await host.read(module, "/v1/type?name=\(name)"))
            return try XCTUnwrap(read["program"] as? [String: Any], "\(read)")
        }

        // The exact text of the issue: variadic.
        let variadic = try await type(["c": "typedef VOID (*FABRIC_SRAT_MEMORY_RANGE_CALLBACK)(UINT8 **Cursor, UINT32 Domain, ...);"])
        let variadicC = variadic["c"] as? String ?? ""
        XCTAssertTrue(variadicC.contains("(*"), "a pointer to a signature: \(variadic)")
        XCTAssertTrue(variadicC.contains("Cursor"), "the signature's parameters: \(variadic)")
        XCTAssertFalse(variadicC.contains("FABRIC_SRAT_MEMORY_RANGE_CALLBACK * FABRIC_SRAT_MEMORY_RANGE_CALLBACK"),
                       "never a typedef of itself: \(variadic)")

        // Not variadic, then a structure using it by pointer and by value.
        let plain = try await type(["c": "typedef EFI_STATUS (*FPT_PLAIN_HOOK)(UINT32 Index, VOID *Context);"])
        let plainC = plain["c"] as? String ?? ""
        XCTAssertTrue(plainC.contains("(*") && plainC.contains("Index"), "a pointer to a signature: \(plain)")
        _ = try await type(["c": """
            typedef EFI_STATUS (*FPT_STRUCT_HOOK)(UINT32 Index, ...);
            typedef struct _FPT_HOOKS { FPT_STRUCT_HOOK *Hooks; FPT_STRUCT_HOOK Direct; FPT_PLAIN_HOOK *Plain; } FPT_HOOKS;
            """])
        let hook = try await program("FPT_STRUCT_HOOK")
        let hookC = hook["c"] as? String ?? ""
        XCTAssertTrue(hookC.contains("(*") && hookC.contains("Index"), "a pointer to a signature: \(hook)")
        let hooks = try await program("FPT_HOOKS")
        let fields = hooks["fields"] as? [[String: Any]] ?? []
        let types = Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            (field["name"] as? String).map { ($0, field["type"] as? String ?? "") }
        })
        XCTAssertEqual(types["Hooks"], "FPT_STRUCT_HOOK *", "\(hooks)")
        XCTAssertEqual(types["Direct"], "FPT_STRUCT_HOOK", "\(hooks)")
        XCTAssertEqual(types["Plain"], "FPT_PLAIN_HOOK *", "\(hooks)")
        let plainAfter = try await program("FPT_PLAIN_HOOK")
        XCTAssertTrue((plainAfter["c"] as? String ?? "").contains("Index"), "still the signature: \(plainAfter)")

        // The old answer taken back as C is refused, and the type stays.
        var refused = false
        do {
            let answer = try await type(["c": "typedef FPT_PLAIN_HOOK * FPT_PLAIN_HOOK;"])
            refused = (answer["c"] as? String ?? "").contains("Index") == false
            XCTAssertFalse(refused, "accepted only as a no-op: \(answer)")
        } catch {
            refused = true
            XCTAssertTrue("\(error)".contains("itself"), "\(error)")
        }
        let plainLast = try await program("FPT_PLAIN_HOOK")
        XCTAssertTrue((plainLast["c"] as? String ?? "").contains("Index"), "never a typedef of itself: \(plainLast)")
    }
}
