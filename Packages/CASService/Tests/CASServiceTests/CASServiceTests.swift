import CodeAnalysis
import Foundation
import HTTPService
import XCTest
@testable import CASService

/// The store served on a loopback port and used through `RemoteStore` and a
/// `StoreMirror` — the same calls the app and the skill make.
final class CASServiceTests: XCTestCase {
    private var directory: URL!
    private var served: ContentStore!
    private var service: CASService!
    private var server: HTTPServer!
    private var remote: RemoteStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CASServiceTests-\(UUID().uuidString)", isDirectory: true)
        served = try ContentStore(root: directory.appendingPathComponent("served"))
        service = try CASService(store: served)
        server = HTTPServer(configuration: .init(port: 0, token: "token"), router: service.routes())
        let port = try await server.start()
        remote = RemoteStore(base: URL(string: "http://127.0.0.1:\(port)")!, token: "token")
    }

    override func tearDown() async throws {
        server?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Helpers

    private func artifact(_ functions: Int) -> Data {
        let functions = (0..<functions).map { index in
            ["entry": String(format: "0x%X", index), "name": "FUN_\(index)",
             "instructions": [["address": String(format: "0x%X", index), "text": "RET"]]] as [String: Any]
        }
        let document: [String: Any] = ["script_version": 2, "ghidra": "12.1.2", "functions": functions,
                                       "strings": [], "post_codes": [], "status_code_calls": []]
        return try! JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
    }

    private func module(_ label: String = "module") -> ModuleIdentity {
        let data = Data(label.utf8)
        return ModuleIdentity(sha256: SHA256Digest(data: data), size: data.count, name: label, kind: "TE",
                              language: "x86:LE:32:default", imageBase: "0x0")
    }

    private let recipe = AnalysisRecipe(id: "code-v4-ghidra-12.1.2", exporter: 4, ghidra: "12.1.2",
                                        script: "ExportCode.java")

    // MARK: - The served store

    func testAPublishThroughTheServerFollowsTheStoresOrderAndRules() async throws {
        let document = Data(#"{"schema":1}"#.utf8)
        let review = try await remote.putObject(document)
        let first = AnalysisReading(project: "p", rev: 1, review: review)
        try await remote.recordRevision(module: module().sha256, reading: first, by: "agent")
        try await remote.putAnalysis(module: module(), recipe: recipe, artifact: artifact(1), reading: first)

        let second = AnalysisReading(project: "p", rev: 2, review: review)
        try await remote.recordRevision(module: module().sha256, reading: second, by: "agent")
        let manifest = try await remote.putAnalysis(module: module(), recipe: recipe, artifact: artifact(2),
                                                    reading: second)
        XCTAssertEqual(manifest.reading?.rev, 2)
        XCTAssertEqual(try served.analysis(module: module().sha256, recipe: recipe.id)?.stats.functions, 2)
        let history = try await remote.reviewHistory(module: module().sha256)
        XCTAssertEqual(history?.revisions.map(\.rev), [1, 2])

        // An older revision is the server's ContentStore refusing it.
        do {
            try await remote.putAnalysis(module: module(), recipe: recipe, artifact: artifact(3), reading: first)
            XCTFail("an older revision replaced a newer one")
        } catch RemoteStore.Failure.refused(let status, let message, _) {
            XCTAssertEqual(status, 409)
            XCTAssertTrue(message.contains("revision 2"), message)
        }
        let problems = try await remote.verify()
        XCTAssertEqual(problems, [])
    }

    /// A client knows nothing of how the server keeps its objects: a publish,
    /// a read, a mirror and a bundle all see the whole bytes under the same name.
    func testAServerKeepingPartedObjectsLooksTheSameToItsClients() async throws {
        // Written before the switch, in the old form, then migrated.
        let before = artifact(3)
        let old = try await remote.putAnalysis(module: module("old"), recipe: recipe, artifact: before)
        XCTAssertEqual(try served.migrateToPartedObjects(dryRun: false).problems, [])
        XCTAssertNotEqual(try Data(contentsOf: served.objectURL(old.artifact.sha256)), before)

        let after = artifact(4)
        let new = try await remote.putAnalysis(module: module("new"), recipe: recipe, artifact: after)
        XCTAssertNotEqual(try Data(contentsOf: served.objectURL(new.artifact.sha256)), after, "kept parted")
        let overTheWire = try await remote.object(new.artifact.sha256)
        XCTAssertEqual(overTheWire, after)
        let oldOverTheWire = try await remote.object(old.artifact.sha256)
        XCTAssertEqual(oldOverTheWire, before)

        // A mirror is a store of its own, in the form it writes.
        let mirror = StoreMirror(remote: remote, mirrorsRoot: directory.appendingPathComponent("mirrors"))
        let store = try await mirror.connect()
        let digest = new.artifact.sha256
        let fetched = try await Task.detached { try store.object(digest) }.value
        XCTAssertEqual(fetched, after)
        XCTAssertEqual(try Data(contentsOf: store.objectURL(new.artifact.sha256)), after, "a mirror is unaffected")

        let bundle = try await remote.exportBundle([try XCTUnwrap(new.key)])
        let elsewhere = try ContentStore(root: directory.appendingPathComponent("elsewhere"))
        let file = directory.appendingPathComponent("bundle.zip")
        try bundle.write(to: file)
        _ = try elsewhere.importBundle(from: file)
        XCTAssertEqual(try elsewhere.object(new.artifact.sha256), after)
        let problems = try await remote.verify()
        XCTAssertEqual(problems, [])
    }

    /// A client takes the root of a cut artifact and the parts it wants,
    /// instead of the whole.
    func testAClientReadsARootAndOnlyThePartsItAsksFor() async throws {
        try served.enablePartedObjects()
        let whole = artifact(3)
        let manifest = try await remote.putAnalysis(module: module("a"), recipe: recipe, artifact: whole)
        let digest = manifest.artifact.sha256

        let root = try await remote.objectRoot(digest)
        XCTAssertEqual(root, try served.objectRoot(digest))
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(root)) as? [String: Any]
        let functions = try XCTUnwrap(object?["functions"] as? [[String: Any]])
        XCTAssertEqual(functions.count, 3)

        let wanted = try XCTUnwrap(SHA256Digest(hex: try XCTUnwrap(functions[1]["part"] as? String)))
        let absent = SHA256Digest(data: Data("absent".utf8))
        let files = try await remote.gzippedObjects([wanted, absent, digest])
        XCTAssertEqual(Set(files.keys), [wanted, digest], "no entry for what the server lacks")
        XCTAssertEqual(files[wanted], try Data(contentsOf: served.objectURL(wanted)))
        XCTAssertEqual(try gunzipped(files[digest]), whole, "a root asked for comes whole")

        let notCut = try await remote.putObject(Data("not an artifact".utf8))
        let noRoot = try await remote.objectRoot(notCut)
        XCTAssertNil(noRoot)
        let missing = try await remote.objectRoot(absent)
        XCTAssertNil(missing)

        // More names than one request carries take more requests.
        let many = (0..<(ServedStoreProtocol.Parts.limit + 2)).map { SHA256Digest(data: Data("\($0)".utf8)) }
        let none = try await remote.gzippedObjects(many + [wanted])
        XCTAssertEqual(Array(none.keys), [wanted])
    }

    private func gunzipped(_ file: Data?) throws -> Data {
        let name = directory.appendingPathComponent("file.gz")
        try XCTUnwrap(file).write(to: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", name.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    func testAnObjectIsCheckedOnTheWayInAndOut() async throws {
        let digest = try await remote.putObject(Data("bytes".utf8))
        let fetched = try await remote.object(digest)
        XCTAssertEqual(fetched, Data("bytes".utf8))
        let absent = try await remote.hasObject(SHA256Digest(data: Data("other".utf8)))
        XCTAssertFalse(absent)

        var request = URLRequest(url: remote.base.appendingPathComponent(
            "cas/v1/objects/\(SHA256Digest(data: Data("a".utf8)).hex)"))
        request.httpMethod = "PUT"
        request.httpBody = Data("b".utf8)
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 422)
    }

    func testABundleImportedAndExportedOverTheWireKeepsItsReport() async throws {
        let local = try ContentStore(root: directory.appendingPathComponent("local"))
        try local.putAnalysis(module: module("a"), recipe: recipe, artifact: artifact(1))
        let bundleURL = directory.appendingPathComponent("a.zip")
        try local.exportBundle([AnalysisKey(module: module("a").sha256, recipe: recipe.id)!], to: bundleURL)

        let report = try await remote.importBundle(try Data(contentsOf: bundleURL))
        XCTAssertEqual(report.imported.count, 1)
        let again = try await remote.importBundle(try Data(contentsOf: bundleURL))
        XCTAssertEqual(again.unchanged.count, 1)

        let exported = try await remote.exportBundle([AnalysisKey(module: module("a").sha256, recipe: recipe.id)!])
        let other = try ContentStore(root: directory.appendingPathComponent("other"))
        let exportedURL = directory.appendingPathComponent("b.zip")
        try exported.write(to: exportedURL)
        XCTAssertEqual(try other.importBundle(from: exportedURL).imported.count, 1)
    }

    func testReferencesAreServed() async throws {
        try await remote.putAnalysis(module: module(), recipe: recipe, artifact: artifact(1))
        let key = AnalysisKey(module: module().sha256, recipe: recipe.id)!
        try await remote.setRef("laptop.project", analyses: [key])
        let refs = try await remote.refs()
        XCTAssertEqual(refs.map(\.name), ["laptop.project"])
        try await remote.removeRef("laptop.project")
        let none = try await remote.refs()
        XCTAssertEqual(none, [])
    }

    // MARK: - The change feed

    func testALongPollEndsOnAChangeAndNamesTheModule() async throws {
        let hello = try await remote.hello()
        let remote = self.remote!
        let waiting = Task { try await remote.changes(since: hello.seq, epoch: hello.epoch, wait: 20) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        try await remote.putAnalysis(module: module(), recipe: recipe, artifact: artifact(1))
        let changes = try await waiting.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(changes.modules, [module().sha256])
        XCTAssertFalse(changes.resync)
        XCTAssertEqual(changes.seq, hello.seq + 1)
    }

    func testAWriteOnTheServersOwnDirectoryIsFoundByARescan() async throws {
        let hello = try await remote.hello()
        try served.putAnalysis(module: module("direct"), recipe: recipe, artifact: artifact(1))
        let found = await service.feed.rescan()
        XCTAssertEqual(found, [module("direct").sha256])
        let changes = try await remote.changes(since: hello.seq, epoch: hello.epoch, wait: 0)
        XCTAssertEqual(changes.modules, [module("direct").sha256])
        // A rescan that finds nothing makes no step.
        let nothing = await service.feed.rescan()
        XCTAssertEqual(nothing, [])
    }

    func testAnotherEpochOrAFutureSequenceAsksForAResync() async throws {
        let hello = try await remote.hello()
        let otherEpoch = try await remote.changes(since: hello.seq, epoch: "another", wait: 0)
        XCTAssertTrue(otherEpoch.resync)
        let future = try await remote.changes(since: hello.seq + 5, epoch: hello.epoch, wait: 0)
        XCTAssertTrue(future.resync)
        let quiet = try await remote.changes(since: hello.seq, epoch: hello.epoch, wait: 0)
        XCTAssertFalse(quiet.resync)
        XCTAssertEqual(quiet.modules, [])
    }

    // MARK: - The library registry

    private func libraryProposal(_ name: String) throws -> LibraryProposal {
        let entry = try JSONSerialization.data(withJSONObject: ["name": name], options: .sortedKeys)
        return LibraryProposal(body: LibraryBody(size: 0x20, full: "00112233445566aa", specific: "0000000000000001"),
                               name: name, kind: "edk2", address: "0x1000", entry: entry)
    }

    /// An offer through the server is the store's own call: an entry, then a
    /// conflict from another module, taken only with a reason; the history is
    /// served, and the feed reports a registry change even with no module's.
    func testTheLibraryRegistryIsServedAndAChangeIsInTheFeed() async throws {
        let hello = try await remote.hello()
        let added = try await remote.putLibraryEntries(module: module("czn").sha256, rev: 33, by: "agent",
                                                       proposals: [try libraryProposal("SetMem")])
        XCTAssertEqual(added.added.map(\.name), ["SetMem"])
        let index = try await remote.libraryIndex()
        XCTAssertEqual(index, try served.libraryIndex())
        let id = try XCTUnwrap(index.entries.keys.first)

        let conflict = try await remote.putLibraryEntries(module: module("rn").sha256, rev: 2, by: "agent",
                                                          proposals: [try libraryProposal("FillBytes")])
        XCTAssertEqual(conflict.conflicts.map(\.proposedName), ["FillBytes"])
        do {
            _ = try await remote.putLibraryEntries(module: module("rn").sha256, rev: 2, by: "agent",
                                                   proposals: [try libraryProposal("FillBytes")], take: .all(""))
            XCTFail("took a conflict without a reason")
        } catch RemoteStore.Failure.refused(let status, _, _) {
            XCTAssertEqual(status, 409)
        }
        let changes = try await remote.changes(since: hello.seq, epoch: hello.epoch, wait: 0)
        XCTAssertEqual(changes.library, true)
        XCTAssertEqual(changes.modules, [], "the registry changed, no module did")

        try await remote.putLibraryEntries(module: module("rn").sha256, rev: 2, by: "agent",
                                           proposals: [try libraryProposal("FillBytes")],
                                           take: .all("the Renoir review names it as EDK2 does"))
        let history = try await remote.libraryHistory(id: id)
        XCTAssertEqual(history?.versions.map(\.version), [1, 2])
        XCTAssertEqual(history?.versions.last?.reason, "the Renoir review names it as EDK2 does")
        let missing = try await remote.libraryHistory(id: "0-0000000000000000-0000000000000000")
        XCTAssertNil(missing)

        // A take by id, each with its own reason, crosses the wire too.
        try await remote.putLibraryEntries(module: module("czn").sha256, rev: 34, by: "agent",
                                           proposals: [try libraryProposal("SetMemTyped")],
                                           take: .these([id: "the Czn review types the length"]))
        let typed = try await remote.libraryHistory(id: id)
        XCTAssertEqual(typed?.versions.last?.reason, "the Czn review types the length")

        // A dry run crosses the wire too, and writes nothing.
        let beforeDry = try await remote.libraryIndex()
        let dry = try await remote.putLibraryEntries(module: module("czn").sha256, rev: 35, by: "agent",
                                                     proposals: [try libraryProposal("SetMemTyped")],
                                                     dryRun: true)
        XCTAssertEqual(dry.unchanged.count, 1)
        let afterDry = try await remote.libraryIndex()
        XCTAssertEqual(afterDry, beforeDry)

        // A take of an entry already settled is refused by name.
        do {
            _ = try await remote.putLibraryEntries(module: module("czn").sha256, rev: 35, by: "agent",
                                                   proposals: [try libraryProposal("SetMemTyped")],
                                                   take: .these([id: "already ours"]))
            XCTFail("a take of a settled entry passed in silence")
        } catch RemoteStore.Failure.refused(let status, let message, _) {
            XCTAssertEqual(status, 409)
            XCTAssertTrue(message.contains("is not in conflict in this publish"), message)
            XCTAssertTrue(message.contains("SetMemTyped is at version 3"), message)
        }
    }

    /// A mirror copies the index when it connects, and again when the feed
    /// says the registry changed.
    func testAMirrorFollowsTheLibraryRegistry() async throws {
        try await remote.putLibraryEntries(module: module("czn").sha256, rev: 33, by: "agent",
                                           proposals: [try libraryProposal("SetMem")])
        let mirror = StoreMirror(remote: remote, mirrorsRoot: directory.appendingPathComponent("mirrors"))
        let store = try await mirror.connect()
        XCTAssertEqual(try store.libraryIndex(), try served.libraryIndex())

        let following = Task { try await mirror.follow(wait: 20) }
        try await Task.sleep(nanoseconds: 200_000_000)
        // A change made on the entry's current version is its next one; a
        // review made on nothing would be a conflict, and the entry would stay.
        var better = try libraryProposal("SetMemBetter")
        better.basedOn = better.body.key
        better.base = 1
        try await remote.putLibraryEntries(module: module("czn").sha256, rev: 34, by: "agent",
                                           proposals: [better])
        _ = try await following.value
        XCTAssertEqual(try store.libraryIndex().entries.values.first?.name, "SetMemBetter")
    }

    // MARK: - The mirror

    func testAMirrorCopiesManifestsAndFetchesObjectsOnRead() async throws {
        try await remote.putAnalysis(module: module("a"), recipe: recipe, artifact: artifact(1))
        let mirrors = directory.appendingPathComponent("mirrors")
        let mirror = StoreMirror(remote: remote, mirrorsRoot: mirrors)
        let store = try await mirror.connect()
        XCTAssertEqual(store.root.lastPathComponent, try served.identity())

        let manifest = try XCTUnwrap(store.analysis(module: module("a").sha256))
        XCTAssertFalse(store.hasObject(manifest.artifact.sha256), "an object is not copied before it is read")
        XCTAssertEqual(store.usableAnalyses().count, 1)
        let code = try await Task.detached { try store.artifact(for: manifest) }.value
        XCTAssertEqual(code.functions.count, 1)
        XCTAssertTrue(store.hasObject(manifest.artifact.sha256), "a fetched object is kept")

        // A change on the server reaches the mirror through the feed.
        let mirrorTask = Task { try await mirror.follow(wait: 20) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await remote.putAnalysis(module: module("b"), recipe: recipe, artifact: artifact(2))
        let copied = try await mirrorTask.value
        XCTAssertEqual(copied, [module("b").sha256])
        XCTAssertEqual(try store.analysis(module: module("b").sha256)?.stats.functions, 2)
    }

    func testAMirrorDropsWhatTheServerNoLongerHasAndRefusesADamagedObject() async throws {
        try await remote.putAnalysis(module: module("a"), recipe: recipe, artifact: artifact(1))
        let mirror = StoreMirror(remote: remote, mirrorsRoot: directory.appendingPathComponent("mirrors"))
        let store = try await mirror.connect()
        XCTAssertNotNil(try store.analysis(module: module("a").sha256))

        // The person collects analyses on the server; the mirror follows.
        try FileManager.default.removeItem(at: served.analysesURL.appendingPathComponent(module("a").sha256.hex))
        try await mirror.connect()
        XCTAssertNil(try store.analysis(module: module("a").sha256))

        // An object the server corrupted is refused, not kept.
        let manifest = try await remote.putAnalysis(module: module("c"), recipe: recipe, artifact: artifact(1))
        try Data("broken".utf8).write(to: served.objectURL(manifest.artifact.sha256))
        try await mirror.connect()
        let mirrored = try XCTUnwrap(store.analysis(module: module("c").sha256))
        let failure = await Task.detached { () -> Error? in
            do { _ = try store.object(mirrored.artifact.sha256); return nil } catch { return error }
        }.value
        XCTAssertNotNil(failure)
        XCTAssertFalse(store.hasObject(mirrored.artifact.sha256))
    }

    func testTheMirrorStaysReadableWithoutTheServer() async throws {
        try await remote.putAnalysis(module: module("a"), recipe: recipe, artifact: artifact(1))
        let mirrors = directory.appendingPathComponent("mirrors")
        let mirror = StoreMirror(remote: remote, mirrorsRoot: mirrors)
        let store = try await mirror.connect()
        let manifest = try XCTUnwrap(store.analysis(module: module("a").sha256))
        _ = try await Task.detached { try store.object(manifest.artifact.sha256) }.value
        server.stop()

        let offline = try await StoreMirror(remote: remote, mirrorsRoot: mirrors)
            .offline(storeID: try served.identity())
        XCTAssertEqual(try offline.object(manifest.artifact.sha256).isEmpty, false)
        do {
            _ = try await remote.hello()
            XCTFail("the stopped server answered")
        } catch RemoteStore.Failure.unreachable {
        }
    }

    // MARK: - byteripper-cas --server

    func testTheCommandLineRunsItsCommandsOnAServedStore() async throws {
        let tokenFile = directory.appendingPathComponent("token")
        try Data("token\n".utf8).write(to: tokenFile)
        let artifactFile = directory.appendingPathComponent("artifact.json")
        try artifact(2).write(to: artifactFile)
        let server = remote.base.absoluteString
        let moduleJSON = String(data: try JSONEncoder().encode(module()), encoding: .utf8)!
        let recipeJSON = String(data: try JSONEncoder().encode(recipe), encoding: .utf8)!

        // The command line blocks on the network; it runs off the test's actor.
        func run(_ arguments: [String]) async -> CASCommand.Output {
            await Task.detached {
                CASCommand.run(["--server", server, "--token-file", tokenFile.path] + arguments)
            }.value
        }
        let hello = await run(["hello"])
        XCTAssertEqual(hello.status, 0, String(data: hello.stderr, encoding: .utf8)!)
        let helloJSON = try JSONSerialization.jsonObject(with: hello.stdout) as! [String: Any]
        XCTAssertEqual(helloJSON["store"] as? String, try served.identity())

        let put = await run(["put-analysis", "--module", moduleJSON, "--recipe", recipeJSON,
                             "--artifact", artifactFile.path])
        XCTAssertEqual(put.status, 0, String(data: put.stderr, encoding: .utf8)!)
        XCTAssertEqual(try served.analysis(module: module().sha256)?.stats.functions, 2)

        let list = await run(["list"])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: list.stdout) as! [Any]).count, 1)
        let newest = await run(["analysis", module().sha256.hex])
        XCTAssertEqual(try JSONDecoder().decode(AnalysisManifest.self, from: newest.stdout).recipe.id, recipe.id)

        let gc = await run(["gc", "--apply"])
        XCTAssertEqual(gc.status, 1)
        XCTAssertTrue(String(data: gc.stderr, encoding: .utf8)!.contains("on the server"))

        let both = CASCommand.run(["--server", server, "--store", "/tmp/x", "list"])
        XCTAssertEqual(both.status, 2)
        let missingToken = CASCommand.run(["--server", server, "--token-file", "/nonexistent", "list"])
        XCTAssertEqual(missingToken.status, 1)
        XCTAssertTrue(String(data: missingToken.stderr, encoding: .utf8)!.contains("no such token file"))
    }

    func testTheTokenGuardsTheStore() async throws {
        let anonymous = RemoteStore(base: remote.base, token: nil)
        do {
            _ = try await anonymous.hello()
            XCTFail("answered without a token")
        } catch RemoteStore.Failure.refused(let status, _, _) {
            XCTAssertEqual(status, 401)
        }
    }
}
