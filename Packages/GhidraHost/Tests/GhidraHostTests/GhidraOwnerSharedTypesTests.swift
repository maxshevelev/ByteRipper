import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// An owner reads the shared review types as they are now, not as they were
/// when it started: another module's publish while it runs makes a version
/// its `take_shared` and its definitions see (issue 10a18abb, where a take
/// answered `taken_from_shared` with the version before). Needs Ghidra and
/// `GHIDRA_LIBRARY_MODULES`, the two AMD SoC images.
final class GhidraOwnerSharedTypesTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testARunningOwnerSeesATypeAnotherPublishShared() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerSharedTypes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraOwnerSharedTypesTests"),
                              writer: store)
        let images = try paths.map { try Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let reader = SHA256Digest(data: images[0]), writer = SHA256Digest(data: images[1])
        _ = try await host.createCached(module: images[0], name: "Reader")
        _ = try await host.createCached(module: images[1], name: "Writer")
        defer { Task { await host.stop(reader); await host.stop(writer) } }

        // The reader's owner is up before the type is shared.
        _ = try await host.read(reader, "/v1/hello")
        let before = try json(await host.read(reader, "/v1/type?name=PROBE_SHARED_RECORD"))
        XCTAssertNil(before["shared"], "\(before)")

        try await host.take(writer)
        _ = try await host.write(writer, "/v1/type", body: body([
            "c": "typedef struct _PROBE_SHARED_RECORD { UINT32 Signature; UINT32 Length; } PROBE_SHARED_RECORD;",
            "description": "A record only this test defines."]))
        _ = try await host.publish(writer, by: "agent")

        // Still the same owner: the shared side is the version just made.
        let after = try json(await host.read(reader, "/v1/type?name=PROBE_SHARED_RECORD"))
        let shared = try XCTUnwrap(after["shared"] as? [String: Any], "the running owner does not see it: \(after)")
        XCTAssertEqual((shared["fields"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Signature", "Length"])

        try await host.take(reader)
        let taken = try json(await host.write(reader, "/v1/type", body: body([
            "name": "PROBE_SHARED_RECORD", "take_shared": true])))
        XCTAssertEqual(taken["taken_from_shared"] as? Bool, true, "\(taken)")
        let now = try json(await host.read(reader, "/v1/type?name=PROBE_SHARED_RECORD"))
        XCTAssertEqual(now["same"] as? Bool, true, "\(now)")
    }
}
