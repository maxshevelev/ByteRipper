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

    /// Ghidra 12.2 runs on JDK 25; the releases before it on 21.
    func testTheJDKAGhidraNeedsFollowsItsVersion() {
        XCTAssertEqual(GhidraInstall.minimumJDK(for: "12.1.2"), 21)
        XCTAssertEqual(GhidraInstall.minimumJDK(for: "12.2"), 25)
        XCTAssertEqual(GhidraInstall.minimumJDK(for: "12.2.1"), 25)
        XCTAssertEqual(GhidraInstall.minimumJDK(for: "13.0"), 25)
        XCTAssertEqual(GhidraInstall.minimumJDK(for: "unknown"), 25)
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
                       mark: GhidraHost.LibraryMatch.Mark? = nil, declined: [String]? = nil) -> GhidraHost.LibraryMatch {
        GhidraHost.LibraryMatch(address: address, name: "F\(address.suffix(4))", named: named, key: "k",
                                kind: nil, exact: exact, near: near, mark: mark, declined: declined)
    }

    func testTheKeysAreEveryBodyAndEveryShape() {
        let keys = GhidraHost.libraryKeys(index)
        XCTAssertEqual(keys.bodies[setMem.key], setMem.key)
        XCTAssertEqual(keys.shapes[setMem.shape], [setMem.key])
        XCTAssertEqual(GhidraHost.shape(of: setMem.key), setMem.shape)
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
            "0x1000 whole unnamed", "0x2000 fill named", "0x4000 whole newer_version",
            "0x7000 variant assert_codes"
        ])
        XCTAssertEqual(plan.toApply.last?.codes, ["0x10199"])
        XCTAssertEqual(plan.applied.map(\.address), ["0x3000"])
        XCTAssertEqual(plan.edited.map(\.address), ["0x5000"])
        XCTAssertNotNil(plan.edited.first?.why, "an edited function is told a newer version exists")
        XCTAssertEqual(plan.declined.map(\.address), ["0x6000"])
        XCTAssertEqual(plan.candidates.map(\.address), ["0x8000"])
        XCTAssertEqual(plan.candidates.first?.entryName, "SetMem")
    }

    /// A candidate is taken only with a reason; an edited function only
    /// with `replace`; a named match with `replace` takes the whole entry.
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
        XCTAssertEqual(try GhidraHost.chosen(plan, address: "0x2000", id: nil, reason: nil, replace: true).first?.mode,
                       "whole")
        XCTAssertThrowsError(try GhidraHost.chosen(plan, address: "0x5000", id: nil, reason: nil, replace: false))
        XCTAssertEqual(try GhidraHost.chosen(plan, address: "0x5000", id: nil, reason: nil, replace: true).first?.mode,
                       "whole")
        XCTAssertThrowsError(try GhidraHost.chosen(plan, address: "0x8000", id: nil, reason: " ", replace: false))
        let taken = try GhidraHost.chosen(plan, address: "0x8000", id: nil, reason: "a debug level, not logic",
                                          replace: false)
        XCTAssertEqual(taken.first?.codes, ["0x2"])
        XCTAssertThrowsError(try GhidraHost.chosen(plan, address: "0x9000", id: nil, reason: nil, replace: false))
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
}
