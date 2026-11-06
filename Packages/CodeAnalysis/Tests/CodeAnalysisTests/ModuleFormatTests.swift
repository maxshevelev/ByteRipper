import Foundation
import XCTest
@testable import CodeAnalysis

/// A library function has no place in a module: what a store keeps of a function
/// is the module's own, or a link with nothing that could describe it.
final class ModuleFormatTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private let module = ModuleIdentity(sha256: SHA256Digest(data: Data("module".utf8)), size: 4, name: "Module",
                                        kind: "pe32", language: "x86:LE:32:default", imageBase: "0x0", phase: nil)
    private let recipe = AnalysisRecipe(id: "code-v10-types2-ghidra-12.2", exporter: 10, ghidra: "12.2",
                                        script: "ExportCode.java", types: nil, passes: nil)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModuleFormatTests-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func artifact(_ functions: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["script_version": 10, "ghidra": "12.2", "functions": functions],
                                   options: [.sortedKeys])
    }

    private let key = "15-00112233445566aa-0123456789abcdef"

    private func stored(_ functions: [[String: Any]]) throws -> [[String: Any]] {
        let manifest = try store.putAnalysis(module: module, recipe: recipe, artifact: try artifact(functions))
        let raw = try store.object(manifest.artifact.sha256)
        return try XCTUnwrap((JSONSerialization.jsonObject(with: raw) as? [String: Any])?["functions"] as? [[String: Any]])
    }

    private func register() throws {
        let object = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": "CopyMem", "kind": "edk2",
                                                                 "plate": "the entry's"], options: .sortedKeys)
        let parts = key.split(separator: "-").map(String.init)
        _ = try store.putLibraryEntries(module: SHA256Digest(data: Data("source".utf8)), rev: 1, by: "agent", proposals: [
            LibraryProposal(body: LibraryBody(size: 0x15, full: parts[1], specific: parts[2]), name: "CopyMem",
                            kind: "edk2", address: "0x1000", entry: object)
        ])
        // Its code, as a publish teaches it: what links a body to the entry.
        let body = LibraryBody(size: 0x15, full: parts[1], specific: parts[2])
        var teaching = LibraryProposal(body: body, name: "CopyMem", kind: "edk2", address: "0x1000",
                                       entry: Data("{}".utf8), basedOn: key, teachesBytesOnly: true)
        teaching.code = LibraryCode.build(
            function: ["entry": "0x1000", "instructions": [["address": "0x1000", "bytes": "90", "text": "NOP"]]],
            number: { _ in nil }, inImage: { _ in false }, label: { _ in nil })
        _ = try store.putLibraryEntries(module: SHA256Digest(data: Data("source".utf8)), rev: 1, by: "agent",
                                        proposals: [teaching])
    }

    /// What used to say "library" says nothing now: the function is the module's,
    /// and none of those words reaches the disk.
    func testAWordOfTheOldFormDoesNotReachTheStore() throws {
        let rows = try stored([["entry": "0x10", "name": "Orphan", "c": "void Orphan(void) {}", "body": key,
                                "review_level": "library", "library_kind": "edk2", "copy_free": true, "review_gaps": ["plate"],
                                "library_entry": ["id": key, "version": 1, "state": "conflict", "base": 1]]])
        for word in ["library_kind", "library_entry", "copy_free", "registry"] { XCTAssertNil(rows[0][word], word) }
        XCTAssertEqual(rows[0]["review_level"] as? String, "partial")
        XCTAssertEqual(rows[0]["name"] as? String, "Orphan", "with no entry it is the module's function")
        let read = try XCTUnwrap(try store.artifactToShow(for: try XCTUnwrap(try store.analysis(module: module.sha256)))
            .functions.first)
        XCTAssertNil(read.libraryKind)
        XCTAssertNil(read.libraryEntry)
        XCTAssertNotEqual(read.reviewLevel, .library)
    }

    /// A body the registry holds has no other place: whatever came in, what is
    /// stored has no field that could hold its name or its text.
    func testABodyTheRegistryHoldsIsStoredAsALinkAndNothingElse() throws {
        try register()
        let rows = try stored([["entry": "0x10", "name": "ACopy", "signature": "void ACopy(void)", "c": "copy",
                                "c_spans": [], "c_sites": [], "c_fields": [], "name_source": "USER_DEFINED",
                                "name_reason": "r", "signature_reason": "r", "custom_storage": true,
                                "review_level": "full", "review_gaps": [], "body": key, "callers": ["0x100"],
                                "callees": [], "instructions": [["address": "0x10", "bytes": "90", "text": "NOP"]],
                                "something_later": "x"]])
        XCTAssertEqual(rows[0].keys.sorted(), ["body", "callees", "callers", "entry", "registry"])
        XCTAssertEqual(rows[0]["registry"] as? String, key)
    }

    /// A reader cannot take a description from a link, whatever a file holds.
    func testALinkDecodesWithNoDescription() throws {
        let data = try artifact([["entry": "0x10", "registry": key, "name": "Smuggled", "signature": "void Smuggled(void)",
                                  "c": "smuggled", "review_level": "full", "review_gaps": ["plate"],
                                  "instructions": [["address": "0x10", "bytes": "90", "text": "NOP"]]]])
        let read = try XCTUnwrap(try JSONDecoder().decode(CodeArtifact.self, from: data).functions.first)
        XCTAssertEqual(read.registryNumber, key)
        XCTAssertNil(read.c)
        XCTAssertNil(read.signature)
        XCTAssertNil(read.reviewLevel)
        XCTAssertEqual(read.reviewGaps, [])
        XCTAssertFalse(read.name.contains("Smuggled"))
    }

    /// A new entry leaves no text behind: every module holding the body links at
    /// once, its artifact and its review both, and a count of the store says so.
    func testANewEntryRewritesEveryModuleHoldingItsBody() throws {
        let review = try JSONSerialization.data(withJSONObject: [
            "functions": ["0x10": ["name": "Holder"], "0x20": ["name": "Own"]],
            "comments": [["address": "0x10", "text": "held"], ["address": "0x20", "text": "own"]]
        ], options: .sortedKeys)
        let reading = AnalysisReading(project: "p", rev: 1, review: try store.putObject(review))
        let raw = try artifact([
            ["entry": "0x10", "name": "Holder", "c": "text of it", "body": key, "instructions": [["address": "0x10", "bytes": "90", "text": "NOP"]]],
            ["entry": "0x20", "name": "Own", "c": "own text", "body": "15-1111111111111111-2222222222222222",
             "instructions": [["address": "0x20", "text": "NOP"]]]
        ])
        let before = try store.putAnalysis(module: module, recipe: recipe, artifact: raw, reading: reading)
        XCTAssertEqual(try store.libraryHoldings().first?.links, 0)
        try register()
        let after = try XCTUnwrap(try store.analysis(module: module.sha256))
        XCTAssertNotEqual(after.artifact.sha256, before.artifact.sha256)
        XCTAssertEqual(after.relinkedFrom, before.artifact.sha256, "still that publish, for the next to replace")
        let text = String(decoding: try store.object(after.artifact.sha256), as: UTF8.self)
        XCTAssertFalse(text.contains("text of it"))
        XCTAssertFalse(text.contains("Holder"))
        XCTAssertTrue(text.contains("own text"), "a function of the module stays")
        let document = String(decoding: try store.object(try XCTUnwrap(after.reading?.review)), as: UTF8.self)
        XCTAssertFalse(document.contains("Holder"))
        XCTAssertFalse(document.contains("held"))
        XCTAssertTrue(document.contains("own"))
        XCTAssertEqual(after.reading?.rev, 1)
        let held = try XCTUnwrap(try store.libraryHoldings().first)
        XCTAssertEqual(held.links, 1)
        XCTAssertEqual(held.ownBodiesInRegistry, 0)
        XCTAssertEqual(held.outOfFormat, 0)
        XCTAssertEqual(try store.relinkModules(dryRun: true), [], "nothing left to rewrite")
    }

    /// The walk over a store written in the old form: a count before, a rewrite, a count after.
    func testOneRelinkBringsAnOldStoreToTheFormat() throws {
        try register()
        // Written past the door, as files from before it are.
        let old = try artifact([["entry": "0x10", "name": "Old", "c": "old text", "body": key, "copy_free": true,
                                 "library_kind": "edk2", "review_level": "library",
                                 "library_entry": ["id": key, "version": 1, "state": "entry"]]])
        let digest = try store.putObject(old)
        let manifest = AnalysisManifest(module: module, recipe: recipe,
                                        artifact: AnalysisArtifact(sha256: digest, size: old.count, mediaType: "application/json"),
                                        analyzedAt: "2026-11-01T00:00:00Z", stats: ArtifactStats.count(in: old))
        let url = store.manifestURL(try XCTUnwrap(manifest.key))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url)
        let found = try XCTUnwrap(try store.libraryHoldings().first)
        XCTAssertEqual(found.ownBodiesInRegistry, 1)
        XCTAssertEqual(found.outOfFormat, 1)
        XCTAssertEqual(try store.relinkModules(dryRun: true).count, 1)
        XCTAssertEqual(try store.analysis(module: module.sha256)?.artifact.sha256, digest, "a dry run writes nothing")
        XCTAssertEqual(try store.relinkModules().count, 1)
        let now = try XCTUnwrap(try store.libraryHoldings().first)
        XCTAssertEqual([now.links, now.ownBodiesInRegistry, now.outOfFormat], [1, 0, 0])
        XCTAssertTrue(store.hasObject(digest), "the old object stays: the way back")
    }

    /// An analysis put in the store as it is, past `stored`: how files written
    /// before a rule reach it.
    @discardableResult
    private func written(_ functions: [[String: Any]]) throws -> SHA256Digest {
        let old = try artifact(functions)
        let digest = try store.putObject(old)
        let manifest = AnalysisManifest(module: module, recipe: recipe,
                                        artifact: AnalysisArtifact(sha256: digest, size: old.count, mediaType: "application/json"),
                                        analyzedAt: "2026-11-01T00:00:00Z", stats: ArtifactStats.count(in: old))
        let url = store.manifestURL(try XCTUnwrap(manifest.key))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url)
        return digest
    }

    private func storedNow() throws -> [String: [String: Any]] {
        let raw = try store.object(try XCTUnwrap(try store.analysis(module: module.sha256)).artifact.sha256)
        let functions = try XCTUnwrap((JSONSerialization.jsonObject(with: raw) as? [String: Any])?["functions"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: functions.map { ($0["name"] as? String ?? "", $0) })
    }

    /// A function that stops being library code says what a reader can find of
    /// its review: the older form's "library" judged nothing where there is no C,
    /// and a thunk has no body of its own.
    func testAFunctionThatIsTheModulesAgainIsGradedByWhatIsStored() throws {
        let rows = try stored([
            ["entry": "0x10", "name": "FUN_00000010", "name_source": "DEFAULT", "body": "1f-aa-bb", "copy_free": true,
             "review_level": "library", "review_gaps": [String](), "library_entry": ["id": "1f-aa-bb", "state": "entry"]],
            ["entry": "0x20", "name": "StrCmp", "name_source": "DEFAULT", "thunk": true, "library_kind": "edk2",
             "review_level": "library", "review_gaps": [String]()],
            ["entry": "0x30", "name": "Reviewed", "name_source": "USER_DEFINED", "c": "int Reviewed(void) {}",
             "library_kind": "edk2", "review_level": "library", "review_gaps": [String]()],
            ["entry": "0x40", "name": "Named", "name_source": "USER_DEFINED", "library_kind": "edk2",
             "review_level": "library", "review_gaps": ["params"]]
        ])
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0["entry"] as? String ?? "", $0) })
        XCTAssertEqual(by["0x10"]?["review_level"] as? String, "decompiled")
        XCTAssertEqual(by["0x10"]?["review_gaps"] as? [String], ["name", "plate", "comments", "c"])
        XCTAssertEqual(by["0x20"]?["review_level"] as? String, "no_body")
        XCTAssertEqual(by["0x20"]?["review_gaps"] as? [String], [])
        XCTAssertEqual(by["0x30"]?["review_level"] as? String, "full", "the exporter's verdict over its C stays")
        XCTAssertEqual(by["0x40"]?["review_level"] as? String, "partial")
        XCTAssertEqual(by["0x40"]?["review_gaps"] as? [String], ["plate", "comments", "params", "c"])
    }

    /// A level an earlier walk wrote wrong is put right by the next one, and
    /// only that changes.
    func testAFullWithNoCIsPutRightByTheNextRelink() throws {
        let digest = try written([
            ["entry": "0x10", "name": "FUN_00000010", "name_source": "DEFAULT", "review_level": "full", "review_gaps": [String]()],
            ["entry": "0x20", "name": "StrCmp", "thunk": true, "review_level": "full", "review_gaps": [String]()],
            ["entry": "0x30", "name": "Reviewed", "name_source": "USER_DEFINED", "c": "text", "review_level": "full",
             "review_gaps": [String]()],
            // An older exporter's thunk, which wrote no level at all: left as it is.
            ["entry": "0x40", "name": "Jump", "thunk": true]
        ])
        XCTAssertEqual(try store.relinkModules().count, 1)
        let now = try storedNow()
        XCTAssertEqual(now["FUN_00000010"]?["review_level"] as? String, "decompiled")
        XCTAssertEqual(now["StrCmp"]?["review_level"] as? String, "no_body")
        XCTAssertEqual(now["Reviewed"]?["review_level"] as? String, "full")
        XCTAssertEqual(now["Reviewed"]?["c"] as? String, "text")
        XCTAssertNil(now["Jump"]?["review_level"])
        XCTAssertNil(now["Jump"]?["review_gaps"])
        XCTAssertEqual(try store.analysis(module: module.sha256)?.relinkedFrom, digest)
        XCTAssertEqual(try store.relinkModules(dryRun: true), [], "a second walk finds nothing")
    }

    /// The count of library code left in modules counts what the store would
    /// link, not bytes: the same bytes with code of the module's own are the
    /// module's function.
    func testTheCountLeavesOutAFunctionWhoseCodeIsTheModules() throws {
        try register()
        try written([["entry": "0x10", "name": "Own", "name_source": "USER_DEFINED", "c": "own", "body": key,
                      "review_level": "full", "review_gaps": [String](),
                      "instructions": [["address": "0x10", "bytes": "91", "text": "XCHG"]]]])
        let mine = try XCTUnwrap(try store.libraryHoldings().first)
        XCTAssertEqual(mine.ownBodiesInRegistry, 0, "its code does not bind: the module's")
        XCTAssertEqual(try store.relinkModules(dryRun: true), [], "and the store would not link it")
        try written([["entry": "0x10", "name": "Copy", "name_source": "USER_DEFINED", "c": "copy", "body": key,
                      "review_level": "full", "review_gaps": [String](),
                      "instructions": [["address": "0x10", "bytes": "90", "text": "NOP"]]]])
        XCTAssertEqual(try store.libraryHoldings().first?.ownBodiesInRegistry, 1, "the entry's code: a link to make")
    }

    func testARefusalNamesEachFunction() throws {
        var result = LibraryWriteResult()
        result.notLibrary = [.init(address: "0x20", name: "Reader", body: "b", why: "data", data: ["0x900"]),
                             .init(address: "0x30", name: "Caller", body: "c", why: "callee", callees: ["Own"])]
        let refusal = try XCTUnwrap(LibraryRefusal.refusal(LibraryRefusal.rows(of: result)))
        for said in ["Reader at 0x20", "0x900", "Caller at 0x30", "Own", "Nothing was stored"] {
            XCTAssertTrue(refusal.contains(said), refusal)
        }
        XCTAssertNil(LibraryRefusal.refusal(LibraryRefusal.rows(of: LibraryWriteResult())))
    }

    private func manifest(project: String?, rev: Int = 1, at: String, recipe: String) -> AnalysisManifest {
        let digest = SHA256Digest(data: Data("\(project ?? "")\(at)".utf8))
        return AnalysisManifest(
            module: module, recipe: AnalysisRecipe(id: recipe, exporter: 10, ghidra: "12.2", script: "ExportCode.java",
                                                   types: nil, passes: nil),
            artifact: AnalysisArtifact(sha256: digest, size: 1, mediaType: "application/json"),
            source: SourceIdentity(), analyzedAt: at, stats: AnalysisStats(),
            reading: project.map { AnalysisReading(project: $0, rev: rev, review: digest, description: nil) })
    }

    /// A module has one history: a reader is shown every analysis the store
    /// holds, whatever project an older build named its reading by, and a saved
    /// session follows to the later revision.
    func testEveryAnalysisIsShownAndASessionFollowsTheLaterRevision() {
        let old = manifest(project: "old", rev: 2, at: "2026-01-01T00:00:00Z", recipe: "code-v5")
        let later = manifest(project: "later", rev: 3, at: "2026-11-05T00:00:00Z", recipe: "code-v10")
        let index = CodeAnalysisIndex(manifests: [old, later])
        XCTAssertEqual(Set(index.manifests(for: module.sha256).map(\.recipe.id)), ["code-v5", "code-v10"])
        XCTAssertEqual(index.latestReading(of: old).recipe.id, "code-v10")
    }

    func testAMechanicalRunDoesNotHideAReviewAndOneProjectKeepsItsRecipes() {
        let review = manifest(project: "one", at: "2026-01-01T00:00:00Z", recipe: "code-v5")
        let run = manifest(project: nil, at: "2026-11-05T00:00:00Z", recipe: "code-v10")
        XCTAssertEqual(CodeAnalysisIndex(manifests: [review, run]).manifests(for: module.sha256).count, 2)
        let next = manifest(project: "one", rev: 2, at: "2026-11-05T00:00:00Z", recipe: "code-v10")
        XCTAssertEqual(CodeAnalysisIndex(manifests: [review, next]).manifests(for: module.sha256).count, 2)
    }
}
