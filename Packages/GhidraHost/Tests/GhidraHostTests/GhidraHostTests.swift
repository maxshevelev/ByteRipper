import CodeAnalysis
import AgentKit
import Foundation
import XCTest
@testable import GhidraHost

final class GhidraHostUnitTests: XCTestCase {
    /// A patched language prints other C, so it is in the recipe's key; a stock artifact's id is what it was.
    func testARecipeNamesTheLanguagePatch() {
        let stock = GhidraHost.recipe(for: ["script_version": 10, "ghidra": "12.2"], types: "edk2-stable202608-r2", passes: [])
        XCTAssertEqual(stock.id, "code-v10-types2-ghidra-12.2")
        let patched = GhidraHost.recipe(for: ["script_version": 10, "ghidra": "12.2", "language_patch": "descriptor-tables-1"],
                                        types: "edk2-stable202608-r2", passes: [])
        XCTAssertEqual(patched.id, "code-v10-types2-ghidra-12.2-lang-descriptor-tables-1")
        XCTAssertEqual(AnalysisRecipe.identifier(exporter: 10, ghidra: "12.2", languagePatch: "descriptor-tables-1"),
                       "code-v10-ghidra-12.2-lang-descriptor-tables-1")
    }

    /// Only a publish that would take a patch away is refused.
    func testAStockPublishMayNotFollowAPatchedOne() {
        let patched = "code-v10-types2-ghidra-12.2-lang-descriptor-tables-1"
        let stock = "code-v10-types2-ghidra-12.2"
        XCTAssertNotNil(GhidraHost.languagePatchRefusal(publishing: stock, over: patched))
        XCTAssertNil(GhidraHost.languagePatchRefusal(publishing: patched, over: stock))
        XCTAssertNil(GhidraHost.languagePatchRefusal(publishing: patched, over: patched))
        XCTAssertNil(GhidraHost.languagePatchRefusal(publishing: stock, over: stock))
        XCTAssertNil(GhidraHost.languagePatchRefusal(publishing: stock, over: nil))
    }

    func testTheRecipeIsTheOnePythonNames() {
        let artifact: [String: Any] = ["script_version": 4, "ghidra": "12.1.2"]
        let typed = GhidraHost.recipe(for: artifact, types: "edk2-stable202608", passes: ["ApplyUefi.java"])
        XCTAssertEqual(typed.id, "code-v4-ghidra-12.1.2")
        XCTAssertEqual(typed.types, "edk2-stable202608")
        let retyped = GhidraHost.recipe(for: artifact, types: "edk2-stable202608-r2", passes: ["ApplyUefi.java"])
        XCTAssertEqual(retyped.id, "code-v4-types2-ghidra-12.1.2")
        let plain = GhidraHost.recipe(for: artifact, types: nil, passes: [])
        XCTAssertEqual(plain.id, "code-v4-plain-ghidra-12.1.2")
        XCTAssertNil(plain.passes)
        XCTAssertEqual(GhidraHost.safeRecipe("12.1 beta/2"), "12.1-beta-2")
        XCTAssertEqual(GhidraHost.safeRecipe("///"), "unknown")
    }

    /// An owner that exited on its idle timeout is the host's zombie until
    /// reaped; it must read as gone, not as an owner too busy to answer.
    /// The count survives an owner's restart, where the modification number
    /// starts again and a number from the session before compares with nothing.
    func testUnpublishedWritesAreReadFromTheCount() {
        func published(modification: Int?, writes: Int?) -> ProjectState.Published {
            ProjectState.Published(artifact: "a", recipe: "r", at: "now", modification: modification, writes: writes)
        }
        let afterRestart: [String: Any] = ["modification": 6, "writes": 501, "changed": false]
        XCTAssertEqual(GhidraHost.holdsUnpublishedWrites(hello: afterRestart,
                                                         published: published(modification: 834, writes: 500)), true)
        XCTAssertEqual(GhidraHost.holdsUnpublishedWrites(hello: ["modification": 4, "writes": 500, "changed": false],
                                                         published: published(modification: 834, writes: 500)), false)
        // A publish made before the count: only what was counted since is work.
        XCTAssertEqual(GhidraHost.holdsUnpublishedWrites(hello: ["modification": 4, "writes": 0, "changed": false],
                                                         published: published(modification: 834, writes: nil)), false)
        XCTAssertEqual(GhidraHost.holdsUnpublishedWrites(hello: ["modification": 5, "writes": 1, "changed": false],
                                                         published: published(modification: 834, writes: nil)), true)
        // An owner of an older build has no count.
        XCTAssertEqual(GhidraHost.holdsUnpublishedWrites(hello: ["modification": 9, "changed": false],
                                                         published: published(modification: 8, writes: nil)), true)
        XCTAssertEqual(GhidraHost.holdsUnpublishedWrites(hello: ["changed": true], published: nil), true)
    }

    /// Two hosts share the cache: only the same sources may share a jar.
    func testAJarBelongsToWhatItsSourcesHold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func tree(_ name: String, _ owner: String) throws -> OwnerSources {
            let at = root.appendingPathComponent(name, isDirectory: true)
            let sources = OwnerSources.directory(at: at)
            for file in sources.files {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data((file.lastPathComponent == "Owner.java" ? owner : "same").utf8).write(to: file)
            }
            return sources
        }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let server = try OwnerBuild.folder(in: cache, sources: try tree("server", "deployed"))
        XCTAssertNotEqual(server, try OwnerBuild.folder(in: cache, sources: try tree("checkout", "being edited")),
                          "a checkout's edit does not reach the server's jar")
        XCTAssertEqual(server, try OwnerBuild.folder(in: cache, sources: try tree("copy", "deployed")),
                       "the same sources elsewhere, or newer on disk, are the same jar")
    }

    func testAnExitedChildReadsAsGone() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("zombie-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let child = try Subprocess.spawn(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 0"], log: log, ownSession: true)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(kill(child.pid, 0), 0, "a zombie answers kill(pid, 0)")
        XCTAssertFalse(Subprocess.isAlive(child.pid))
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

        // The description alone makes the next revision, as an object of its own.
        _ = try await host.write(module, "/v1/set/description", body: JSONSerialization.data(withJSONObject: [
            "text": "# CpuPei\r\n\n## Purpose\n\nInitialises the CPU.  \n\n"]))
        _ = try await host.write(module, "/v1/set/description", body: JSONSerialization.data(withJSONObject: [
            "section": "Open questions", "text": "- Who reads 0x11004?"]))
        let read = try JSONSerialization.jsonObject(with: await host.read(module, "/v1/description")) as! [String: Any]
        XCTAssertEqual(read["sections"] as? [String], ["Purpose", "Open questions"])
        let described = try await host.publish(module, by: "agent").manifest
        XCTAssertEqual(described.reading?.rev, (manifest.reading?.rev ?? 0) + 1)
        XCTAssertEqual(try store.moduleDescription(for: described),
                       "# CpuPei\n\n## Purpose\n\nInitialises the CPU.\n\n## Open questions\n\n- Who reads 0x11004?\n")
        XCTAssertEqual(try store.reviewHistory(module: module)?.revisions.last?.description,
                       described.reading?.description)
        let unchanged = try await host.publish(module, by: "agent").manifest
        XCTAssertEqual(unchanged.reading?.rev, described.reading?.rev)
        XCTAssertEqual(store.verify(), [])

        // A range read as 16-bit code decodes again in that size, says so in
        // the disassembly, and goes back to 32-bit the same way.
        let start = try XCTUnwrap(UInt64(entry.dropFirst(2), radix: 16))
        let range: [String: Any] = ["start": entry, "end": String(format: "0x%llX", start + 0x10), "by": "agent"]
        func bitsOfFirst() async throws -> Int? {
            let listing = try JSONSerialization.jsonObject(with: await host.read(module, "/v1/disassembly/\(entry)")) as! [String: Any]
            return (listing["instructions"] as? [[String: Any]])?.first?["bits"] as? Int
        }
        let sixteen = try JSONSerialization.jsonObject(with: await host.write(
            module, "/v1/set/code-mode", body: JSONSerialization.data(withJSONObject: range.merging(["bits": 16]) { $1 }))) as! [String: Any]
        XCTAssertGreaterThan(sixteen["instructions"] as? Int ?? 0, 0)
        XCTAssertEqual(sixteen["functions"] as? [String], [entry])
        let sixteenBits = try await bitsOfFirst()
        XCTAssertEqual(sixteenBits, 16)
        _ = try await host.write(module, "/v1/set/code-mode",
                                 body: JSONSerialization.data(withJSONObject: range.merging(["bits": 32]) { $1 }))
        let thirtyTwoBits = try await bitsOfFirst()
        XCTAssertNil(thirtyTwoBits, "32-bit code in a 32-bit program carries no mark")

        let stopped = await host.stop(module)
        XCTAssertTrue(stopped)
        let summaries = await host.summaries()
        XCTAssertEqual(summaries.first?.running, false)
    }

    /// A kept project is let go by moving its folder to the Trash — the owner
    /// stopped first — and nothing of the analysis store is touched.
    func testForgettingAProjectMovesItToTheTrash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraForget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: root.appendingPathComponent("projects"),
                                                   idle: 120, holder: "test"), writer: store)
        let module = SHA256Digest(data: Data("module \(UUID().uuidString)".utf8))
        let folder = root.appendingPathComponent("projects/\(module.hex)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("state.json"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("module.gpr"))
        // The store's copy of the project goes too, or the next open would bring it back.
        let zip = root.appendingPathComponent("project.zip")
        try Data("a project".utf8).write(to: zip)
        try store.putProject(module: module, file: zip, rev: 1, artifact: SHA256Digest(data: Data()), review: nil,
                             environment: .init(ghidra: "12.2", languagePatch: nil, types: nil, passes: [],
                                                recipe: "r", ownerBuild: nil))
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        addTeardownBlock {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
            where name.hasPrefix(module.hex) {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
            }
        }

        let trashed = try await host.forget(module)
        addTeardownBlock { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the project folder is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path), "and it is in the Trash")
        XCTAssertNil(try store.project(module: module), "the store keeps no copy of it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.path), "the store stays")
    }

    /// Ghidra 12.2 is the oldest this build runs on, and its JDK is 25. A
    /// version read as older is refused by name; one that cannot be read is
    /// not guessed at.
    func testAnOlderGhidraIsRefusedAndTheJDKIs25() {
        XCTAssertEqual(GhidraInstall.oldestVersion, "12.2")
        XCTAssertEqual(GhidraInstall.jdkFloor, 25)
        XCTAssertTrue(GhidraInstall.isTooOld("12.1.2"))
        XCTAssertTrue(GhidraInstall.isTooOld("11.4"))
        XCTAssertFalse(GhidraInstall.isTooOld("12.2"))
        XCTAssertFalse(GhidraInstall.isTooOld("12.2.1"))
        XCTAssertFalse(GhidraInstall.isTooOld("13.0"))
        XCTAssertFalse(GhidraInstall.isTooOld("unknown"), "a version that cannot be read is not refused")
    }

    /// The owner's library answer as the registry takes it: an entry's object
    /// made canonical — the same review is the same bytes whatever order the
    /// owner wrote its keys in — and the functions short of the bar with their
    /// gaps.
    func testTheOwnersLibraryAnswerBecomesProposalsAndShortfalls() throws {
        let answer = Data("""
            {"module": "x", "entries": [{"address": "0x9A91116", "name": "SetMem", "kind": "edk2",
              "body": {"size": 22, "full": "00112233445566AA", "specific": "0123456789abcdef"},
              "entry": {"plate": "EDK2 BaseMemoryLib SetMem", "name": "SetMem", "schema": 1}}],
             "below_bar": [{"address": "0x9A910A9", "name": "LibAmdIoWrite", "kind": "amd",
              "gaps": ["params", "comments"]}]}
            """.utf8)
        let offer = try GhidraHost.libraryOffer(answer)
        XCTAssertEqual(offer.proposals.count, 1)
        let proposal = try XCTUnwrap(offer.proposals.first)
        let c: [String: Any] = ["entry": "0x1000", "c": "cpuid(PRINTED); return 0;",
                                "instructions": [["address": "0x1000"], ["address": "0x1004"]]]
        let printed = try XCTUnwrap(GhidraHost.printedEquates(of: c, in: [
            ["name": "PRINTED", "value": "0xBA", "enum": "LEAF", "comment": "why", "references": [["0x1004", 1], ["0x9999", 0]]],
            ["name": "NOT_PRINTED", "value": "0x1", "references": [["0x1000", 1]]],
            ["name": "ELSEWHERE", "value": "0x2", "references": [["0x9999", 1]]]
        ]))
        XCTAssertEqual(printed.count, 1)
        XCTAssertEqual(printed[0]["name"] as? String, "PRINTED")
        XCTAssertEqual((printed[0]["uses"] as? [[Any]])?.count, 1, "only its places in this function")
        XCTAssertEqual((printed[0]["uses"] as? [[Any]])?.first?.first as? String, "0x4")
        XCTAssertNil(GhidraHost.printedEquates(of: c, in: []), "an entry that prints none does not change")
        // An older entry learns only what its own C already prints.
        let older = try JSONSerialization.data(withJSONObject: ["name": "F", "function": ["c": "cpuid(PRINTED);"]])
        let twoPrinted: [String: Any] = ["entry": "0x1000", "c": "cpuid(PRINTED); f(ONLY_HERE);",
                                         "instructions": [["address": "0x1000"]]]
        let learned = try XCTUnwrap(GhidraHost.withEquatesItPrints(older, of: twoPrinted, in: [
            ["name": "PRINTED", "value": "0x1", "references": [["0x1000", 1]]],
            ["name": "ONLY_HERE", "value": "0x2", "references": [["0x1000", 0]]]
        ]))
        let names = ((try JSONSerialization.jsonObject(with: learned) as? [String: Any])?["equates"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["PRINTED"])
        XCTAssertNil(GhidraHost.withEquatesItPrints(older, of: twoPrinted, in: [
            ["name": "ONLY_HERE", "value": "0x2", "references": [["0x1000", 0]]]
        ]))
        XCTAssertEqual(proposal.body.key, "16-00112233445566aa-0123456789abcdef")
        XCTAssertEqual(String(decoding: proposal.entry, as: UTF8.self),
                       #"{"name":"SetMem","plate":"EDK2 BaseMemoryLib SetMem","schema":1}"#)
        XCTAssertEqual(offer.shortfalls, [GhidraHost.LibraryShortfall(
            address: "0x9A910A9", name: "LibAmdIoWrite", kind: "amd", gaps: ["params", "comments"])])
        XCTAssertThrowsError(try GhidraHost.libraryOffer(Data(#"{"entries": [{"name": "X"}]}"#.utf8)))
    }
}

/// What each match of a module with the library registry calls for
/// (`Design/LIBRARY_REGISTRY_PLAN.md` §1), decided without an owner.
final class GhidraHostLibraryPlanTests: XCTestCase {
    private let module = SHA256Digest(data: Data("AmdSocFp6CznPei".utf8))
    private let setMem = LibraryBody(size: 7, full: "2ed7d3a86dde3054", specific: "68eb8ed527beddca")
    private let assertHalt = LibraryBody(size: 0x20, full: "1111111111111111", specific: "2222222222222222")

    private var index: LibraryIndex {
        var index = LibraryIndex()
        func add(_ body: LibraryBody, _ name: String, version: Int = 1, role: String? = nil) {
            index.entries[body.key] = LibraryIndexEntry(
                version: version, entry: SHA256Digest(data: Data(name.utf8)), name: name, kind: "edk2",
                source: LibrarySource(module: module, address: "0x9A91116", rev: 35, by: "agent"),
                variants: [LibraryVariant(body: body, module: module)], role: role)
            index.bodies[body.key] = body.key
        }
        add(setMem, "SetMem", version: 2)
        add(assertHalt, "AgesaAssertHalt", role: "assert")
        return index
    }

    private func match(_ address: String, named: Bool = true, exact: String? = nil, near: [String]? = nil,
                       mark: GhidraHost.LibraryMatch.Mark? = nil,
                       declined: [String]? = nil) -> GhidraHost.LibraryMatch {
        GhidraHost.LibraryMatch(address: address, name: "F\(address.suffix(4))", named: named, key: "k",
                                exact: exact, near: near, mark: mark, declined: declined)
    }

    func testTheKeysAreEveryBodyAndEveryShape() {
        let keys = GhidraHost.libraryKeys(index)
        XCTAssertEqual(keys.bodies[setMem.key], setMem.key)
        XCTAssertEqual(keys.shapes[setMem.shape], [setMem.key])
        XCTAssertEqual(GhidraHost.shape(of: setMem.key), setMem.shape)
    }

    /// A live row marked as an entry, whose data is not the entry's, reads as the
    /// project holds it: what the plan and a stored row already say.
    func testAMarkedRowWithOtherBytesIsNotReadAsTheEntry() {
        var held = index
        held.entries[setMem.key]?.variants[0].referenceBytes = "aaaa"
        func answer(_ bytes: String?) -> [String: Any] {
            var row: [String: Any] = ["body_key": setMem.key, "library_entry": ["id": setMem.key, "version": 0, "state": "entry"]]
            row["reference_bytes"] = bytes
            return row
        }
        var same = answer("aaaa")
        XCTAssertNotNil(GhidraHost.heldEntry(&same, index: held))
        XCTAssertEqual((same["library_entry"] as? [String: Any])?["state"] as? String, "linked")
        XCTAssertEqual((same["library_entry"] as? [String: Any])?["version"] as? Int, held.entries[setMem.key]?.version)
        for bytes in ["bbbb", nil] as [String?] {
            var other = answer(bytes)
            XCTAssertNil(GhidraHost.heldEntry(&other, index: held), "\(String(describing: bytes))")
            XCTAssertEqual((other["library_entry"] as? [String: Any])?["state"] as? String, "reference_bytes")
        }
    }

    func testEachMatchIsSortedByWhatItCallsFor() {
        let id = setMem.key
        let assertOnly = GhidraHost.LibraryComparison(comparable: true, why: nil, differences: [
            .init(offset: "0x4", operand: 0, value: "0x10199", entryValue: "0x10196", isAssert: true)
        ], assertCodesOnly: true)
        let otherConstants = GhidraHost.LibraryComparison(comparable: true, why: nil, differences: [
            .init(offset: "0x8", operand: 1, value: "0xC0011004", entryValue: "0xC0011005", isAssert: false)
        ], assertCodesOnly: false)
        let matches = [
            match("0x1000", named: false, exact: id),
            match("0x2000", exact: id),
            match("0x3000", exact: id, mark: .init(id: id, version: 2, edited: false, codes: nil)),
            match("0x4000", exact: id, mark: .init(id: id, version: 1, edited: false, codes: nil)),
            match("0x5000", exact: id, mark: .init(id: id, version: 1, edited: true, codes: nil)),
            match("0x6000", exact: id, declined: [id]),
            match("0x7000", near: [id]),
            match("0x8000", near: [id])
        ]
        XCTAssertEqual(GhidraHost.comparisons(matches).map(\.address), ["0x7000", "0x8000"])
        let plan = GhidraHost.libraryPlan(matches, index: index, hashed: 112, comparisons: [
            "0x7000 \(id)": assertOnly, "0x8000 \(id)": otherConstants
        ])
        XCTAssertEqual(plan.toApply.map { "\($0.address) \($0.mode ?? "") \($0.state)" }, [
            "0x1000 link unnamed", "0x2000 link named", "0x4000 link newer_version",
            "0x7000 link assert_codes"
        ])
        XCTAssertEqual(plan.toApply.last?.codes, ["0x10199"])
        XCTAssertEqual(plan.applied.map(\.address), ["0x3000"])
        XCTAssertEqual(plan.edited.map(\.address), ["0x5000"])
        XCTAssertNotNil(plan.edited.first?.why, "an edited function is told a newer version exists")
        XCTAssertEqual(plan.declined.map(\.address), ["0x6000"])
        XCTAssertEqual(plan.candidates.map(\.address), ["0x8000"])
        XCTAssertEqual(plan.candidates.first?.entryName, "SetMem")
    }

    /// A candidate is taken only with a reason; what is already matched links.
    func testAnAddressIsAppliedOnlyAsItsStateAllows() throws {
        let id = setMem.key
        let plan = GhidraHost.libraryPlan([
            match("0x2000", exact: id),
            match("0x5000", exact: id, mark: .init(id: id, version: 2, edited: true, codes: nil)),
            match("0x8000", near: [id])
        ], index: index, hashed: 3, comparisons: ["0x8000 \(id)": GhidraHost.LibraryComparison(
            comparable: true, why: nil,
            differences: [.init(offset: "0x8", operand: 1, value: "0x2", entryValue: "0x1", isAssert: false)],
            assertCodesOnly: false)])
        XCTAssertEqual(try GhidraHost.chosen(plan, address: "0x2000", id: nil, reason: nil).first?.mode, "link")
        // A draft of the entry's next version is given up by linking again.
        XCTAssertEqual(try GhidraHost.chosen(plan, address: "0x5000", id: nil, reason: nil).first?.mode, "link")
        XCTAssertThrowsError(try GhidraHost.chosen(plan, address: "0x8000", id: nil, reason: " "))
        let taken = try GhidraHost.chosen(plan, address: "0x8000", id: nil, reason: "a debug level, not logic")
        XCTAssertEqual(taken.first?.codes, ["0x2"])
        XCTAssertThrowsError(try GhidraHost.chosen(plan, address: "0x9000", id: nil, reason: nil))
    }

    /// A body applied as a variant is offered with the entry it joins and
    /// its codes; an assert routine with its role.
    func testTheOfferCarriesVariantsAndRoles() throws {
        let answer = Data("""
            {"entries": [{"address": "0x9A91116", "name": "ReadSmn", "kind": "amd", "variant_of": "7-aa-bb",
              "codes": ["0x10199"], "body": {"size": 7, "full": "00112233445566aa", "specific": "0123456789abcdef"},
              "entry": {"name": "ReadSmn", "schema": 1}},
             {"address": "0x9A90FF3", "name": "AgesaAssertHalt", "kind": "amd",
              "body": {"size": 32, "full": "00112233445566ab", "specific": "0123456789abcdee"},
              "entry": {"name": "AgesaAssertHalt", "assert": true, "schema": 1}}],
             "below_bar": []}
            """.utf8)
        let offer = try GhidraHost.libraryOffer(answer)
        XCTAssertEqual(offer.proposals.first?.variantOf, "7-aa-bb")
        XCTAssertEqual(offer.proposals.first?.codes, ["0x10199"])
        XCTAssertNil(offer.proposals.first?.role)
        XCTAssertEqual(offer.proposals.last?.role, "assert")
    }

    /// What a review may say to a publish about the registry is why it adds to
    /// an entry. Replacing one is no argument of the tool's.
    func testAReviewGivesReasonsAndNoDecisionToReplace() async throws {
        XCTAssertEqual(try GhidraTools.entryReasons(AgentArguments(["entry_reasons": ["a": "first"]])), ["a": "first"])
        XCTAssertEqual(try GhidraTools.entryReasons(AgentArguments([:])), [:])
        XCTAssertThrowsError(try GhidraTools.entryReasons(AgentArguments(["entry_reasons": "not an object"])))
        XCTAssertThrowsError(try GhidraTools.entryReasons(AgentArguments(["entry_reasons": ["a": 1]])))
    }

    /// A publish answers what it changed: the entries it left as they were
    /// are a count, not a list of sixty-five.
    func testAPublishAnswerLeavesOutTheEntriesItDidNotChange() throws {
        let answer = AgentAnswer.json([
            "library": [
                "added": [],
                "updated": [["id": "a"]],
                "unchanged": [["id": "b"], ["id": "c"]],
                "conflicts": [["id": "d"]]
            ],
            "type_conflicts": []
        ])
        guard case .json(.object(let compact)) = GhidraTools.compactPublish(answer),
              let library = compact["library"]?.objectValue else { return XCTFail("no library part") }
        XCTAssertNil(library["unchanged"])
        XCTAssertEqual(library["unchanged_count"], .int(2))
        XCTAssertEqual(library["updated"]?.arrayValue?.count, 1)
        XCTAssertEqual(library["conflicts"]?.arrayValue?.count, 1)
        XCTAssertEqual(compact["type_conflicts"]?.arrayValue?.count, 0)
    }

    /// An apply answers what it did: the functions already carrying their
    /// entry are a count, and the rest of the plan is kept.
    func testAnApplyAnswerCountsWhatWasAlreadyApplied() throws {
        let answer = AgentAnswer.json([
            "entries": 69, "hashed": 88,
            "applied": [["address": "0x1"], ["address": "0x2"], ["address": "0x3"]],
            "to_apply": [["address": "0x4"]],
            "results": [["address": "0x4", "ok": true]]
        ])
        guard case .json(.object(let compact)) = GhidraTools.compactPlan(answer) else {
            return XCTFail("not an object")
        }
        XCTAssertNil(compact["applied"])
        XCTAssertEqual(compact["applied_count"], .int(3))
        XCTAssertEqual(compact["to_apply"]?.arrayValue?.count, 1)
        XCTAssertEqual(compact["results"]?.arrayValue?.count, 1)
        XCTAssertEqual(compact["entries"], .int(69))
    }
}
