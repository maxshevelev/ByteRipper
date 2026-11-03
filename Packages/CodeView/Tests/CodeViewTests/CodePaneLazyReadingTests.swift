import AppKit
import XCTest
import CodeAnalysis
@testable import CodeView

/// A pane opened on a cut artifact's index reads a function's code when it is
/// shown, and the rest only for what needs all of it.
@MainActor
final class CodePaneLazyReadingTests: XCTestCase {
    private func json(_ entry: String, _ name: String, code: Bool) -> String {
        let c = "void \(name)(void) { }"
        let body = code
            ? "\"c\":\"\(c)\",\"instructions\":[{\"address\":\"\(entry)\",\"bytes\":\"C3\",\"mnemonic\":\"RET\",\"text\":\"RET\"}]"
            : "\"fingerprint\":\"\(CodeArtifact.fingerprint(name: name, signature: nil, c: c))\""
        return "{\"entry\":\"\(entry)\",\"name\":\"\(name)\",\"size\":1,\(body)}"
    }

    private func artifact(code: Bool) throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":9,"program":{"image_base":"0x0"},"functions":[\(json("0x220", "Alpha", code: code)),\(json("0x330", "Beta", code: code))]}
        """.utf8))
    }

    private func manifest() -> AnalysisManifest {
        AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: Data([1])), size: 16, name: "M", kind: "TE",
                                   language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code", exporter: 2, ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(sha256: SHA256Digest(data: Data([2])), size: 1,
                                       mediaType: "application/json"),
            analyzedAt: "2026-11-03T00:00:00+00:00",
            stats: AnalysisStats(functions: 2, instructions: 2))
    }

    /// Every call of the loader, and its answer.
    @MainActor private final class Loader {
        var asked: [Set<CodeAddress>?] = []
        var failing = false
    }

    private func pane(_ loader: Loader) throws -> CodePaneView {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(code: false),
                                moduleBytes: Data(repeating: 0, count: 0x400), hexView: NSView())
        let whole = try artifact(code: true)
        view.onLoadFunctions = { [loader] entries in
            loader.asked.append(entries)
            if loader.failing { return nil }
            return whole.functions.filter { entries?.contains($0.entry) ?? true }
        }
        return view
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func code(in view: NSView) -> String {
        if let text = view as? CodeTextView { return text.string }
        return view.subviews.lazy.map(code(in:)).first { !$0.isEmpty } ?? ""
    }

    func testTheFunctionOnScreenIsReadAloneAndDrawn() async throws {
        let loader = Loader()
        let view = try pane(loader)
        XCTAssertFalse(code(in: view).contains("void Alpha"))
        await settle()
        XCTAssertEqual(loader.asked, [[CodeAddress(0x220)]])
        XCTAssertTrue(code(in: view).contains("void Alpha(void)"))
        XCTAssertEqual(view.currentModelForTest.pendingFunctions, [1], "the other one is left unread")
        XCTAssertNotNil(view.currentModelForTest.line(at: CodeAddress(0x220)))
    }

    /// What was not read says so, and is asked for again when the reader returns.
    func testAFailedReadSaysSoAndTriesAgainOnReturn() async throws {
        let loader = Loader()
        loader.failing = true
        let view = try pane(loader)
        await settle()
        XCTAssertTrue(code(in: view).contains("has not been read"))
        XCTAssertEqual(loader.asked.count, 1, "no asking over and over")

        loader.failing = false
        view.follow(.function(1))
        await settle()
        XCTAssertTrue(code(in: view).contains("void Beta(void)"))
        view.follow(.function(0))
        await settle()
        XCTAssertTrue(code(in: view).contains("void Alpha(void)"))
        XCTAssertTrue(view.currentModelForTest.pendingFunctions.isEmpty)
    }

    /// Who calls a function is in every function's code.
    func testCallersReadEverythingFirst() async throws {
        let loader = Loader()
        let view = try pane(loader)
        await settle()
        XCTAssertNil(view.showCallers(of: 0))
        await settle()
        XCTAssertEqual(loader.asked.count, 2)
        XCTAssertTrue(view.currentModelForTest.pendingFunctions.isEmpty)
    }

    /// A whole artifact asks for nothing.
    func testAWholeArtifactIsNeverRead() async throws {
        let loader = Loader()
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(code: true),
                                moduleBytes: Data(repeating: 0, count: 0x400), hexView: NSView())
        view.onLoadFunctions = { [loader] entries in
            loader.asked.append(entries)
            return nil
        }
        await settle()
        XCTAssertTrue(loader.asked.isEmpty)
    }
}
