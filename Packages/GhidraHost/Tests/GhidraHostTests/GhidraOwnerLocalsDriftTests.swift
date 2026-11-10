import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Issue 4a9a4484's re-laid frames: a review document's local names, bound
/// to storages that moved, found again by their first use and put back under
/// the lease. A frame laid out again keeps each value's first use and moves
/// its storage; the document here records a name on a storage the program
/// does not have, at a first use it does, which is what such a document reads
/// like. Runs against `GHIDRA_TYPE_MODULE`, a 32-bit PEI module.
final class GhidraOwnerLocalsDriftTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerLocalsDrift-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerLocalsDriftTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
    }

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func read(_ path: String) async throws -> [String: Any] {
        try json(await host.read(module, path))
    }

    /// A function with three unnamed locals that each have a first use, and those locals.
    private func function() async throws -> (entry: String, locals: [[String: Any]]) {
        let functions = try await read("/v1/functions")["functions"] as? [[String: Any]] ?? []
        for row in functions {
            guard let entry = row["entry"] as? String else { continue }
            let locals = (try await read("/v1/function/\(entry)?summary=1")["locals"] as? [[String: Any]] ?? [])
                .filter { $0["first_use"] is String && ($0["named"] as? Bool) == false }
            var seen = Set<String>()
            let distinct = locals.filter { seen.insert($0["first_use"] as! String).inserted }
            let alone = distinct.filter { local in
                locals.filter { ($0["first_use"] as? String) == (local["first_use"] as? String) }.count == 1
            }
            if alone.count >= 3 { return (entry, Array(alone.prefix(3))) }
        }
        throw XCTSkip("no function with three locals of their own first use")
    }

    private func recorded(_ name: String, _ local: [String: Any], storage: String? = nil) -> [String: Any] {
        ["name": name, "storage": storage ?? local["storage"] as! String, "first_use": local["first_use"] as! String,
         "type": local["type"] as? String ?? "undefined4"]
    }

    private func drift(_ functions: [String: Any], apply: Bool) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["functions": functions])
        if apply {
            try await host.take(module)
            return try json(await host.write(module, "/v1/locals/remap", body: body))
        }
        return try json(await host.preview(module, "/v1/locals/drift", body: body))
    }

    private func items(_ answer: [String: Any]) -> [String: [String: Any]] {
        var byName: [String: [String: Any]] = [:]
        for function in answer["functions"] as? [[String: Any]] ?? [] {
            for local in function["locals"] as? [[String: Any]] ?? [] {
                byName[local["name"] as! String] = local
            }
        }
        return byName
    }

    /// The reference is a published review document, read from the store:
    /// the one just published reads intact, and the answer names it.
    func testThePublishedDocumentIsTheReference() async throws {
        let (entry, locals) = try await function()
        try await host.take(module)
        _ = try await host.write(module, "/v1/rename/variable", body: try JSONSerialization.data(withJSONObject: [
            "function": entry, "storage": locals[0]["storage"]!, "first_use": locals[0]["first_use"]!,
            "name": "PublishedName"]))
        let published = try await host.publish(module, by: "agent")
        let project = await host.project(module)
        let recipe = try XCTUnwrap(try project.state().published?.recipe)
        let answer = try json(await host.driftOfLocals(module, .init(recipe: recipe), holder: nil))
        let baseline = try XCTUnwrap(answer["baseline"] as? [String: Any], "\(answer)")
        XCTAssertEqual(baseline["rev"] as? Int, published.manifest.reading?.rev, "\(answer)")
        XCTAssertEqual(baseline["recipe"] as? String, recipe)
        XCTAssertEqual((answer["functions"] as? [Any])?.count, 0, "nothing moved: \(answer)")
        do {
            _ = try await host.driftOfLocals(module, .init(recipe: "code-v0-none"), holder: nil)
            XCTFail("a recipe never published is no reference")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 404, "\(error)")
        }
    }

    /// Two recorded names whose slots became one local: the one that holds
    /// it keeps it, the other is `merged` and goes nowhere.
    func testTwoNamesOnOneLocalNowAreMergedNotMoved() async throws {
        let (entry, locals) = try await function()
        try await host.take(module)
        _ = try await host.write(module, "/v1/rename/variable", body: try JSONSerialization.data(withJSONObject: [
            "function": entry, "storage": locals[0]["storage"]!, "first_use": locals[0]["first_use"]!,
            "name": "HeldName"]))
        let document: [String: Any] = [entry: ["locals": [
            recorded("HeldName", locals[0]),
            recorded("OtherHalf", locals[0], storage: "HASH:1234:4")
        ]]]
        let applied = try await drift(document, apply: true)
        XCTAssertEqual(items(applied)["OtherHalf"]?["status"] as? String, "merged", "\(applied)")
        let now = try await read("/v1/function/\(entry)?summary=1")["locals"] as? [[String: Any]] ?? []
        let there = now.filter { ($0["first_use"] as? String) == (locals[0]["first_use"] as? String) }
            .compactMap { $0["name"] as? String }
        XCTAssertTrue(there.contains("HeldName"), "\(now)")
        XCTAssertFalse(there.contains("OtherHalf"), "\(now)")
    }

    /// A function linked to a registry entry keeps the entry's names: its
    /// drift is `library_link`, with what it would be, and an apply renames
    /// nothing there.
    func testALinkedFunctionIsReportedAndNeverRenamed() async throws {
        let (entry, locals) = try await function()
        try await host.take(module)
        _ = try await host.write(module, "/v1/library/mark", body: try JSONSerialization.data(withJSONObject: [
            "items": [["address": entry, "id": "test-entry", "version": 1, "kind": "edk2"]]]), byHost: true)
        let document: [String: Any] = [entry: ["locals": [recorded("EntryName", locals[0], storage: "Stack[-0x7c]:4")]]]
        let applied = try await drift(document, apply: true)
        let function = (applied["functions"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual((function["library_link"] as? [String: Any])?["id"] as? String, "test-entry", "\(applied)")
        let item = items(applied)["EntryName"]
        XCTAssertEqual(item?["status"] as? String, "library_link", "\(applied)")
        XCTAssertEqual(item?["drift"] as? String, "moved", "\(applied)")
        let now = try await read("/v1/function/\(entry)?summary=1")["locals"] as? [[String: Any]] ?? []
        XCTAssertFalse(now.contains { ($0["name"] as? String) == "EntryName" }, "\(now)")
    }

    /// Issue 24c094eb: an entry's register local recorded on a storage the
    /// program no longer uses lands on the local of its first use, and
    /// nothing is added on the entry's storage; one whose first use no local
    /// starts at is reported.
    func testAnEntrysLocalLandsByFirstUseNotOnItsOldStorage() async throws {
        let (entry, locals) = try await function()
        let shown = try await read("/v1/function/\(entry)")
        let offset = { (local: [String: Any]) -> String in
            let at = UInt64((local["first_use"] as! String).dropFirst(2), radix: 16)!
            return String(format: "0x%llX", at - UInt64(entry.dropFirst(2), radix: 16)!)
        }
        let parameters = (shown["parameters"] as? [[String: Any]] ?? [])
            .map { ["name": $0["name"] ?? "", "type": $0["type"] ?? "", "storage": $0["storage"] ?? "", "ordinal": $0["ordinal"] ?? 0] }
        let item: [String: Any] = [
            "address": entry, "id": "1a-landing", "version": 1, "mode": "whole",
            "entry": ["name": shown["name"] ?? "", "signature": shown["signature"] ?? "",
                      "calling_convention": shown["calling_convention"] ?? "unknown", "params": parameters,
                      "locals": [
                        ["name": "LandedValue", "storage": "EDI:4", "first_use": offset(locals[0]),
                         "type": locals[0]["type"] as? String ?? "undefined4"],
                        ["name": "NowhereValue", "storage": "ESI:4", "first_use": "0x1", "type": "undefined4"]
                      ]] as [String: Any]]
        try await host.take(module)
        let applied = try json(await host.write(module, "/v1/library/apply",
                                                body: try JSONSerialization.data(withJSONObject: ["items": [item]]),
                                                byHost: true))
        let result = try XCTUnwrap((applied["items"] as? [[String: Any]])?.first, "\(applied)")
        let unplaced = (result["unplaced"] as? [String] ?? []).joined(separator: "\n")
        XCTAssertTrue(unplaced.contains("NowhereValue"), "\(result)")
        XCTAssertFalse(unplaced.contains("LandedValue"), "\(result)")
        let now = try await read("/v1/function/\(entry)?summary=1")["locals"] as? [[String: Any]] ?? []
        let landed = now.filter { ($0["name"] as? String) == "LandedValue" }
        XCTAssertEqual(landed.count, 1, "\(now)")
        XCTAssertEqual(landed.first?["first_use"] as? String, locals[0]["first_use"] as? String, "\(now)")
        XCTAssertFalse(now.contains { ($0["name"] as? String) == "NowhereValue" }, "never added: \(now)")
        XCTAssertFalse(now.contains { ($0["storage"] as? String) == "ESI:4" && ($0["named"] as? Bool) == true }, "\(now)")
    }

    /// A registry entry's locals against a function linked to it, by
    /// placement: the entry's storage at its first use is intact, another
    /// storage there is moved, a first use no local starts at is lost; names
    /// are not compared, and nothing is written.
    func testAnEntrysLocalsArePlacedAtItsLinkedFunctions() async throws {
        let (entry, locals) = try await function()
        try await host.take(module)
        _ = try await host.write(module, "/v1/library/mark", body: try JSONSerialization.data(withJSONObject: [
            "items": [["address": entry, "id": "test-entry", "version": 3, "kind": "edk2"]]]), byHost: true)
        let offset = { (local: [String: Any]) -> String in
            let at = UInt64((local["first_use"] as! String).dropFirst(2), radix: 16)!
            return String(format: "0x%llX", at - UInt64(entry.dropFirst(2), radix: 16)!)
        }
        let entryLocals: [[String: Any]] = [
            ["name": "SameSlot", "storage": locals[0]["storage"]!, "first_use": offset(locals[0]), "type": "undefined4"],
            ["name": "OldSlot", "storage": "EDI:4", "first_use": offset(locals[1]), "type": "undefined4"],
            ["name": "NoStart", "storage": "ESI:4", "first_use": "0x1", "type": "undefined4"],
            ["name": "NoFrameSlot", "storage": "Stack[-0x7c0]:4", "first_use": "0x0", "type": "undefined4"],
            // A first use before the entry, as Ghidra keeps an input register's: signed.
            ["name": "BeforeEntry", "storage": "CR4:8", "first_use": "0xFFFFFFFF", "type": "UINTN"]
        ]
        let body = try JSONSerialization.data(withJSONObject: ["entries": [
            "test-entry": ["version": 3, "locals": entryLocals],
            "other-entry": ["version": 1, "locals": entryLocals]]])
        let answer = try json(await host.preview(module, "/v1/locals/entries", body: body))
        XCTAssertEqual(answer["linked"] as? Int, 1, "\(answer)")
        let function = try XCTUnwrap((answer["functions"] as? [[String: Any]])?.first, "\(answer)")
        XCTAssertEqual(function["entry_version"] as? Int, 3)
        XCTAssertEqual((function["library_link"] as? [String: Any])?["id"] as? String, "test-entry")
        let byName = items(answer)
        XCTAssertNil(byName["SameSlot"], "intact is not listed: \(answer)")
        XCTAssertEqual(byName["OldSlot"]?["status"] as? String, "moved", "\(answer)")
        XCTAssertEqual((byName["OldSlot"]?["now"] as? [String: Any])?["storage"] as? String,
                       locals[1]["storage"] as? String, "\(answer)")
        XCTAssertEqual(byName["NoStart"]?["status"] as? String, "lost", "\(answer)")
        XCTAssertEqual(byName["NoFrameSlot"]?["status"] as? String, "lost", "\(answer)")
        let before = String(format: "0x%llX", UInt64(entry.dropFirst(2), radix: 16)! - 1)
        XCTAssertEqual(byName["BeforeEntry"]?["first_use"] as? String, before, "\(answer)")
        let now = try await read("/v1/function/\(entry)?summary=1")["locals"] as? [[String: Any]] ?? []
        XCTAssertFalse(now.contains { ["SameSlot", "OldSlot", "NoStart", "NoFrameSlot"].contains($0["name"] as? String ?? "") },
                       "nothing written: \(now)")
    }

    /// Through the host, the registry is read from the store, and an apply is refused.
    func testTheRegistryComparisonIsReadOnly() async throws {
        let answer = try json(await host.driftOfLocals(module, .init(registry: true), holder: nil))
        XCTAssertEqual(answer["linked"] as? Int, 0, "\(answer)")
        XCTAssertEqual((answer["registry"] as? [String: Any])?["entries_with_locals"] as? Int, 0, "\(answer)")
        do {
            _ = try await host.driftOfLocals(module, .init(apply: true, registry: true), holder: nil)
            XCTFail("a registry comparison is never applied")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 400, "\(error)")
        }
    }

    func testTheReferenceIsTheRecipeBeforeRevision3() {
        XCTAssertEqual(GhidraHost.recipeBeforeEFIAPI("code-v10-types3-ghidra-12.2-lang-descriptor-tables-1"),
                       "code-v10-types2-ghidra-12.2-lang-descriptor-tables-1")
        XCTAssertEqual(GhidraHost.recipeBeforeEFIAPI("code-v10-plain-ghidra-12.2"), "code-v10-plain-ghidra-12.2")
    }

    /// A name on a storage that moved is found by its first use and put back
    /// there; a name given after the document is a conflict and stays; a name
    /// left on a wrong slot is taken off it.
    func testANameAStorageLeftBehindGoesBackToItsFirstUse() async throws {
        let (entry, locals) = try await function()
        let (moved, later, wrongSlot) = (locals[0], locals[1], locals[2])
        // A name given after the document, on the local of the second first use.
        try await host.take(module)
        _ = try await host.write(module, "/v1/rename/variable", body: try JSONSerialization.data(withJSONObject: [
            "function": entry, "storage": later["storage"]!, "first_use": later["first_use"]!, "name": "GivenLater"]))
        // The document's name for the first local, left by the re-lay on the third.
        _ = try await host.write(module, "/v1/rename/variable", body: try JSONSerialization.data(withJSONObject: [
            "function": entry, "storage": wrongSlot["storage"]!, "first_use": wrongSlot["first_use"]!,
            "name": "DriftedValue"]))
        let document: [String: Any] = [entry: ["locals": [
            recorded("DriftedValue", moved, storage: "Stack[-0x7c]:4"),
            recorded("EarlierName", later, storage: "Stack[-0x78]:4")
        ]]]

        let seen = try await drift(document, apply: false)
        let before = items(seen)
        XCTAssertEqual(before["DriftedValue"]?["status"] as? String, "moved", "\(seen)")
        XCTAssertEqual(before["EarlierName"]?["status"] as? String, "conflict", "\(seen)")
        XCTAssertNotNil(before["DriftedValue"]?["name_now_on"], "where the name sits now: \(seen)")
        XCTAssertEqual(seen["applied"] as? Bool, false)

        let applied = try await drift(document, apply: true)
        let after = items(applied)
        XCTAssertEqual(after["DriftedValue"]?["restored"] as? Bool, true, "\(applied)")
        XCTAssertEqual(after["EarlierName"]?["status"] as? String, "conflict", "\(applied)")
        let counts = (applied["functions"] as? [[String: Any]])?.first?["counts"] as? [String: Any] ?? [:]
        XCTAssertEqual(counts["restored"] as? Int, 1, "\(applied)")
        XCTAssertEqual(counts["conflict"] as? Int, 1, "\(applied)")
        XCTAssertEqual(counts["cleared"] as? Int, 1, "the wrong slot is unnamed again: \(applied)")

        let now = try await read("/v1/function/\(entry)?summary=1")["locals"] as? [[String: Any]] ?? []
        func named(at local: [String: Any]) -> [String] {
            now.filter { ($0["first_use"] as? String) == (local["first_use"] as? String) && ($0["named"] as? Bool) == true }
                .compactMap { $0["name"] as? String }
        }
        XCTAssertEqual(named(at: moved), ["DriftedValue"], "\(now)")
        XCTAssertEqual(named(at: later), ["GivenLater"], "never overwritten: \(now)")
        XCTAssertEqual(named(at: wrongSlot), [], "\(now)")

        // Once put back, the same document reads intact.
        let again = try await drift(document, apply: false)
        XCTAssertNil(items(again)["DriftedValue"], "\(again)")
        // The conflict keeps the function listed; its intact local counts.
        XCTAssertEqual((again["totals"] as? [String: Any])?["intact"] as? Int, 1, "\(again)")
        // A document whose every name reads intact lists nothing and counts it.
        let whole = try await drift([entry: ["locals": [recorded("DriftedValue", moved)]]], apply: false)
        XCTAssertEqual((whole["functions"] as? [Any])?.count, 0, "\(whole)")
        XCTAssertEqual(whole["intact_functions"] as? Int, 1, "\(whole)")
        XCTAssertEqual((whole["totals"] as? [String: Any])?["intact"] as? Int, 1, "\(whole)")
    }
}
