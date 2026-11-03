import Foundation
import XCTest
@testable import CodeAnalysis

/// Objects kept parted: the same names and the same bytes, in less room.
final class ContentStorePartsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentStorePartsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func artifact(_ second: String, extra: String = "") -> Data {
        let padding = String(repeating: "x", count: 2000)
        return Data("""
        {
          "script_version": 9,
          "ghidra": "12.2",
          "types": [{"name": "\(padding)", "é": "ü\\"]}"}],
          "functions": [
            {
              "entry": "0x10",
              "c": "void A(void) { /* ], } \\" */ }"
            },
            {
              "entry": "0x20",
              "c": "\(second)"
            }\(extra)
          ],
          "post_codes": []
        }

        """.utf8)
    }

    /// The root names every function with its part and its fingerprint, and
    /// holds no code; a section is not in it.
    func testARootIndexesItsFunctionsWithoutTheirCode() throws {
        let store = try store()
        let data = artifact("second", extra: "")
        let digest = try store.putObject(data)
        let root = try XCTUnwrap(try store.objectRoot(digest))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: root) as? [String: Any])
        let functions = try XCTUnwrap(object["functions"] as? [[String: Any]])
        XCTAssertEqual(functions.map { $0["entry"] as? String }, ["0x10", "0x20"])
        XCTAssertNil(functions[0]["c"])
        XCTAssertEqual(functions[1]["fingerprint"] as? String,
                       CodeArtifact.fingerprint(name: "", signature: nil, c: "second"))
        for function in functions {
            let part = try XCTUnwrap(SHA256Digest(hex: try XCTUnwrap(function["part"] as? String)))
            XCTAssertTrue(String(decoding: try store.object(part), as: UTF8.self)
                .contains("\"\(try XCTUnwrap(function["entry"] as? String))\""))
        }
        XCTAssertEqual(try store.object(digest), data)
        XCTAssertNil(try store.objectRoot(try store.putObject(Data("not an artifact".utf8))))
        XCTAssertThrowsError(try store.objectRoot(SHA256Digest(data: Data("absent".utf8))))
    }

    /// A function that does not read as one leaves the artifact readable, with
    /// no index to mislead anyone.
    func testAnUnreadableFunctionLeavesNoIndex() throws {
        let store = try store()
        let data = artifact("second", extra: ", 7")
        let digest = try store.putObject(data)
        XCTAssertEqual(try store.object(digest), data)
        let root = try XCTUnwrap(try store.objectRoot(digest))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: root) as? [String: Any])
        XCTAssertTrue(object["functions"] is NSNull)
        XCTAssertEqual(try store.migrateToPartedObjects(dryRun: false).indexed, 0)
    }

    /// A root from before the index gets it from the migration, once, and a
    /// dry run leaves the store as it was.
    func testTheMigrationGivesAnOldRootItsIndex() throws {
        let store = try store()
        let data = artifact("second")
        let digest = try store.putObject(data)
        let url = store.objectURL(digest)
        var old = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(try store.objectRoot(digest)))
            as? [String: Any])
        old["functions"] = nil
        let bare = try Gzip.compress(try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys]))
        try bare.write(to: url)
        XCTAssertEqual(try store.object(digest), data, "an old root reads as it did")

        XCTAssertEqual(try store.migrateToPartedObjects(dryRun: true).indexed, 1)
        XCTAssertEqual(try Data(contentsOf: url), bare)

        let report = try store.migrateToPartedObjects(dryRun: false)
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(try store.object(digest), data)
        XCTAssertTrue(PartedObject.hasIndex(try XCTUnwrap(try store.objectRoot(digest))))
        XCTAssertEqual(try store.migrateToPartedObjects(dryRun: false).indexed, 0)
    }

    /// What a server sends for an object is its gzip file, whatever form it
    /// lies in: a part, a plain object, or the whole of a cut one.
    func testAGzippedObjectIsTheWholeBytesInEveryForm() throws {
        let store = try store()
        let data = artifact("second")
        let digest = try store.putObject(data)
        XCTAssertEqual(Gzip.decompress(try store.gzippedObject(digest)), data)
        let part = try XCTUnwrap(store.parts(of: digest).first)
        XCTAssertEqual(try store.gzippedObject(part), try Data(contentsOf: store.objectURL(part)))
        let plain = Data("plain".utf8)
        let name = SHA256Digest(data: plain)
        try plain.write(to: store.objectURL(name))
        XCTAssertEqual(Gzip.decompress(try store.gzippedObject(name)), plain)
    }

    private func store(parted: Bool = true) throws -> ContentStore {
        let store = try ContentStore(root: folder)
        if parted { try store.enablePartedObjects() }
        return store
    }

    private func objectFiles(_ store: ContentStore) -> Int { store.contents(of: store.objectsURL).count }

    func testAnArtifactComesBackByteForByteAndSharesItsFunctions() throws {
        let store = try store()
        let one = artifact("one"), two = artifact("two")
        let first = try store.putObject(one)
        XCTAssertEqual(first, SHA256Digest(data: one), "the name is the hash of the whole")
        XCTAssertEqual(try store.object(first), one)
        // Root, two functions, the types.
        XCTAssertEqual(objectFiles(store), 4)
        let second = try store.putObject(two)
        XCTAssertEqual(try store.object(second), two)
        XCTAssertEqual(objectFiles(store), 6, "only the root and the function that changed are new")
        XCTAssertEqual(try store.verify(), [])
    }

    func testAnObjectThatIsNotAnArtifactIsOneGzipFile() throws {
        let store = try store()
        let text = Data("# A description\n".utf8)
        let name = try store.putObject(text)
        XCTAssertEqual(objectFiles(store), 1)
        let file = try Data(contentsOf: store.objectURL(name))
        XCTAssertEqual(Array(file.prefix(2)), [0x1F, 0x8B])
        XCTAssertEqual(try store.object(name), text)
    }

    func testTheSystemsGzipReadsTheFiles() throws {
        let store = try store()
        let text = Data(String(repeating: "A description. ", count: 100).utf8)
        let name = try store.putObject(text)
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gunzip.arguments = ["-dc"]
        let input = Pipe(), output = Pipe()
        gunzip.standardInput = input
        gunzip.standardOutput = output
        try gunzip.run()
        input.fileHandleForWriting.write(try Data(contentsOf: store.objectURL(name)))
        input.fileHandleForWriting.closeFile()
        let read = output.fileHandleForReading.readDataToEndOfFile()
        gunzip.waitUntilExit()
        XCTAssertEqual(gunzip.terminationStatus, 0, "the header and the trailer are gzip's")
        XCTAssertEqual(read, text)
    }

    func testAnObjectWrittenBeforeThePartsStillReads() throws {
        let plain = try store(parted: false)
        let bytes = artifact("one")
        let name = try plain.putObject(bytes)
        XCTAssertEqual(try Data(contentsOf: plain.objectURL(name)), bytes, "off until the store is switched")
        try plain.enablePartedObjects()
        XCTAssertEqual(try plain.object(name), bytes)
        XCTAssertEqual(try plain.verify(), [])
    }

    func testAMissingPartAndADamagedPartAreSaid() throws {
        let store = try store()
        let bytes = artifact("one")
        let name = try store.putObject(bytes)
        let part = try XCTUnwrap(store.parts(of: name).first)
        let kept = try Data(contentsOf: store.objectURL(part))
        try FileManager.default.removeItem(at: store.objectURL(part))
        XCTAssertThrowsError(try store.object(name))
        XCTAssertTrue(store.verify().contains { $0.contains("part \(part.hex) is missing") }, "\(store.verify())")
        // Damage in a part is caught by the hash of the whole.
        let other = try Gzip.compress(Data("{\"entry\":\"0x99\"}".utf8))
        try other.write(to: store.objectURL(part))
        XCTAssertThrowsError(try store.object(name))
        try kept.write(to: store.objectURL(part))
        XCTAssertEqual(try store.object(name), bytes)
    }

    func testACollectionKeepsAKeptArtifactsPartsAndDropsAnOrphansOwn() throws {
        let store = try store()
        let data = Data("m".utf8)
        let module = ModuleIdentity(sha256: SHA256Digest(data: data), size: data.count,
                              name: "M", kind: "TE",
                              language: "x86:LE:32:default", imageBase: "0x0")
        let recipe = AnalysisRecipe(id: "r", exporter: 9, ghidra: "12.2", script: "ExportCode.java")
        let kept = artifact("one")
        _ = try store.putAnalysis(module: module, recipe: recipe, artifact: kept)
        let keptName = SHA256Digest(data: kept)
        let orphan = try store.putObject(artifact("two"))
        let lonePart = try XCTUnwrap(store.parts(of: orphan).first { !store.parts(of: keptName).contains($0) })
        _ = try store.collectGarbage(dryRun: false)
        XCTAssertEqual(try store.object(keptName), kept, "its parts stayed")
        XCTAssertFalse(store.hasObject(orphan))
        XCTAssertFalse(store.hasObject(lonePart))
    }

    func testADryRunTouchesNothingAndAMigrationKeepsEveryByte() throws {
        let store = try store(parted: false)
        let text = Data("# A description\n".utf8)
        let one = artifact("one"), two = artifact("two")
        let names = try [one, two, text].map { try store.putObject($0) }
        func file(_ index: Int) throws -> Data { try Data(contentsOf: store.objectURL(names[index])) }

        let dry = try store.migrateToPartedObjects()
        XCTAssertEqual(dry.parted, 3)
        XCTAssertEqual(dry.cut, 2)
        XCTAssertEqual(dry.filesAfter, 7, "two roots, three functions, the types, the text")
        XCTAssertEqual(try file(0), one)
        XCTAssertEqual(objectFiles(store), 3)
        XCTAssertFalse(store.writesPartedObjects)

        let real = try store.migrateToPartedObjects(dryRun: false)
        XCTAssertEqual(real.problems, [])
        XCTAssertTrue(real.switched)
        XCTAssertTrue(store.writesPartedObjects)
        XCTAssertEqual(objectFiles(store), 7)
        XCTAssertNotEqual(try file(0), one)
        XCTAssertEqual(try store.object(names[0]), one)
        XCTAssertEqual(try store.object(names[1]), two)
        XCTAssertEqual(try store.object(names[2]), text)
        XCTAssertEqual(store.verify(), [])

        let again = try store.migrateToPartedObjects(dryRun: false)
        XCTAssertEqual(again.parted, 0, "a second run goes on from where the first stopped")
        XCTAssertEqual(again.alreadyParted, 7)
    }

    func testADamagedObjectStopsTheSwitchAndIsLeftAlone() throws {
        let store = try store(parted: false)
        let good = try store.putObject(artifact("one"))
        let bad = try store.putObject(Data("words".utf8))
        try Data("damage".utf8).write(to: store.objectURL(bad))
        let report = try store.migrateToPartedObjects(dryRun: false)
        XCTAssertEqual(report.problems.count, 1, "\(report.problems)")
        XCTAssertFalse(report.switched)
        XCTAssertFalse(store.writesPartedObjects)
        XCTAssertEqual(try Data(contentsOf: store.objectURL(bad)), Data("damage".utf8))
        XCTAssertEqual(try store.object(good), artifact("one"))
    }

    func testABundleCarriesTheWholeBytesBetweenStoresOfEitherForm() throws {
        let parted = try store()
        let data = Data("m".utf8)
        let module = ModuleIdentity(sha256: SHA256Digest(data: data), size: data.count, name: "M", kind: "TE",
                                    language: "x86:LE:32:default", imageBase: "0x0")
        let recipe = AnalysisRecipe(id: "r", exporter: 2, ghidra: "12.2", script: "ExportCode.java")
        let bytes = artifact("one")
        let manifest = try parted.putAnalysis(module: module, recipe: recipe, artifact: bytes)
        let bundle = folder.appendingPathComponent("bundle.zip")
        _ = try parted.exportBundle([try XCTUnwrap(manifest.key)], to: bundle)
        let plain = try ContentStore(root: folder.appendingPathComponent("other"))
        _ = try plain.importBundle(from: bundle)
        XCTAssertEqual(try Data(contentsOf: plain.objectURL(SHA256Digest(data: bytes))), bytes)
        XCTAssertEqual(try plain.object(SHA256Digest(data: bytes)), bytes)
    }

    func testJSONThatCannotBeCutIsKeptWhole() throws {
        for text in ["{\"functions\": []}", "[1, 2]", "{\"script_version\": 1, \"functions\": 3}", "not json"] {
            XCTAssertNil(PartedObject.segments(of: Data(text.utf8)), text)
        }
    }

    /// A store's real objects, each put into a parted store and read back.
    /// Reads `PARTS_STORE`, never writes to it. Skipped unless it is set.
    /// Against a migrated copy of a real store: a function read through the
    /// root is what reading it out of the whole gives. `PARTS_MIGRATED` names it.
    func testARealFunctionReadsAsFromTheWhole() throws {
        guard let path = ProcessInfo.processInfo.environment["PARTS_MIGRATED"] else {
            throw XCTSkip("PARTS_MIGRATED is not set")
        }
        let store = try ContentStore(root: URL(fileURLWithPath: path), create: false)
        var compared = 0, slowestPart = 0.0, slowestWhole = 0.0
        for manifest in store.analyses() where manifest.artifact.size > 1_000_000 {
            let digest = manifest.artifact.sha256
            let started = Date()
            let whole = try store.object(digest)
            let functions = try JSONDecoder().decode(CodeArtifact.self, from: whole).functions
            for function in stride(from: 0, to: functions.count, by: max(1, functions.count / 5)) {
                let entry = functions[function].entry
                let wholeRead = try CodeArtifact.decoding(whole, function: entry)
                slowestWhole = max(slowestWhole, Date().timeIntervalSince(started))
                let at = Date()
                let read = try store.artifact(digest, function: entry)
                slowestPart = max(slowestPart, Date().timeIntervalSince(at))
                XCTAssertEqual(read, wholeRead, "\(digest.hex) \(entry)")
                compared += 1
            }
        }
        print("REAL FUNCTION READS \(compared) slowest \(slowestPart) s, whole read and decode \(slowestWhole) s")
        XCTAssertGreaterThan(compared, 0)
    }

    func testARealStoreRoundTrips() throws {
        guard let path = ProcessInfo.processInfo.environment["PARTS_STORE"] else {
            throw XCTSkip("PARTS_STORE is not set")
        }
        let store = try store()
        let source = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("objects"),
                                                                includingPropertiesForKeys: nil)
        var total = 0, cut = 0, slowestRead = 0.0, reading = 0.0
        for file in files {
            let bytes = try Data(contentsOf: file)
            total += bytes.count
            let name = try store.putObject(bytes)
            XCTAssertEqual(name.hex, file.lastPathComponent)
            let started = Date()
            let back = try store.object(name)
            let took = Date().timeIntervalSince(started)
            reading += took
            slowestRead = max(slowestRead, took)
            XCTAssertEqual(back, bytes, file.lastPathComponent)
            if !store.parts(of: name).isEmpty { cut += 1 }
        }
        var stored = 0
        for file in store.contents(of: store.objectsURL) {
            stored += (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        print("PARTS objects \(files.count) cut \(cut) before \(total >> 20) MB after \(stored >> 20) MB",
              "files \(objectFiles(store)) slowest read \(Int(slowestRead * 1000)) ms",
              "mean read \(Int(reading / Double(max(files.count, 1)) * 1000)) ms")
    }
}
