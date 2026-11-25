import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Issue 77b4ad63: two shared types that point at each other each refused a
/// withdrawal, the other one using it, so neither could ever go. Withdrawn as
/// one set they go together; a type outside the set still holds them.
final class GhidraHostWithdrawSetTests: XCTestCase {
    func testTypesPointingAtEachOtherAreWithdrawnAsOneSet() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostWithdrawSetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let projects = directory.appendingPathComponent("projects")
        let host = GhidraHost(configuration: .init(projectsRoot: projects, idle: 300,
                                                   holder: "GhidraHostWithdrawSetTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(module)
        defer { Task { await host.stop(module) } }
        let language = try json(await host.read(module, "/v1/hello"))["language"] as? String ?? ""
        let bits = GhidraHost.archiveBits(language: language)
        func versions() throws -> [TypeArchiveVersion] { try store.typeArchive(bits: bits)?.versions ?? [] }
        func define(_ c: String) async throws {
            _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["c": c]))
        }
        func withdraw(_ arguments: [String: Any]) async throws -> [String: Any] {
            var body = arguments
            body["delete"] = true
            body["shared"] = true
            body["reason"] = "a test set"
            return try json(await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: body)))
        }

        try await define("typedef struct _WS_MAP { int Start; int Size; } WS_MAP;")
        try await define("typedef struct _WS_DATA { struct _WS_INFO *Info; WS_MAP Map; } WS_DATA;")
        try await define("typedef struct _WS_INFO { WS_DATA *Data; int Count; } WS_INFO;")
        try await define("typedef struct _WS_OUTSIDE { WS_MAP *Map; } WS_OUTSIDE;")
        let published = try await host.publish(module, by: "agent")
        XCTAssertEqual(published.typeConflicts, [])
        let before = try versions().count

        // One at a time, each refuses for the other.
        for name in ["WS_DATA", "WS_INFO"] {
            do {
                _ = try await withdraw(["name": name])
                XCTFail("\(name) alone is used by its partner")
            } catch let error as GhidraHostError {
                XCTAssertEqual(error.status, 409, "\(error)")
            }
        }
        // A type outside the set holds a member: the whole set is refused.
        do {
            _ = try await withdraw(["names": ["WS_DATA", "WS_INFO", "WS_MAP"]])
            XCTFail("WS_OUTSIDE uses WS_MAP")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
            XCTAssertTrue("\(error)".contains("WS_OUTSIDE"), "\(error)")
        }
        XCTAssertEqual(try versions().count, before, "nothing withdrawn")

        // The closed cycle goes as one set, typedefs and tags together.
        let answer = try await withdraw(["names": ["WS_DATA", "WS_INFO"]])
        let gone = Set(answer["withdrawn"] as? [String] ?? [])
        XCTAssertEqual(gone, ["WS_DATA", "_WS_DATA", "WS_INFO", "_WS_INFO"], "\(answer)")
        let after = try versions()
        XCTAssertEqual(after.count, before + 1)
        XCTAssertTrue(after.last?.withdrawn.contains("WS_INFO") == true, "\(String(describing: after.last))")
        let shown = try json(await host.read(module, "/v1/type?name=WS_DATA"))
        XCTAssertNil(shown["shared"] as? [String: Any], "\(shown)")
        XCTAssertTrue("\(shown["withdrawn"] ?? "")".contains("Info"), "the record keeps the C as it was: \(shown)")

        // WS_MAP is still held by WS_OUTSIDE; with it in the set, both go.
        let rest = try await withdraw(["names": ["WS_MAP", "WS_OUTSIDE"]])
        XCTAssertEqual(Set(rest["withdrawn"] as? [String] ?? []), ["WS_MAP", "_WS_MAP", "WS_OUTSIDE", "_WS_OUTSIDE"])
        XCTAssertEqual(store.verify(), [])
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
