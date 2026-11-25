import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// `ghidra_type_definition`'s `same` compares the program's copy with the
/// shared one: a copy taken from the shared types by name and then defined
/// again with another layout is not the same (AMD_PSP_COMMON_SERVICE_PPI
/// read same:true at 0x28 against 0x18).
final class GhidraHostSharedTypeSameTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testACopyTakenByNameAndLaidOutAgainIsNotTheSame() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count >= 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set to two modules")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostSharedTypeSame-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "GhidraHostSharedTypeSameTests"),
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

        _ = try await type(writer, ["c": "typedef struct _SAME_PPI { unsigned int Size; void *Run; } SAME_PPI;"])
        _ = try await host.publish(writer, by: "agent")
        let taken = try await type(reader, ["name": "SAME_PPI"])
        XCTAssertEqual(taken["size"] as? Int, 8, "\(taken)")
        let read = try json(await host.read(reader, "/v1/type?name=SAME_PPI"))
        XCTAssertEqual(read["same"] as? Bool, true, "taken by name, it is the shared one: \(read)")

        _ = try await type(reader, ["c": "typedef struct _SAME_PPI { unsigned int Size; unsigned int Flags; void *Run; } SAME_PPI;"])
        let again = try json(await host.read(reader, "/v1/type?name=SAME_PPI"))
        let program = (again["program"] as? [String: Any])?["c"] as? String ?? ""
        let shared = (again["shared"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertNotEqual(program, shared)
        XCTAssertEqual(again["same"] as? Bool, false, "\(again)")
        do {
            _ = try await host.publish(reader, by: "agent")
            XCTFail("the old copy replaces the shared type")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
        }

        // `name` alone answers the program's own copy; `take_shared` puts the shared one in its place.
        let own = try await type(reader, ["name": "SAME_PPI"])
        XCTAssertEqual(own["size"] as? Int, 12, "\(own)")
        let shared2 = try await type(reader, ["name": "SAME_PPI", "take_shared": true])
        XCTAssertEqual(shared2["taken_from_shared"] as? Bool, true, "\(shared2)")
        XCTAssertEqual(shared2["size"] as? Int, 8, "\(shared2)")
        let after = try json(await host.read(reader, "/v1/type?name=SAME_PPI"))
        XCTAssertEqual(after["same"] as? Bool, true, "\(after)")
        _ = try await host.publish(reader, by: "agent")
    }

    /// `take_shared` of a structure whose member points at a function type
    /// the review named (IDS_HOOK_ENTRY's `IDS_HOOK_FUNCTION *Hook`) leaves the
    /// program as the shared archive has it: the member's type is not renamed
    /// after the structure and the field, which is only for the parser's
    /// `_func_N`.
    func testTakingASharedStructureKeepsItsNamedMemberFunctionType() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count >= 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set to two modules")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostSharedTypeSame-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "GhidraHostSharedTypeSameTests"),
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

        // The function type in a call of its own, as a review defines one: a
        // function definition, not a typedef of one.
        _ = try await type(writer, ["c": "typedef unsigned int (EFIAPI PROBE_HOOK_FUNCTION)(unsigned int HookId, unsigned int Reserved0);"])
        _ = try await type(writer, ["c": """
            typedef struct _PROBE_HOOK_ENTRY { unsigned int HookId; PROBE_HOOK_FUNCTION *Hook; } PROBE_HOOK_ENTRY;
            """])
        _ = try await host.publish(writer, by: "agent")
        let written = try json(await host.read(writer, "/v1/type?name=PROBE_HOOK_ENTRY"))
        let sharedC = (written["shared"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(sharedC.contains("PROBE_HOOK_FUNCTION * Hook"), "\(written)")
        // The reader's own copy has an inline member, named after the field.
        _ = try await type(reader, ["c": """
            typedef struct _PROBE_HOOK_ENTRY { unsigned int HookId; unsigned int (*Hook)(unsigned int HookId, unsigned int Reserved0); } PROBE_HOOK_ENTRY;
            """])
        let taken = try await type(reader, ["name": "PROBE_HOOK_ENTRY", "take_shared": true])
        XCTAssertEqual(taken["taken_from_shared"] as? Bool, true, "\(taken)")
        let after = try json(await host.read(reader, "/v1/type?name=PROBE_HOOK_ENTRY"))
        let program = (after["program"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(program.contains("PROBE_HOOK_FUNCTION * Hook"), "\(after)")
        XCTAssertEqual(after["same"] as? Bool, true, "\(after)")
    }

    /// Issue 764c15b7: the shared archive holds a structure's function members
    /// under its tag, `_TAG_PPI_Get`, as an older owner named them; a module
    /// that takes it and names the typedef has them renamed after the typedef
    /// at its publish. That is the archive's names normalised, not a conflict:
    /// the publish goes through, and the archive then reads the typedef's names
    /// with no `.conflict` copy.
    func testTakenMembersNamedAfterTheTagPublishUnderTheTypedefsNames() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count >= 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set to two modules")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostSharedTypeSame-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "GhidraHostSharedTypeSameTests"),
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

        // No typedef names the structure: its members are named after the tag.
        _ = try await type(writer, ["c": "struct _TAGSTEM_PPI { unsigned int (*Get)(void *This, unsigned int Index); };"])
        _ = try await host.publish(writer, by: "agent")
        let written = try json(await host.read(writer, "/v1/type?name=_TAGSTEM_PPI"))
        let sharedBefore = (written["shared"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(sharedBefore.contains("_TAGSTEM_PPI_Get"), "\(written)")

        let taken = try await type(reader, ["name": "_TAGSTEM_PPI", "take_shared": true])
        XCTAssertEqual(taken["taken_from_shared"] as? Bool, true, "\(taken)")
        _ = try await type(reader, ["c": "typedef struct _TAGSTEM_PPI TAGSTEM_PPI;"])
        _ = try await host.publish(reader, by: "agent")

        let after = try json(await host.read(reader, "/v1/type?name=_TAGSTEM_PPI"))
        let program = (after["program"] as? [String: Any])?["c"] as? String ?? ""
        let shared = (after["shared"] as? [String: Any])?["c"] as? String ?? ""
        XCTAssertTrue(program.contains("TAGSTEM_PPI_Get") && !program.contains("_TAGSTEM_PPI_Get"), "\(after)")
        XCTAssertTrue(shared.contains("TAGSTEM_PPI_Get") && !shared.contains("_TAGSTEM_PPI_Get"), "\(after)")
        XCTAssertFalse(shared.contains("conflict"), "\(after)")
        XCTAssertEqual(after["same"] as? Bool, true, "\(after)")
    }
}
