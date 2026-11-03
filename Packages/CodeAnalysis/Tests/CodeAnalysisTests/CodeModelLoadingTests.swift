import Foundation
import XCTest
@testable import CodeAnalysis

/// A model made from a cut artifact's index and given its functions' code as
/// they are read reads as one made from the whole artifact.
final class CodeModelLoadingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeModelLoadingTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func function(_ entry: Int, _ name: String, calling target: Int?) -> [String: Any] {
        let first = String(entry, radix: 16), second = String(entry + 5, radix: 16)
        var call: [String: Any] = ["address": "0x\(first)", "bytes": "E8", "mnemonic": "CALL", "text": "CALL"]
        if let target {
            call["references"] = [["to": "0x\(String(target, radix: 16))", "type": "UNCONDITIONAL_CALL"]]
        }
        return [
            "entry": "0x\(first)", "name": name, "signature": "void \(name)(void)", "size": 6,
            "c": "void \(name)(void) { /* \(String(repeating: name, count: 40)) */ }",
            "instructions": [call, ["address": "0x\(second)", "bytes": "C3", "mnemonic": "RET", "text": "RET"]]
        ]
    }

    private func stored() throws -> (ContentStore, SHA256Digest, CodeArtifact) {
        let store = try ContentStore(root: folder)
        try store.enablePartedObjects()
        let data = try JSONSerialization.data(withJSONObject: [
            "script_version": 9, "program": ["image_base": "0x0"],
            "functions": [function(0x100, "Alpha", calling: 0x300),
                          function(0x200, "Beta", calling: 0x300),
                          function(0x300, "Gamma", calling: nil)]
        ], options: [.sortedKeys])
        return (store, try store.putObject(data), try JSONDecoder().decode(CodeArtifact.self, from: data))
    }

    func testAnIndexHoldsNamesAndNoCode() throws {
        let (store, digest, whole) = try stored()
        let skeleton = try XCTUnwrap(try store.skeleton(of: digest))
        XCTAssertEqual(skeleton.functions.map(\.name), whole.functions.map(\.name))
        XCTAssertTrue(skeleton.functions.allSatisfy { $0.codeIsPending && $0.c == nil && $0.instructions.isEmpty })
        XCTAssertEqual(skeleton.functions.map(\.readingFingerprint), whole.functions.map(\.readingFingerprint))

        let model = CodeModel(artifact: skeleton, moduleBytes: Data())
        XCTAssertEqual(model.pendingFunctions, [0, 1, 2])
        XCTAssertEqual(model.lines.count, 0)
        XCTAssertEqual(model.pendingFunction(holding: CodeAddress(0x205)), 1)
        XCTAssertNil(model.pendingFunction(holding: CodeAddress(0x206)))
        XCTAssertEqual(model.function(at: CodeAddress(0x200)), 1)
    }

    /// The order they are read in leaves the places already handed out alone,
    /// and what the model says in the end is what the whole one says.
    func testFunctionsReadInAnyOrderEndAsTheWhole() throws {
        let (store, digest, whole) = try stored()
        var model = CodeModel(artifact: try XCTUnwrap(try store.skeleton(of: digest)), moduleBytes: Data())

        model.load(try store.functions([CodeAddress(0x300)], of: digest))
        XCTAssertEqual(model.pendingFunctions, [0, 1])
        let gammaLine = try XCTUnwrap(model.line(at: CodeAddress(0x300)))
        XCTAssertEqual(model.lines[gammaLine].function, 2)
        XCTAssertNotNil(model.functions[2].c)
        XCTAssertNil(model.functions[1].c)
        XCTAssertEqual(model.uses(of: CodeAddress(0x300)).count, 0, "the callers are not read yet")

        model.load(try store.functions(nil, of: digest))
        XCTAssertTrue(model.pendingFunctions.isEmpty)
        XCTAssertEqual(model.line(at: CodeAddress(0x300)), gammaLine, "a line keeps its place")
        XCTAssertEqual(model.lines[gammaLine].instruction.address, CodeAddress(0x300))

        let reference = CodeModel(artifact: whole, moduleBytes: Data())
        XCTAssertEqual(model.functions.map(\.c), reference.functions.map(\.c))
        XCTAssertEqual(model.functions.map(\.readingFingerprint), reference.functions.map(\.readingFingerprint))
        XCTAssertEqual(model.uses(of: CodeAddress(0x300)).map(\.from), reference.uses(of: CodeAddress(0x300)).map(\.from))
        XCTAssertEqual(Set(model.lines.map(\.instruction.address)), Set(reference.lines.map(\.instruction.address)))
    }

    /// An artifact kept whole, or written before the index, is not pending.
    func testAWholeArtifactHasNothingPending() throws {
        let (_, _, whole) = try stored()
        XCTAssertTrue(CodeModel(artifact: whole, moduleBytes: Data()).pendingFunctions.isEmpty)
        let store = try ContentStore(root: folder)
        XCTAssertNil(try store.skeleton(of: try store.putObject(Data("not an artifact".utf8))))
    }
}

/// Against a real store, read only: `PARTS_MIGRATED=<root>`.
final class CodeModelLoadingRealStoreTests: XCTestCase {
    func testRealArtifactsOpenFastAndEndAsTheWhole() throws {
        guard let path = ProcessInfo.processInfo.environment["PARTS_MIGRATED"] else {
            throw XCTSkip("PARTS_MIGRATED is not set")
        }
        let store = try ContentStore(root: URL(fileURLWithPath: path), create: false)
        var checked = 0, slowestOpen = 0.0, slowestWhole = 0.0, functions = 0
        for manifest in store.analyses() {
            let digest = manifest.artifact.sha256
            let begun = Date()
            guard let skeleton = try store.skeleton(of: digest) else { continue }
            var model = CodeModel(artifact: skeleton, moduleBytes: Data())
            slowestOpen = max(slowestOpen, Date().timeIntervalSince(begun))
            let begunWhole = Date()
            let whole = try store.artifact(for: manifest)
            let reference = CodeModel(artifact: whole, moduleBytes: Data())
            slowestWhole = max(slowestWhole, Date().timeIntervalSince(begunWhole))
            XCTAssertEqual(skeleton.functions.map(\.readingFingerprint), whole.functions.map(\.readingFingerprint), digest.hex)
            if let middle = skeleton.functions.indices.dropFirst(skeleton.functions.count / 2).first {
                model.load(try store.functions([skeleton.functions[middle].entry], of: digest))
                XCTAssertEqual(model.functions[middle].c, whole.functions[middle].c, digest.hex)
            }
            model.load(try store.functions(nil, of: digest))
            XCTAssertTrue(model.pendingFunctions.isEmpty, digest.hex)
            XCTAssertEqual(model.functions.map(\.c), whole.functions.map(\.c), digest.hex)
            XCTAssertEqual(Set(model.lines.map(\.instruction.address)), Set(reference.lines.map(\.instruction.address)), digest.hex)
            checked += 1
            functions += whole.functions.count
        }
        print("real store: \(checked) artifacts, \(functions) functions; slowest index open \(slowestOpen) s, slowest whole \(slowestWhole) s")
        XCTAssertGreaterThan(checked, 0)
    }
}
