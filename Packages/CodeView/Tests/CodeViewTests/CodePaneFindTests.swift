import AppKit
import XCTest
import CodeAnalysis
import Find
@testable import CodeView

/// The code panel's side of a search (#41): the bar stands over the code or
/// the description, never over the navigator; the search reads the C of the
/// function on screen, or the description while it is open; its matches are
/// drawn in the text that was searched.
@MainActor
final class CodePaneFindTests: XCTestCase {
    private let moduleBytes = Data([0x56, 0x5A] + [UInt8](repeating: 0, count: 14))

    private func manifest() -> AnalysisManifest {
        AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: moduleBytes),
                                   size: moduleBytes.count, name: "CpuPei", kind: "TE",
                                   language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(
                sha256: SHA256Digest(data: Data("artifact".utf8)), size: 8,
                mediaType: "application/json"),
            analyzedAt: "2026-10-25T15:00:00+00:00",
            stats: AnalysisStats(functions: 2, instructions: 2))
    }

    private func artifact() throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","program":{"image_base":"0x0"},
         "functions":[
          {"entry":"0x220","name":"First","c":"Status = Read(); Status = Check(Status); return Status;",
           "instructions":[{"address":"0x220","bytes":"56","mnemonic":"PUSH","text":"PUSH ESI"}]},
          {"entry":"0x355","name":"Second","c":"return Status;",
           "instructions":[{"address":"0x355","bytes":"57","mnemonic":"PUSH","text":"PUSH EDI"}]}
         ]}
        """.utf8))
    }

    private func paneInWindow() throws -> (CodePaneView, NSWindow) {
        let view = CodePaneView(manifest: manifest(), artifact: try artifact(),
                                moduleBytes: moduleBytes, hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.selectFunction(at: 0)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// A stand-in for the app's bar: a view with a height of its own.
    private func bar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return bar
    }

    private func inPane(_ view: NSView, _ pane: CodePaneView) -> NSRect {
        pane.convert(view.bounds, from: view)
    }

    private func waitForIndex(_ finder: TextFindIndexer) async throws {
        for _ in 0..<200 where finder.matches?.isComplete != true {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The bar takes the top of the code area: the code moves down by its
    /// height, the navigator does not move, and the bar does not reach over
    /// it. Taken away, the code gets the height back.
    func testTheBarStandsOverTheCodeNotTheNavigator() throws {
        let (pane, _) = try paneInWindow()
        let area = pane.codeAreaFrameInPane
        let navigatorList = try XCTUnwrap(pane.functionTableForTests.enclosingScrollView)
        let navigator = inPane(navigatorList, pane)
        let code = try XCTUnwrap(pane.cTextView.enclosingScrollView)
        let codeBefore = inPane(code, pane)
        let found = bar()
        pane.showFindBar(found)
        pane.layoutSubtreeIfNeeded()
        let shown = inPane(found, pane)
        XCTAssertTrue(pane.isFindBarShown)
        XCTAssertEqual(shown.height, 30, accuracy: 0.5)
        XCTAssertEqual(shown.minX, area.minX, accuracy: 0.5, "the code area's width")
        XCTAssertEqual(shown.width, area.width, accuracy: 0.5)
        XCTAssertFalse(shown.intersects(navigator), "never over the navigator")
        XCTAssertEqual(inPane(navigatorList, pane), navigator, "the navigator stays")
        XCTAssertEqual(codeBefore.maxY - inPane(code, pane).maxY, 30, accuracy: 0.5,
                       "the code's top moves down by the bar's height")
        XCTAssertLessThanOrEqual(inPane(code, pane).maxY, shown.minY, "under the bar")

        pane.hideFindBar()
        pane.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.isFindBarShown)
        XCTAssertTrue(found.isHidden)
        XCTAssertEqual(inPane(code, pane).maxY, codeBefore.maxY, accuracy: 0.5)
    }

    /// A search with the listing on screen reads the C: the pane shows it.
    func testASearchShowsTheCInPlaceOfTheListing() throws {
        let (pane, _) = try paneInWindow()
        pane.showDecompiledC(false)
        XCTAssertFalse(pane.showsDecompiledC)
        pane.showFindBar(bar())
        pane.prepareForFind()
        XCTAssertTrue(pane.showsDecompiledC)
        XCTAssertEqual(pane.findSide, .c)
    }

    /// The matches are drawn in the C under the dump's grey, and a match is
    /// selected where the reader is put on it.
    func testMatchesAreDrawnInTheCAndTheMatchIsSelected() async throws {
        let (pane, _) = try paneInWindow()
        pane.showFindBar(bar())
        pane.prepareForFind()
        let query = TextQuery(text: "Status", caseSensitive: true, wholeWord: true)
        let outcome = await pane.finder.find([query], from: 0, direction: .forward)
        guard case .found(_, _, let range, _) = outcome else { return XCTFail("\(outcome)") }
        try await waitForIndex(pane.finder)
        let text = pane.cTextView.string as NSString
        XCTAssertEqual(pane.paintedFindRanges(.c).count, 4)
        XCTAssertTrue(pane.paintedFindRanges(.c).allSatisfy { text.substring(with: $0) == "Status" })
        pane.showFindMatch(range)
        XCTAssertEqual(text.substring(with: pane.cTextView.selectedRange()), "Status")
        XCTAssertEqual(pane.findSelection, "Status", "what ⌘E takes")

        pane.hideFindBar()
        XCTAssertEqual(pane.paintedFindRanges(.c), [], "Done takes the showing away")
    }

    /// Another function on screen is other text: the search goes on over it,
    /// so its matches show there.
    func testAnotherFunctionIsSearchedAgain() async throws {
        let (pane, _) = try paneInWindow()
        pane.showFindBar(bar())
        pane.prepareForFind()
        let query = TextQuery(text: "Status", caseSensitive: true, wholeWord: true)
        _ = await pane.finder.find([query], from: 0, direction: .forward)
        try await waitForIndex(pane.finder)
        XCTAssertEqual(pane.finder.matches?.total, 4)

        pane.selectFunction(at: 1)
        try await waitForIndex(pane.finder)
        XCTAssertEqual(pane.finder.matches?.query, query, "the same search")
        XCTAssertEqual(pane.finder.matches?.total, 1, "over the second function's C")
        XCTAssertEqual(pane.paintedFindRanges(.c).count, 1)
    }

    /// With the description open, the search reads the description, and the
    /// matches are drawn there and not in the C.
    func testTheDescriptionIsSearchedWhileItIsOpen() async throws {
        let (pane, _) = try paneInWindow()
        pane.setModuleDescription("# CpuPei\n\nReads the Status of the CPU.")
        pane.showDescription(true)
        pane.showFindBar(bar())
        pane.prepareForFind()
        XCTAssertEqual(pane.findSide, .description)
        let outcome = await pane.finder.find([TextQuery(text: "status")], from: 0, direction: .forward)
        guard case .found = outcome else { return XCTFail("\(outcome)") }
        try await waitForIndex(pane.finder)
        XCTAssertEqual(pane.paintedFindRanges(.description).count, 1)
        XCTAssertEqual(pane.paintedFindRanges(.c), [])
    }
}
