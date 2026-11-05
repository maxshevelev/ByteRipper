import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A library function lives in the registry: a review proposes candidates, and a
/// publish takes them all to the registry in one revision, or stores nothing. What
/// the registry cannot hold is the module's. Needs Ghidra and `GHIDRA_TYPE_MODULE`.
final class GhidraHostCandidateTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func setUp(_ label: String) async throws -> (GhidraHost, ContentStore, SHA256Digest, URL) {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCandidateTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostCandidateTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try await host.create(module: image, name: "Module")
        return (host, store, SHA256Digest(data: image), directory)
    }

    private func functions(_ host: GhidraHost, _ module: SHA256Digest) async throws -> [[String: Any]] {
        try json(await host.read(module, "/v1/functions"))["functions"] as? [[String: Any]] ?? []
    }

    private func propose(_ host: GhidraHost, _ module: SHA256Digest, _ address: String) async throws {
        _ = try await host.library(module, .init(action: .candidate, candidates: [.init(address: address, kind: "edk2")]))
    }

    /// Proposed, and published: what the registry made of it.
    @discardableResult
    private func move(_ host: GhidraHost, _ module: SHA256Digest, _ address: String) async throws -> LibraryWriteResult {
        try await propose(host, module, address)
        let published = try await host.publish(module, by: "agent")
        return try XCTUnwrap(published.library)
    }

    private func storedRow(of entry: String, in store: ContentStore, module: SHA256Digest) throws -> [String: Any]? {
        let manifest = try XCTUnwrap(try store.analysis(module: module))
        let list = try json(try store.object(manifest.artifact.sha256))["functions"] as? [[String: Any]] ?? []
        return list.first { $0["entry"] as? String == entry }
    }

    private func level(of entry: String, in store: ContentStore, module: SHA256Digest) throws -> String? {
        let manifest = try XCTUnwrap(try store.analysis(module: module))
        let artifact = try json(try store.object(manifest.artifact.sha256))
        let list = artifact["functions"] as? [[String: Any]] ?? []
        return list.first { $0["entry"] as? String == entry }?["review_level"] as? String
    }

    /// A candidate the registry does not take stops the publish: nothing is
    /// stored, and it stays stopped until the review resolves it. Taken off the
    /// list, the function is the module's, and the module publishes.
    func testACandidateTheRegistryDoesNotTakeStopsThePublish() async throws {
        let (host, store, module, directory) = try await setUp("bar")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { await host.stop(module) } }
        let list = try await functions(host, module)
        let function = try XCTUnwrap(list.first { $0["size"] as? Int == 25 })
        let entry = try XCTUnwrap(function["entry"] as? String)
        let name = try XCTUnwrap(function["name"] as? String)
        try await propose(host, module, entry)
        let proposed = try json(await host.read(module, "/v1/function/\(entry)"))
        XCTAssertEqual((proposed["library_candidate"] as? [String: Any])?["kind"] as? String, "edk2")

        // Asking writes nothing, and says the same.
        let asked = try json(await host.publishPreview(module))
        XCTAssertTrue((asked["library_refused"] as? String)?.contains("\(name) at \(entry)") == true, "\(asked)")
        XCTAssertNil(try store.analysis(module: module))

        for _ in 0..<2 {
            do {
                _ = try await host.publish(module, by: "agent")
                XCTFail("short of the bar, the candidate stops the publish")
            } catch {
                XCTAssertTrue("\(error)".contains("\(name) at \(entry)"), "\(error)")
                XCTAssertTrue("\(error)".contains("short of the bar"), "\(error)")
                XCTAssertTrue("\(error)".contains("Nothing was stored"), "\(error)")
            }
            XCTAssertTrue(try store.libraryIndex().entries.isEmpty)
            XCTAssertNil(try store.analysis(module: module))
        }

        _ = try await host.library(module, .init(action: .candidate, remove: [entry]))
        let taken = try json(await host.read(module, "/v1/function/\(entry)"))
        XCTAssertNil(taken["library_candidate"])
        _ = try await host.publish(module, by: "agent")
        let row = try XCTUnwrap(try storedRow(of: entry, in: store, module: module))
        XCTAssertNil(row["registry"])
        XCTAssertNil(row["library_candidate"], "a candidate is the project's: no store holds it")
    }

    /// Candidates are gathered through a review and go in one publish, with one
    /// new revision, and no revision the store keeps names their text. A candidate
    /// alone is a change a done publishes.
    func testCandidatesGoInOnePublishWithOneRevision() async throws {
        let (host, store, module, directory) = try await setUp("one")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { await host.stop(module) } }
        let list = try await functions(host, module)
        let entry = try XCTUnwrap(list.first { $0["size"] as? Int == 25 }?["entry"] as? String)
        _ = try await host.write(module, "/v1/set/signature", body: body([
            "address": entry, "signature": "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)",
            "storage": ["ECX:4", "EDX:4"], "by": "agent", "reason": "EDK2 BaseLib CopyGuid"]))
        _ = try await host.write(module, "/v1/set/comment", body: body([
            "address": entry, "kind": "plate", "text": "EDK2 BaseLib CopyGuid: the words of the entry."]))
        _ = try await host.write(module, "/v1/set/comment", body: body([
            "address": entry, "kind": "eol", "text": "first dword of the GUID"]))
        _ = try await host.publish(module, by: "agent")
        let before = try XCTUnwrap(try store.analysis(module: module)?.reading?.rev)
        XCTAssertTrue(try store.libraryIndex().entries.isEmpty, "a publish with no candidate offers nothing")
        XCTAssertNotNil(try storedRow(of: entry, in: store, module: module)?["name"], "it is the module's so far")

        try await propose(host, module, entry)
        XCTAssertNotNil(try store.analysis(module: module)?.reading, "proposing stores nothing")
        XCTAssertEqual(try store.analysis(module: module)?.reading?.rev, before)
        XCTAssertTrue(try store.libraryIndex().entries.isEmpty)
        let asked = try json(await host.publishPreview(module))
        XCTAssertEqual(((asked["library"] as? [String: Any])?["added"] as? [[String: Any]])?.first?["name"] as? String, "CopyGuid", "\(asked)")
        XCTAssertTrue(try store.libraryIndex().entries.isEmpty, "asking writes nothing")

        let released = try await host.release(module, by: "agent")
        let published = try XCTUnwrap(released, "a candidate is a change")
        let id = try XCTUnwrap(published.library?.added.first?.id)
        let manifest = try XCTUnwrap(try store.analysis(module: module))
        XCTAssertEqual(manifest.reading?.rev, before + 1, "one publish, one revision")
        XCTAssertEqual(try storedRow(of: entry, in: store, module: module)?["registry"] as? String, id)
        let revision = try XCTUnwrap(try store.reviewHistory(module: module)?.revisions.last)
        XCTAssertEqual(revision.rev, before + 1)
        let text = String(decoding: try store.object(try XCTUnwrap(revision.artifact)), as: UTF8.self)
        XCTAssertFalse(text.contains("the words of the entry"), "no revision names the entry's text")
        XCTAssertFalse(text.contains("library_candidate"))
        let after = try json(await host.read(module, "/v1/function/\(entry)"))
        XCTAssertNil(after["library_candidate"])
    }

    /// A project from before candidates holds library tags. Its next publish takes
    /// them off: a function it links keeps the kind on its mark, and one with no
    /// entry is the module's, with nothing offered for it.
    func testAnOldTagInAProjectIsRetiredAtAPublish() async throws {
        let (host, store, module, directory) = try await setUp("tags")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { await host.stop(module) } }
        let list = try await functions(host, module)
        let entry = try XCTUnwrap(list.first { $0["size"] as? Int == 25 }?["entry"] as? String)
        await host.stop(module)
        let script = directory.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        try """
            import ghidra.app.script.GhidraScript;
            public class PlantTag extends GhidraScript {
                @Override public void run() throws Exception {
                    currentProgram.getFunctionManager().getFunctionAt(toAddr("\(entry)")).addTag("library.edk2");
                }
            }
            """.write(to: script.appendingPathComponent("PlantTag.java"), atomically: true, encoding: .utf8)
        let install = try GhidraInstall.find()
        let project = GhidraProject(root: directory.appendingPathComponent("projects"), module: module)
        let log = directory.appendingPathComponent("plant.log")
        let status = try Subprocess.run(install.analyzeHeadless,
            [project.folder.path, GhidraProject.name, "-process", "-noanalysis",
             "-scriptPath", script.path, "-postScript", "PlantTag.java"],
            log: log, timeout: 600, environment: install.environment)
        XCTAssertEqual(status, 0, (try? String(contentsOf: log, encoding: .utf8)) ?? "")

        let planted = try json(await host.read(module, "/v1/function/\(entry)"))
        XCTAssertEqual(planted["tags"] as? [String], ["library.edk2"])
        _ = try await host.write(module, "/v1/set/comment", body: body([
            "address": entry, "kind": "plate", "text": "A word, so that something is published."]))
        _ = try await host.publish(module, by: "agent")
        let retired = try json(await host.read(module, "/v1/function/\(entry)"))
        XCTAssertEqual(retired["tags"] as? [String], [])
        XCTAssertTrue(try store.libraryIndex().entries.isEmpty, "an old tag offers nothing")
        XCTAssertNil(try storedRow(of: entry, in: store, module: module)?["registry"])
    }

    /// The whole of a move, on two real modules: reviewed, moved, and then no
    /// module stores the function's name or text; the other holder links at once,
    /// in the store, before anyone opens it.
    func testAMoveLeavesNoTextInAnyModule() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCandidateTests-whole-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostCandidateTests"),
                              writer: store)
        let images = try paths.map { try Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let reviewed = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.create(module: images[0], name: "Reviewed")
        _ = try await host.create(module: images[1], name: "Other")
        defer { Task { await host.stop(reviewed); await host.stop(other) } }
        let ours = try await functions(host, reviewed), theirs = try await functions(host, other)
        let copyGuid = try XCTUnwrap(ours.first { $0["size"] as? Int == 25 }?["entry"] as? String)
        let holder = try XCTUnwrap(theirs.first { $0["size"] as? Int == 25 }?["entry"] as? String)

        // The other module holds its own words on the same body, stored, before any entry.
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": holder, "kind": "plate", "text": "The holder's words on this body."]))
        _ = try await host.publish(other, by: "agent")
        XCTAssertEqual(try storedRow(of: holder, in: store, module: other)?["registry"] as? String, nil)
        let heldBefore = try XCTUnwrap(try store.analysis(module: other))
        XCTAssertTrue(String(decoding: try store.object(try XCTUnwrap(heldBefore.reading?.review)), as: UTF8.self)
            .contains("The holder's words"))

        _ = try await host.write(reviewed, "/v1/set/signature", body: body([
            "address": copyGuid, "signature": "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)",
            "storage": ["ECX:4", "EDX:4"], "by": "agent", "reason": "EDK2 BaseLib CopyGuid"]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "plate", "text": "EDK2 BaseLib CopyGuid: the plate of the entry."]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "eol", "text": "first dword of the GUID"]))

        let moved = try await move(host, reviewed, copyGuid)
        let id = try XCTUnwrap(moved.added.first?.id)
        for (module, address) in [(reviewed, copyGuid), (other, holder)] {
            let row = try XCTUnwrap(try storedRow(of: address, in: store, module: module))
            XCTAssertEqual(row["registry"] as? String, id, "\(row.keys.sorted())")
            for field in ["name", "signature", "c", "c_spans", "name_reason", "review_level", "library_kind", "library_entry"] {
                XCTAssertNil(row[field], field)
            }
            let manifest = try XCTUnwrap(try store.analysis(module: module))
            let whole = String(decoding: try store.object(manifest.artifact.sha256), as: UTF8.self)
            XCTAssertFalse(whole.contains("the plate of the entry"))
            XCTAssertFalse(whole.contains("The holder's words"))
            if let review = manifest.reading?.review {
                let document = String(decoding: try store.object(review), as: UTF8.self)
                XCTAssertFalse(document.contains("the plate of the entry"))
                XCTAssertFalse(document.contains("The holder's words"))
            }
            // A reader gets the entry, in either module.
            let shown = try store.artifactToShow(for: manifest)
            let read = try XCTUnwrap(shown.functions.first { $0.entry == CodeAddress(hex: address) })
            XCTAssertEqual(read.name, "CopyGuid")
            XCTAssertEqual(read.reviewLevel, .library)
            // The instructions are the registry's too: the module holds none, and a
            // reader gets exactly what Ghidra shows at this module's addresses.
            XCTAssertNil(row["instructions"])
            let code = try XCTUnwrap(store.artifact(for: manifest).functions.first { $0.entry == CodeAddress(hex: address) }).instructions
            XCTAssertFalse(code.isEmpty)
            let real = try json(await host.read(module, "/v1/disassembly/\(address)?limit=\(code.count)"))
            let rows = try XCTUnwrap(real["instructions"] as? [[String: Any]])
            XCTAssertEqual(code.map { $0.address.description }, rows.compactMap { $0["address"] as? String })
            XCTAssertEqual(code.map { $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") },
                           rows.compactMap { ($0["bytes"] as? String)?.uppercased() })
            XCTAssertEqual(code.map(\.text), rows.compactMap { $0["text"] as? String })
        }
        XCTAssertEqual(try store.relinkModules(dryRun: true), [])
        XCTAssertEqual(try store.libraryHoldings().map(\.ownBodiesInRegistry), [0, 0])
        XCTAssertEqual(try store.libraryHoldings().map(\.outOfFormat), [0, 0])

        // The holder's next publish replaces the rewritten analysis without a fuss,
        // and a second move of the same body has nothing to add.
        _ = try await host.library(other, .init(action: .apply))
        let again = try await host.publish(other, by: "agent")
        XCTAssertNil(again.libraryError)
        XCTAssertEqual(try store.libraryIndex().entries[id]?.version, 1)
        XCTAssertEqual(try storedRow(of: holder, in: store, module: other)?["registry"] as? String, id)
        // Bound and not dirty, its own words offer nothing and stay in its project;
        // so do the reviewed module's. A publish cleans no project.
        XCTAssertEqual(again.library?.conflicts.count ?? 0, 0)
        XCTAssertEqual(again.library?.updated.count ?? 0, 0)
        let holderRaw = try json(await host.read(other, "/v1/function/\(holder)"))
        XCTAssertEqual(holderRaw["plate"] as? String, "The holder's words on this body.")
        let sourceRaw = try json(await host.read(reviewed, "/v1/function/\(copyGuid)"))
        XCTAssertEqual(sourceRaw["plate"] as? String, "EDK2 BaseLib CopyGuid: the plate of the entry.")
        XCTAssertEqual((sourceRaw["comments"] as? [[String: Any]])?.first?["text"] as? String, "first dword of the GUID")

        // A function the registry holds is no candidate.
        do {
            try await propose(host, other, holder)
            XCTFail("a registry function was proposed")
        } catch {
            XCTAssertTrue("\(error)".contains(id) && "\(error)".contains("no candidate"), "\(error)")
        }
    }

    /// A body under Function ID's four instructions: the review names, comments
    /// and moves it, and another module's review binds it.
    func testAShortBodyMovesToTheRegistryAndIsBoundByAReview() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCandidateTests-short-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostCandidateTests"),
                              writer: store)
        let images = try paths.map { try Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let reviewed = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.create(module: images[0], name: "Reviewed")
        _ = try await host.create(module: images[1], name: "Other")
        defer { Task { await host.stop(reviewed); await host.stop(other) } }

        // The same few bytes, as a short function of both modules.
        func short(_ module: SHA256Digest) async throws -> [(entry: String, bytes: String)] {
            var found: [(entry: String, bytes: String)] = []
            let rows = try await functions(host, module)
            for row in rows where (row["size"] as? Int ?? 99) <= 8 && row["thunk"] as? Bool != true {
                guard let entry = row["entry"] as? String, let size = row["size"] as? Int,
                      let start = UInt64(entry.dropFirst(2), radix: 16) else { continue }
                let read = try json(await host.read(module, "/v1/disassembly/\(entry)?limit=4"))
                let units = (read["instructions"] as? [[String: Any]] ?? []).filter {
                    guard let at = ($0["address"] as? String).flatMap({ UInt64($0.dropFirst(2), radix: 16) }) else { return false }
                    return at < start + UInt64(size)
                }
                guard units.count < 4 else { continue }
                found.append((entry, units.compactMap { $0["bytes"] as? String }.joined(separator: " ")))
            }
            return found
        }
        let ours = try await short(reviewed), theirs = try await short(other)
        let pair = try XCTUnwrap(ours.lazy.compactMap { one in
            theirs.first { $0.bytes == one.bytes }.map { (one.entry, $0.entry) }
        }.first, "\(ours) \(theirs)")

        _ = try await host.write(reviewed, "/v1/rename/function", body: body([
            "address": pair.0, "name": "ShortBodyForTheTest", "by": "agent", "reason": "named for the test"]))
        do {
            try await move(host, reviewed, pair.0)
            XCTFail("short of the bar, it does not go")
        } catch {
            XCTAssertTrue("\(error)".contains("ShortBodyForTheTest"), "\(error)")
            XCTAssertTrue("\(error)".contains("short of the bar"), "\(error)")
        }
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": pair.0, "kind": "plate", "text": "A short library routine, for the test."]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": pair.0, "kind": "pre", "text": "Its one step."]))
        // A dry run counts the links the publish will store, the short body
        // the registry is about to take among them.
        try await propose(host, reviewed, pair.0)
        let dry = try json(await host.preview(reviewed))
        let moved = try await move(host, reviewed, pair.0)
        let id = try XCTUnwrap(moved.added.first { $0.name == "ShortBodyForTheTest" }?.id, "\(moved)")
        XCTAssertEqual(try storedRow(of: pair.0, in: store, module: reviewed)?["registry"] as? String, id)
        let links = try json(try store.object(try XCTUnwrap(try store.analysis(module: reviewed)).artifact.sha256))["functions"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(dry["links"] as? Int, links.filter { $0["registry"] != nil }.count, "\(dry)")
        XCTAssertLessThan(try XCTUnwrap(Int(id.split(separator: "-")[0], radix: 16)), 4, id)

        // Nothing links by itself: the entry is a candidate, and the review binds it.
        let plain = try json(await host.library(other, .init(action: .apply)))
        let results = plain["results"] as? [[String: Any]] ?? []
        XCTAssertFalse(results.contains { $0["address"] as? String == pair.1 }, "\(plain)")
        let status = try json(await host.library(other, .init(action: .status)))
        let candidates = status["candidates"] as? [[String: Any]] ?? []
        let candidate = candidates.first { $0["address"] as? String == pair.1 && $0["id"] as? String == id }
        XCTAssertEqual(candidate?["state"] as? String, "short_candidate", "\(status)")
        XCTAssertEqual(candidate?["entry_name"] as? String ?? candidate?["name"] as? String != nil, true, "\(status)")

        let bound = try json(await host.library(other, .init(action: .apply, address: pair.1, id: id)))
        let row = (bound["results"] as? [[String: Any]] ?? []).first
        XCTAssertEqual(row?["marked"] as? Bool, true, "\(bound)")

        // A rename replaces what the entry says, so it is an administrator's
        // decision. It is the entry's next version: the id and the bytes stay, and
        // the function stays bound in both modules.
        _ = try await host.publish(other, by: "agent")
        _ = try await host.write(reviewed, "/v1/rename/function", body: body([
            "address": pair.0, "name": "ShortBodyRenamed", "by": "agent", "reason": "the review knows better"]))
        let renamed = try await host.publish(reviewed, by: "agent", options: .init(
            takeLibrary: .these([id: "the review knows better"])))
        XCTAssertEqual(renamed.library?.updated.map(\.id), [id], "\(String(describing: renamed.library))")
        let held = try store.libraryIndex().entries[id]
        XCTAssertEqual(held?.name, "ShortBodyRenamed")
        XCTAssertEqual(held?.variants.count, 1)
        // A reader of the other module reads the new name from the entry, at once.
        let shown = try store.artifactToShow(for: try XCTUnwrap(try store.analysis(module: other)))
        let there = shown.functions.first { $0.entry == CodeAddress(hex: pair.1) }
        XCTAssertEqual(there?.name, "ShortBodyRenamed")
    }

    /// A thunk has no body: it does not move. `PeiVariable` holds one.
    func testAThunkDoesNotMove() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_THUNK_MODULE"] else {
            throw XCTSkip("GHIDRA_THUNK_MODULE is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCandidateTests-thunk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostCandidateTests"),
                              writer: store)
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Thunks")
        defer { Task { await host.stop(module) } }
        let list = try await functions(host, module)
        _ = list
        let exported = try json(await host.write(module, "/v1/export", body: Data()))
        let thunk = try XCTUnwrap((exported["functions"] as? [[String: Any]])?.first { $0["thunk"] as? Bool == true }?["entry"] as? String)
        do {
            try await move(host, module, thunk)
            XCTFail("a thunk has no body")
        } catch {
            XCTAssertTrue("\(error)".contains("no body"), "\(error)")
        }
        XCTAssertTrue(try store.libraryIndex().entries.isEmpty)
    }

    func testANameOnTheOldListDoesNotMakeALibraryFunction() async throws {
        let (host, store, module, directory) = try await setUp("name")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { await host.stop(module) } }
        let list = try await functions(host, module)
        let function = try XCTUnwrap(list.first { $0["size"] as? Int == 25 })
        let entry = try XCTUnwrap(function["entry"] as? String)
        _ = try await host.write(module, "/v1/rename/function", body: body([
            "address": entry, "name": "CpuPause", "by": "agent", "reason": "named for the test"]))
        let read = try json(await host.read(module, "/v1/function/\(entry)"))
        XCTAssertNil(read["library"], "\(read)")
        _ = try await host.publish(module, by: "agent")
        XCTAssertNotEqual(try level(of: entry, in: store, module: module), "library")
    }

    /// Entries a module only links are not a review of it: the field says false
    /// until the module's own review writes something.
    func testAModuleThatOnlyLinksEntriesIsNotReviewed() async throws {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCandidateTests-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostCandidateTests"),
                              writer: store)
        let images = try paths.map { try Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let reviewed = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.create(module: images[0], name: "Reviewed")
        _ = try await host.create(module: images[1], name: "Other")
        defer { Task { await host.stop(reviewed); await host.stop(other) } }

        let list = try await functions(host, reviewed)
        let copyGuid = try XCTUnwrap(list.first { $0["size"] as? Int == 25 }?["entry"] as? String)
        _ = try await host.write(reviewed, "/v1/set/signature", body: body([
            "address": copyGuid, "signature": "EFI_GUID * CopyGuid(EFI_GUID * DestinationGuid, EFI_GUID * SourceGuid)",
            "storage": ["ECX:4", "EDX:4"], "by": "agent", "reason": "EDK2 BaseLib CopyGuid"]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "plate", "text": "EDK2 BaseLib CopyGuid: the plate of the entry."]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": copyGuid, "kind": "eol", "text": "first dword of the GUID"]))
        try await move(host, reviewed, copyGuid)

        _ = try await host.library(other, .init(action: .apply))
        func field() async throws -> Bool? {
            await host.summaries().first { $0.module == other.hex }?.reviewed
        }
        let afterLinks = try await field()
        XCTAssertEqual(afterLinks, false)
        let preview = try json(await host.publishPreview(other))
        XCTAssertEqual(preview["reviewed"] as? Bool, false, "\(preview)")
        let linked = try await host.publish(other, by: "agent")
        let afterPublish = try await field()
        XCTAssertEqual(afterPublish, false)

        let theirs = try await functions(host, other)
        let own = try XCTUnwrap(theirs.first { $0["size"] as? Int != 25 && ($0["size"] as? Int ?? 0) > 16 }?["entry"] as? String)
        _ = try await host.write(other, "/v1/set/comment", body: body(["address": own, "kind": "plate", "text": "This module's own."]))
        _ = try await host.publish(other, by: "agent")
        let afterReview = try await field()
        XCTAssertEqual(afterReview, true)
    }

    /// Function ID's plate on a fresh project: `__aullshr` in both Fp6 modules.
    private func aullshrInBoth() async throws -> (GhidraHost, ContentStore, SHA256Digest, SHA256Digest, String, String, String, URL) {
        guard let paths = ProcessInfo.processInfo.environment["GHIDRA_LIBRARY_MODULES"]?.split(separator: ":"),
              paths.count == 2 else {
            throw XCTSkip("GHIDRA_LIBRARY_MODULES is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostCandidateTests-fid-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostCandidateTests"),
                              writer: store)
        let images = try paths.map { try Data(contentsOf: URL(fileURLWithPath: String($0))) }
        let reviewed = SHA256Digest(data: images[0]), other = SHA256Digest(data: images[1])
        _ = try await host.create(module: images[0], name: "Reviewed")
        _ = try await host.create(module: images[1], name: "Other")
        let ours = try await functions(host, reviewed), theirs = try await functions(host, other)
        let source = try XCTUnwrap(ours.first { $0["name"] as? String == "__aullshr" }?["entry"] as? String)
        let target = try XCTUnwrap(theirs.first { $0["name"] as? String == "__aullshr" }?["entry"] as? String)

        let plate = try json(await host.read(other, "/v1/function/\(target)"))["plate"] as? String
        XCTAssertTrue(plate?.hasPrefix("Library Function") == true, "\(String(describing: plate))")

        // As analysis left it, Function ID's plate is no review's: it does not go.
        do {
            try await move(host, reviewed, source)
            XCTFail("Function ID's plate is no review")
        } catch {
            XCTAssertTrue("\(error)".contains("plate"), "\(error)")
        }

        _ = try await host.write(reviewed, "/v1/set/signature", body: body([
            "address": source, "signature": "UINT64 __aullshr(UINT8 ShiftCount, UINT64 Value)",
            "storage": ["CL:1", "EDX:4,EAX:4"], "by": "agent", "reason": "MSVC runtime"]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": source, "kind": "plate", "text": "MSVC runtime: a 64-bit logical shift right."]))
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": source, "kind": "pre", "text": "The shift count is in CL."]))
        let moved = try await move(host, reviewed, source)
        let id = try XCTUnwrap(moved.added.first { $0.name == "__aullshr" }?.id, "\(moved)")
        return (host, store, reviewed, other, source, target, id, directory)
    }

    func testAPlateFunctionIDWroteDoesNotKeepAWholeMatchFromLinking() async throws {
        let (host, _, reviewed, other, _, target, id, directory) = try await aullshrInBoth()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { await host.stop(reviewed); await host.stop(other) } }
        let applied = try json(await host.library(other, .init(action: .apply)))
        let row = (applied["results"] as? [[String: Any]] ?? []).first { $0["address"] as? String == target }
        XCTAssertEqual(row?["marked"] as? Bool, true, "\(applied)")
        XCTAssertEqual(row?["mode"] as? String, "link", "\(applied)")
        XCTAssertEqual(row?["id"] as? String, id)
        let preview = try json(await host.publishPreview(other))
        XCTAssertNil(preview["library_refused"], "\(preview)")
    }

    /// A body taken out of the registry is the module's function again: it takes
    /// the entry's text as its own, and the next publish stores that, with no link.
    /// An entry from before entries held their function — one a take-out kept
    /// and a restore brought back — as the registry's index lists it.
    private func withoutItsFunction(_ id: String, in store: ContentStore, directory: URL) throws {
        let url = directory.appendingPathComponent("store/library/index.json")
        var index = try json(try Data(contentsOf: url))
        var entries = try XCTUnwrap(index["entries"] as? [String: Any])
        var row = try XCTUnwrap(entries[id] as? [String: Any])
        let held = try XCTUnwrap(SHA256Digest(hex: try XCTUnwrap(row["entry"] as? String)))
        var object = try json(try store.object(held))
        XCTAssertNotNil(object["function"])
        object["function"] = nil
        object["equates"] = nil
        row["entry"] = try store.putObject(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).hex
        entries[id] = row
        index["entries"] = entries
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: url)
    }

    /// A link reads its entry's text. A module that links to an entry holding
    /// no C, with its own review of the function differing from the entry's, is
    /// refused: its C would carry what nobody took. Brought to the entry's text,
    /// it records its C there in the same publish — no version moves — and
    /// stores a link: no stored analysis holds the function's text.
    func testALinkToAnEntryWithNoCRecordsTheModulesCOnlyAsTheEntrysReview() async throws {
        let (host, store, reviewed, other, _, target, id, directory) = try await aullshrInBoth()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { await host.stop(reviewed); await host.stop(other) } }
        let applied = try json(await host.library(other, .init(action: .apply)))
        let row = (applied["results"] as? [[String: Any]] ?? []).first { $0["address"] as? String == target }
        XCTAssertEqual(row?["marked"] as? Bool, true, "\(applied)")
        try withoutItsFunction(id, in: store, directory: directory)
        let before = try XCTUnwrap(try store.libraryIndex().entries[id])
        // Something of the module's own, so the publish is a review's.
        let theirs = try await functions(host, other)
        let own = try XCTUnwrap(theirs.first { $0["name"] as? String != "__aullshr" }?["entry"] as? String)
        _ = try await host.write(other, "/v1/set/comment", body: body([
            "address": own, "kind": "pre", "text": "A step of the module's own."]))
        let storedBefore = try store.analysis(module: other)?.artifact

        // Function ID's plate is this module's text of it: short of the bar, it offers nothing the entry could record.
        let preview = try json(await host.publishPreview(other))
        let said = try XCTUnwrap(preview["library_refused"] as? String, "\(preview)")
        XCTAssertTrue(said.contains("__aullshr") && said.contains("holds no C") && said.contains("take_text"), said)
        do {
            _ = try await host.publish(other, by: "agent")
            XCTFail("a link to an entry with no C, its review differing, stores nothing")
        } catch {
            XCTAssertTrue("\(error)".contains("holds no C"), "\(error)")
        }
        XCTAssertEqual(try store.analysis(module: other)?.artifact, storedBefore, "nothing was stored")
        XCTAssertNil(try json(try store.object(try XCTUnwrap(try store.libraryIndex().entries[id]).entry))["function"])

        // The entry's text taken, the module's review of it is the entry's.
        _ = try await host.library(other, .init(action: .apply, address: target, id: id, takeText: true))
        _ = try await host.publish(other, by: "agent")
        let after = try XCTUnwrap(try store.libraryIndex().entries[id])
        XCTAssertEqual(after.version, before.version, "recording the C moves no version")
        let object = try json(try store.object(after.entry))
        let function = try XCTUnwrap(object["function"] as? [String: Any], "the entry learned its C")
        XCTAssertNotNil(function["c"])
        let history = try XCTUnwrap(try store.libraryHistory(id: id))
        XCTAssertTrue(history.versions.last?.reason?.hasPrefix("the function's C recorded") == true,
                      "\(String(describing: history.versions.last?.reason))")
        let stored = try XCTUnwrap(try storedRow(of: target, in: store, module: other))
        XCTAssertEqual(stored["registry"] as? String, id, "stored as a link")
        XCTAssertNil(stored["c"], "no text of the function in the module")
    }

    func testABodyTakenOutIsTheModulesAgain() async throws {
        let (host, store, reviewed, other, source, _, id, directory) = try await aullshrInBoth()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { Task { await host.stop(reviewed); await host.stop(other) } }
        // Written on before the entry went: what is on it now is the module's, and no offer.
        _ = try await host.write(reviewed, "/v1/set/comment", body: body([
            "address": source, "kind": "eol", "text": "written before it was taken out."]))
        _ = try await store.changeLibrary(.init(action: .takeOut, id: id, reason: "test"), by: "test", module: reviewed, dryRun: false)
        let preview = try json(await host.publishPreview(reviewed))
        XCTAssertNil(preview["library_refused"], "\(preview)")
        _ = try await host.publish(reviewed, by: "agent")
        let row = try XCTUnwrap(try storedRow(of: source, in: store, module: reviewed))
        XCTAssertNil(row["registry"])
        XCTAssertEqual(row["name"] as? String, "__aullshr")
        XCTAssertNotEqual(try level(of: source, in: store, module: reviewed), "library")
        // It comes back with the text its project held, and it is stored as the module's.
        let raw = try json(await host.read(reviewed, "/v1/function/\(source)"))
        XCTAssertEqual(row["plate"] as? String ?? raw["plate"] as? String, raw["plate"] as? String)
        XCTAssertNotNil(raw["plate"], "the project kept its text")
        XCTAssertNotNil(row["c"], "stored as the module's own function")
    }
}
