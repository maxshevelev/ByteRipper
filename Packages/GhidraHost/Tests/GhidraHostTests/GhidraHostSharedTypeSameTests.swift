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
}
