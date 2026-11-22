import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// The UEFI pass's typing run again over a reviewed module (the person's
/// decision of 2026-11-22): a variable a review named and left `int` gets the
/// type the code proves, keeps its name, and the module is published as a
/// revision of the run's own. Needs Ghidra and `GHIDRA_TYPE_MODULE`, an IA32
/// PEIM that reads the PEI Services pointer below the IDT.
final class GhidraHostRetypeTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAReviewedIdtBaseLeftUntypedIsTypedAndKeepsItsName() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostRetype-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostRetypeTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Probe")
        defer { Task { await host.stop(module) } }

        // The pass typed the IDT's base at create. A review that named it and
        // left it `int` is what the run is for.
        try await host.take(module)
        let functions = try json(await host.read(module, "/v1/functions?limit=500"))["functions"] as? [[String: Any]] ?? []
        var found: String?
        search: for function in functions {
            guard let entry = function["entry"] as? String else { continue }
            let read = try json(await host.read(module, "/v1/function/" + entry))
            guard (read["c"] as? String ?? "").contains("IdtBase[-1]") else { continue }
            for local in read["locals"] as? [[String: Any]] ?? [] where (local["name"] as? String) == "IdtBase" {
                _ = try await host.write(module, "/v1/rename/variable", body: JSONSerialization.data(withJSONObject: [
                    "function": entry, "storage": local["storage"] ?? "", "first_use": local["first_use"] ?? "",
                    "name": "IdtBase", "type": "int", "by": "agent"]))
                // A reviewed module: the review has written something.
                _ = try await host.write(module, "/v1/set/comment", body: JSONSerialization.data(withJSONObject: [
                    "address": entry, "kind": "plate", "text": "Reads the PEI Services pointer below the IDT."]))
                found = entry
                break search
            }
        }
        let entry = try XCTUnwrap(found, "the pass typed no IDT base at create")
        let untyped = try json(await host.read(module, "/v1/function/" + entry))["c"] as? String ?? ""
        XCTAssertFalse(untyped.contains("IdtBase[-1]"), untyped)
        XCTAssertTrue(untyped.contains("(code **)"), untyped)
        _ = try await host.release(module, by: "agent")

        let rows = try await host.retypeReviewed([module])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.outcome, "published", "\(row)")
        XCTAssertGreaterThan(row.typed, 0, "\(row)")
        XCTAssertLessThan(row.after ?? .max, row.before, "\(row)")
        XCTAssertNotNil(row.revision, "\(row)")
        let typed = try json(await host.read(module, "/v1/function/" + entry))
        let c = typed["c"] as? String ?? ""
        XCTAssertTrue(c.contains("IdtBase[-1]"), c)
        let local = (typed["locals"] as? [[String: Any]] ?? []).first { ($0["name"] as? String) == "IdtBase" }
        XCTAssertEqual(local?["type"] as? String, "EFI_PEI_SERVICES * * *", "\(local ?? [:])")

        // Nothing left to type: the next run publishes nothing.
        let again = try await host.retypeReviewed([module])
        XCTAssertEqual(again.first?.outcome, "unchanged", "\(again)")
        XCTAssertEqual(again.first?.typed, 0, "\(again)")
    }

    /// Issues 3eae8ad6 and 3a8ce8e7: a local a review named but left
    /// `undefined` is counted in `leftovers.locals`, and `local_list` says
    /// which one and how to reach it.
    func testLeftoversNameTheLocalTheyCount() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostLeftovers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostLeftovers"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Probe")
        defer { Task { await host.stop(module) } }
        try await host.take(module)
        let functions = try json(await host.read(module, "/v1/functions?limit=500"))["functions"] as? [[String: Any]] ?? []
        var named: (entry: String, storage: String)?
        search: for function in functions {
            guard let entry = function["entry"] as? String else { continue }
            let read = try json(await host.read(module, "/v1/function/" + entry))
            for local in read["locals"] as? [[String: Any]] ?? [] {
                guard let storage = local["storage"] as? String, storage.hasPrefix("Stack"),
                      (local["type"] as? String)?.hasPrefix("undefined") == true else { continue }
                // Named, and left `undefined` as a review might.
                // A stack slot has no first use: it is named by storage alone.
                var change: [String: Any] = ["function": entry, "storage": storage,
                                             "name": "ProbeValue", "by": "agent"]
                if let first = local["first_use"] as? String { change["first_use"] = first }
                // A slot the decompiler splits or merges refuses the name: try the next.
                guard (try? await host.write(module, "/v1/rename/variable",
                                             body: JSONSerialization.data(withJSONObject: change))) != nil else { continue }
                named = (entry, storage)
                break search
            }
        }
        let (entry, storage) = try XCTUnwrap(named, "no undefined local to name")
        let read = try json(await host.read(module, "/v1/function/" + entry))
        let leftovers = try XCTUnwrap(read["leftovers"] as? [String: Any], "\(read)")
        let list = leftovers["local_list"] as? [[String: Any]] ?? []
        let item = try XCTUnwrap(list.first { ($0["name"] as? String) == "ProbeValue" }, "\(leftovers)")
        XCTAssertEqual(item["why"] as? String, "untyped", "\(item)")
        XCTAssertEqual(item["storage"] as? String, storage, "\(item)")
        XCTAssertNotNil(item["type"] as? String, "\(item)")
        XCTAssertEqual(list.count, leftovers["locals"] as? Int, "\(leftovers)")
    }
}
