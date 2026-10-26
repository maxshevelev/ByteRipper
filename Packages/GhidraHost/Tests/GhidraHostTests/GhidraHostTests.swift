import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

final class GhidraHostUnitTests: XCTestCase {
    func testTheRecipeIsTheOnePythonNames() {
        let artifact: [String: Any] = ["script_version": 4, "ghidra": "12.1.2"]
        let typed = GhidraHost.recipe(for: artifact, types: "edk2-stable202608", passes: ["ApplyUefi.java"])
        XCTAssertEqual(typed.id, "code-v4-ghidra-12.1.2")
        XCTAssertEqual(typed.types, "edk2-stable202608")
        let plain = GhidraHost.recipe(for: artifact, types: nil, passes: [])
        XCTAssertEqual(plain.id, "code-v4-plain-ghidra-12.1.2")
        XCTAssertNil(plain.passes)
        XCTAssertEqual(GhidraHost.safeRecipe("12.1 beta/2"), "12.1-beta-2")
        XCTAssertEqual(GhidraHost.safeRecipe("///"), "unknown")
    }

    func testAStateWrittenByPythonReadsAndWritesBackTheSameFields() throws {
        let json = """
        {"schema": 1, "project": "p", "module": {"sha256": "ab", "size": 1, "name": "M", "kind": "TE", "phase": "pei"},
         "program": "M.pe", "made_with": {"ghidra": "12.1.2", "types": "edk2-stable202608", "passes": ["ApplyUefi.java"]},
         "source": {"path": "/tmp/M.te", "document": "d.bin", "node": "0.1"}, "created_at": "2026-10-26T13:34:27+00:00",
         "reviewed": true, "published": {"artifact": "aa", "recipe": "r", "review": "bb", "rev": 3, "at": "t"},
         "archive": "/x.gdt"}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        XCTAssertEqual(state.published?.rev, 3)
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(Set(again.keys), Set(original.keys))
    }
}

/// Against a real Ghidra and a copy of a kept project: skipped on a machine
/// with neither.
final class GhidraHostOwnerTests: XCTestCase {
    private var directory: URL!

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAnOwnerIsStartedReadWrittenPublishedAndStopped() async throws {
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let source = GhidraHost.defaultProjectsRoot
        guard let original = GhidraProject.all(in: source).first(where: { (try? $0.state().module.name) == "CpuPei" }) else {
            throw XCTSkip("no kept CpuPei project to copy")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostTests-\(UUID().uuidString)", isDirectory: true)
        let projects = directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let copy = projects.appendingPathComponent(original.module.hex)
        try FileManager.default.copyItem(at: original.folder, to: copy)
        try? FileManager.default.removeItem(at: copy.appendingPathComponent("owner.json"))
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: projects, idle: 120, holder: "GhidraHostTests"),
                              writer: store)
        let module = original.module

        let hello = try JSONSerialization.jsonObject(with: await host.read(module, "/v1/hello")) as! [String: Any]
        XCTAssertNotNil(hello["functions"])

        // A first publish of the copy: the program is as its last publish left it.
        let first = try await host.publish(module, by: "agent")
        let firstRev = first.manifest.reading?.rev

        let functions = try JSONSerialization.jsonObject(with: await host.read(module, "/v1/functions")) as! [String: Any]
        let list = try XCTUnwrap(functions["functions"] as? [[String: Any]])
        let entry = try XCTUnwrap(list.first?["entry"] as? String)
        let name = "HostTestName\(Int.random(in: 1000...9999))"
        _ = try await host.write(module, "/v1/rename/function",
                                 body: JSONSerialization.data(withJSONObject: ["address": entry, "name": name,
                                                                               "by": "agent"]))
        let released = try await host.release(module, by: "agent")
        let manifest = try XCTUnwrap(released?.manifest)
        XCTAssertEqual(manifest.reading?.rev, (firstRev ?? 0) + 1)
        let code = try store.artifact(for: manifest)
        XCTAssertTrue(code.functions.contains { $0.name == name })
        XCTAssertEqual(try store.reviewHistory(module: module)?.revisions.last?.rev, manifest.reading?.rev)

        // Publishing again with nothing changed is the same revision.
        let again = try await host.publish(module, by: "agent")
        XCTAssertEqual(again.manifest.reading?.rev, manifest.reading?.rev)
        XCTAssertEqual(store.verify(), [])

        let stopped = await host.stop(module)
        XCTAssertTrue(stopped)
        let summaries = await host.summaries()
        XCTAssertEqual(summaries.first?.running, false)
    }
}
