import AppKit
import XCTest
import CodeAnalysis
@testable import CodeView

/// The pane the app puts beside a module's bytes: at this stage it says what
/// the analysis is, and that the listing is still to come
/// (`Design/CODE_PANEL_PLAN.md`).
@MainActor
final class CodePaneViewTests: XCTestCase {
    func testThePlaceholderNamesTheModuleAndTheRecipe() {
        let bytes = Data("module".utf8)
        let manifest = AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: bytes), size: bytes.count,
                                   name: "CpuPei", kind: "TE",
                                   language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(
                sha256: SHA256Digest(data: Data("artifact".utf8)), size: 8,
                mediaType: "application/json"),
            analyzedAt: "2026-10-25T15:00:00+00:00",
            stats: AnalysisStats(functions: 13, instructions: 508))

        let view = CodePaneView(manifest: manifest)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        view.layoutSubtreeIfNeeded()

        let words = labels(in: view)
        XCTAssertTrue(words.contains("CpuPei"))
        XCTAssertTrue(words.contains("code-v2-ghidra-12.1.2"))
        XCTAssertTrue(words.contains("Code analysis"))
        XCTAssertFalse(view.hasAmbiguousLayout)
    }

    private func labels(in view: NSView) -> [String] {
        view.subviews.flatMap { subview in
            (subview as? NSTextField).map { [$0.stringValue] } ?? []
        } + view.subviews.flatMap(labels)
    }
}
