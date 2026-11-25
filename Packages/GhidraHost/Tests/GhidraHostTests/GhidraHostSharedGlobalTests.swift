import XCTest
import CodeAnalysis
@testable import GhidraHost

/// A library function may read a module global of a shared type (issue
/// 5b6ade08): the registry keeps the type, and another module's function is
/// the entry's only where its own global has that type. On
/// `GHIDRA_LIBRARY_MODULES`, the two AMD SoC images.
final class GhidraHostSharedGlobalTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private struct Pair {
        var host: GhidraHost
        var store: ContentStore
        var modules: [SHA256Digest]
        var directory: URL
    }

    private func setUp(_ label: String) async throws -> Pair {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set to two modules")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostSharedGlobalTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostSharedGlobalTests",
                                                   ticketsFile: directory.appendingPathComponent("private/tickets.json")),
                              writer: store)
        var modules: [SHA256Digest] = []
        for (index, path) in paths.enumerated() {
            let image = try Data(contentsOf: URL(fileURLWithPath: String(path)))
            _ = try await host.createCached(module: image, name: "Module\(index)")
            try await host.take(SHA256Digest(data: image))
            modules.append(SHA256Digest(data: image))
        }
        return Pair(host: host, store: store, modules: modules, directory: directory)
    }

    /// The function both modules hold with one body, calling nothing and
    /// reading one global: its address in each, the global's address in each,
    /// and the offset of the instruction that reads it. On the AMD SoC pair it is
    /// one at 0x9A94F5B; the datum it reads is retyped for the test, whatever
    /// it is in the image.
    private struct Reader {
        var functions: [String]
        var globals: [String]
        var offset: String
        var size: Int
    }

    private func reader(_ pair: Pair) async throws -> Reader {
        var rows: [[String: [String: Any]]] = []
        for module in pair.modules {
            _ = try await pair.host.publish(module, by: "agent")
            let manifest = try XCTUnwrap(try pair.store.analysis(module: module))
            let list = try json(try pair.store.object(manifest.artifact.sha256))["functions"] as? [[String: Any]] ?? []
            var byBody: [String: [String: Any]] = [:]
            for function in list {
                guard let key = function["body"] as? String, !LibraryBody.isShort(key: key),
                      (function["callees"] as? [Any] ?? []).isEmpty,
                      (function["globals"] as? [[String: Any]])?.count == 1 else { continue }
                byBody[key] = byBody[key] == nil ? function : [:]
            }
            rows.append(byBody.filter { !$0.value.isEmpty })
        }
        let common = rows[0].keys.filter { rows[1][$0] != nil }.sorted {
            (rows[0][$0]?["size"] as? Int ?? 0) < (rows[0][$1]?["size"] as? Int ?? 0)
        }
        for key in common {
            var functions: [String] = [], globals: [String] = [], offset: String?
            for (row, module) in zip(rows, pair.modules) {
                let function = try XCTUnwrap(row[key])
                let entry = try XCTUnwrap(function["entry"] as? String)
                let global = try XCTUnwrap((function["globals"] as? [[String: Any]])?.first)
                offset = global["offset"] as? String
                let instructions = try json(await pair.host.read(module, "/v1/disassembly/\(entry)?limit=400"))["instructions"]
                    as? [[String: Any]] ?? []
                let start = try XCTUnwrap(CodeAddress(hex: entry)).value
                let reading = instructions.first {
                    CodeAddress(hex: $0["address"] as? String ?? "").map { String(format: "0x%llX", $0.value - start) } == offset
                }
                guard let to = (reading?["references"] as? [[String: Any]])?.first(where: { $0["type"] as? String != "CALL" })?["to"]
                    as? String else { break }
                functions.append(entry)
                globals.append(to)
            }
            if functions.count == 2, let offset {
                return Reader(functions: functions, globals: globals, offset: offset,
                              size: rows[0][key]?["size"] as? Int ?? 0)
            }
        }
        // The AMD SoC pair holds one: an exporter that does not say what a
        // body reads finds none, and that is a failure, not a skip.
        return try XCTUnwrap(nil as Reader?, "the two modules hold no common body that reads one global and calls nothing")
    }

    /// The review that makes a function a library candidate the registry
    /// takes: a plate, a comment on each step, every local named and typed,
    /// and a name.
    private func review(_ pair: Pair, _ module: SHA256Digest, _ entry: String) async throws {
        _ = try await pair.host.write(module, "/v1/set/comment", body: body([
            "address": entry, "kind": "plate", "text": "Reads the shared pointer and gives it back."]))
        let instructions = try json(await pair.host.read(module, "/v1/disassembly/\(entry)?limit=400"))["instructions"]
            as? [[String: Any]] ?? []
        for instruction in instructions {
            guard let at = instruction["address"] as? String else { continue }
            _ = try await pair.host.write(module, "/v1/set/comment", body: body([
                "address": at, "kind": "eol", "text": "step"]))
        }
        // Each local named by its storage, read again after each: a rename can move the others.
        var tried = Set<String>()
        for number in 0..<12 {
            let read = try json(await pair.host.read(module, "/v1/function/" + entry))
            guard let local = (read["locals"] as? [[String: Any]] ?? []).first(where: {
                !($0["name"] as? String ?? "").hasPrefix("Value") && !tried.contains($0["storage"] as? String ?? "")
            }), let storage = local["storage"] as? String else { break }
            tried.insert(storage)
            do {
                var change: [String: Any] = ["function": entry, "storage": storage, "name": "Value\(number)", "by": "agent"]
                let type = (local["type"] as? String ?? "")
                    .replacingOccurrences(of: "undefined1", with: "UINT8").replacingOccurrences(of: "undefined2", with: "UINT16")
                    .replacingOccurrences(of: "undefined4", with: "UINT32").replacingOccurrences(of: "undefined8", with: "UINT64")
                if type != local["type"] as? String { change["type"] = type }
                if let first = local["first_use"] as? String, storage.hasPrefix("HASH:") {
                    change["first_use"] = first
                } else {
                    change["shared"] = true
                }
                _ = try await pair.host.write(module, "/v1/rename/variable", body: body(change))
            } catch {
                // A slot that cannot be named alone is named with the one it shares.
            }
        }
        _ = try await pair.host.write(module, "/v1/rename/function", body: body([
            "address": entry, "name": "ProbeSharedGlobalReader", "by": "agent", "reason": "test"]))
    }

    private func type(_ pair: Pair, _ module: SHA256Digest, _ global: String, _ type: String?) async throws {
        var fields: [String: Any] = ["address": global, "name": "gProbeShared"]
        if let type { fields["type"] = type }
        _ = try await pair.host.write(module, "/v1/set/data", body: body(fields))
    }

    private func library(_ pair: Pair, _ module: SHA256Digest, _ entry: String) async throws -> [String: Any] {
        _ = try await pair.host.library(module, .init(action: .candidate, candidates: [.init(address: entry, kind: "edk2")]))
        let library = try json(await pair.host.read(module, "/v1/library"))
        let rows = (library["entries"] as? [[String: Any]] ?? []) + (library["below_bar"] as? [[String: Any]] ?? [])
        return try XCTUnwrap(rows.first { ($0["address"] as? String)?.uppercased() == entry.uppercased() }, "\(library)")
    }

    /// Typed `EFI_PEI_SERVICES **` in both modules: the global is no data
    /// reference, the body enters the registry with the type it reads, and the
    /// second module's function is the entry's.
    func testABodyReadingAGlobalOfASharedTypeEntersAndLinksInTheSecondModule() async throws {
        let pair = try await setUp("shared")
        defer { try? FileManager.default.removeItem(at: pair.directory) }
        defer { Task { for module in pair.modules { await pair.host.stop(module) } } }
        let found = try await reader(pair)
        for (module, global) in zip(pair.modules, found.globals) {
            try await type(pair, module, global, "EFI_PEI_SERVICES **")
        }
        try await review(pair, pair.modules[0], found.functions[0])
        let offered = try await library(pair, pair.modules[0], found.functions[0])
        XCTAssertEqual(offered["data_references"] as? [String], [], "\(offered)")
        let globals = try XCTUnwrap(offered["globals"] as? [[String: Any]], "\(offered)")
        XCTAssertEqual(globals.first?["shared"] as? Bool, true, "\(globals)")
        XCTAssertEqual(globals.first?["type"] as? String, "EFI_PEI_SERVICES * *", "\(globals)")

        let published = try await pair.host.publish(pair.modules[0], by: "agent")
        let added = try XCTUnwrap(published.library?.added.first, "\(String(describing: published.library))")
        let held = try XCTUnwrap(try pair.store.libraryIndex().entries[added.id])
        XCTAssertEqual(held.variants.first?.globals?.map(\.type), ["EFI_PEI_SERVICES * *"])
        XCTAssertEqual(held.variants.first?.globals?.map(\.offset), [found.offset])
        // Nothing of the module's place: the global is named, not addressed.
        let entry = String(decoding: try pair.store.object(held.entry), as: UTF8.self)
        XCTAssertFalse(entry.contains("DAT_"), entry)

        let (plan, _) = try await pair.host.libraryPlan(pair.modules[1])
        XCTAssertTrue(plan.toApply.contains { $0.address == found.functions[1] && $0.id == added.id },
                      "\(plan)")
        _ = try await pair.host.library(pair.modules[1], .init(action: .apply))
        _ = try await pair.host.publish(pair.modules[1], by: "agent")
        let manifest = try XCTUnwrap(try pair.store.analysis(module: pair.modules[1]))
        let list = try json(try pair.store.object(manifest.artifact.sha256))["functions"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.first { $0["entry"] as? String == found.functions[1] }?["registry"] as? String, added.id)
    }

    /// The same body, its global untyped in the second module: the entry does
    /// not apply there, and says which global and which type it wants.
    func testAnUntypedGlobalKeepsTheEntryFromTheSecondModule() async throws {
        let pair = try await setUp("untyped")
        defer { try? FileManager.default.removeItem(at: pair.directory) }
        defer { Task { for module in pair.modules { await pair.host.stop(module) } } }
        let found = try await reader(pair)
        try await type(pair, pair.modules[0], found.globals[0], "EFI_PEI_SERVICES **")
        try await type(pair, pair.modules[1], found.globals[1], nil)
        try await review(pair, pair.modules[0], found.functions[0])
        _ = try await library(pair, pair.modules[0], found.functions[0])
        let published = try await pair.host.publish(pair.modules[0], by: "agent")
        let added = try XCTUnwrap(published.library?.added.first, "\(String(describing: published.library))")

        let (plan, _) = try await pair.host.libraryPlan(pair.modules[1])
        XCTAssertFalse(plan.toApply.contains { $0.address == found.functions[1] }, "\(plan)")
        let refused = try XCTUnwrap(plan.candidates.first { $0.address == found.functions[1] && $0.id == added.id },
                                    "\(plan)")
        XCTAssertEqual(refused.state, "global")
        let why = refused.why ?? ""
        XCTAssertTrue(why.contains("gProbeShared") && why.contains("untyped") && why.contains("EFI_PEI_SERVICES * *"), why)

        // Its own review offered as the entry's body: refused with the same reason.
        try await review(pair, pair.modules[1], found.functions[1])
        _ = try await library(pair, pair.modules[1], found.functions[1])
        do {
            let second = try await pair.host.publish(pair.modules[1], by: "agent")
            let rows = LibraryRefusal.rows(of: try XCTUnwrap(second.library))
            XCTAssertTrue(rows.contains { $0.why.contains("untyped") && $0.why.contains("gProbeShared") }, "\(rows)")
        } catch {
            XCTAssertTrue("\(error)".contains("untyped") && "\(error)".contains("gProbeShared"), "\(error)")
        }
    }

    /// A global of a type only this program has is the module's data still.
    func testAGlobalOfAModuleOnlyTypeIsStillModuleData() async throws {
        let pair = try await setUp("own")
        defer { try? FileManager.default.removeItem(at: pair.directory) }
        defer { Task { for module in pair.modules { await pair.host.stop(module) } } }
        let found = try await reader(pair)
        _ = try await pair.host.write(pair.modules[0], "/v1/type", body: body([
            "c": "typedef struct { UINT32 ProbeOnlyHere; } PROBE_MODULE_ONLY;"]))
        try await type(pair, pair.modules[0], found.globals[0], "PROBE_MODULE_ONLY *")
        try await review(pair, pair.modules[0], found.functions[0])
        let offered = try await library(pair, pair.modules[0], found.functions[0])
        XCTAssertEqual(offered["data_references"] as? [String], [found.offset], "\(offered)")
        XCTAssertEqual((offered["globals"] as? [[String: Any]])?.first?["shared"] as? Bool, false, "\(offered)")
        // A data reference left: the registry refuses a new body for it, as before.
    }
}
