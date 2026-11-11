import XCTest
import CodeAnalysis
import CodeView
import Localization
import PartCodec
@testable import ByteRipper

/// The Find bar over a code pane (#41): it stands over the code, not across
/// the surface; it searches the C of the function on screen; ⌘G steps
/// through the matches and wraps as in the dump; Done takes it away; ⌘E
/// takes the selected C.
@MainActor
final class CodeFindBarTests: XCTestCase {
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var cleanups: [() -> Void] = []

    override func setUp() {
        super.setUp()
        installToolStubs()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        FindHistoryStore.defaults = defaults
        CodeFindHistoryStore.defaults = defaults
        FindBarView.defaults = defaults
        ToolController.defaults = defaults
        DocumentSurface.minimapDefaults = defaults
    }

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups = []
        FindHistoryStore.defaults = AppDefaults.store
        CodeFindHistoryStore.defaults = AppDefaults.store
        FindBarView.defaults = AppDefaults.store
        ToolController.defaults = .standard
        DocumentSurface.minimapDefaults = .standard
        discardIsolatedDefaults(defaultsName, defaults)
        defaults = nil
        super.tearDown()
    }

    private let cText = "Status = Read(); Status = Check(Status); return Status;"

    private func artifact() throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","functions":[
          {"entry":"0x0","name":"entry","c":"\(cText)","instructions":[
            {"address":"0x0","bytes":"90","mnemonic":"NOP","text":"NOP"}]}]}
        """.utf8))
    }

    private func manifest(for bytes: Data) -> AnalysisManifest {
        AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: bytes), size: bytes.count,
                                   name: "CpuPei", kind: "TE",
                                   language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2,
                                   ghidra: "12.1.2", script: "ExportCode.java"),
            artifact: AnalysisArtifact(sha256: SHA256Digest(data: Data("artifact".utf8)), size: 8,
                                       mediaType: "application/json"),
            analyzedAt: "2026-10-25T15:00:00+00:00",
            stats: AnalysisStats())
    }

    /// A window whose tab is a module's code screen, on its C.
    private func codeTab() throws -> (MainViewController, CodePaneView) {
        let bytes = [UInt8](repeating: 0x90, count: 0x100)
        let controller = MainViewController()
        let window = makeTestWindow(width: 1400, height: 700)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: 700))
        let url = try tempFile(bytes)
        try controller.windowModel.pane1.open(url: url)
        controller.installCodeScreen(CodeScreen(manifest: manifest(for: Data(bytes)),
                                                artifact: try artifact(), bytes: Data(bytes),
                                                selectedFunction: 0, selectedInstruction: 0,
                                                showsC: true),
                                     on: controller.windowModel.pane1)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        cleanups.append {
            controller.windowModel.pane1.close()
            try? FileManager.default.removeItem(at: url)
            window.close()
        }
        return (controller, try XCTUnwrap(controller.codeScreenView))
    }

    private func waitUntil(_ condition: () -> Bool, _ message: String) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message)
    }

    /// ⌘F over a code tab: the bar is the code's — no encoding, the
    /// whole-word toggle — and it stands in the code pane, over the code,
    /// not across the surface.
    func testTheBarOfACodeTabStandsOverTheCode() throws {
        let (controller, code) = try codeTab()
        controller.findPattern()
        let bar = controller.findBar
        XCTAssertEqual(bar.profile, .code)
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.isDescendant(of: code), "in the code pane")
        XCTAssertTrue(code.isFindBarShown)
        XCTAssertNil(controller.surface.shownFindBar, "not across the surface")
    }

    /// Return finds in the C and puts the reader on the match; ⌘G steps
    /// through the rest, wraps round to the first, and the count follows.
    func testReturnAndFindNextStepThroughTheCAndWrap() async throws {
        let (controller, code) = try codeTab()
        controller.findPattern()
        let bar = controller.findBar
        bar.wholeWordRule = true
        bar.setPatternTextForTests("Status")
        bar.pressFindForTests(.forward)
        try await waitUntil({ code.findSelection == "Status" }, "on the first match")
        try await waitUntil({ bar.countTextForTests == L("%1$@ of %2$@", "1", "4") }, "the count")
        XCTAssertEqual(CodeFindHistoryStore.recent.first?.pattern, "Status", "a search that found is kept")

        for ordinal in 2...4 {
            controller.findNextMatch()
            try await waitUntil({ bar.countTextForTests == L("%1$@ of %2$@", "\(ordinal)", "4") },
                               "step to \(ordinal)")
        }
        controller.findNextMatch()
        try await waitUntil({ bar.countTextForTests == L("%1$@ of %2$@", "1", "4") }, "wrapped to the first")
        XCTAssertEqual(code.findSelection, "Status")
    }

    /// A text the C does not hold: the count says so.
    func testNothingFoundIsSaidInTheCount() async throws {
        let (controller, _) = try codeTab()
        controller.findPattern()
        let bar = controller.findBar
        bar.setPatternTextForTests("NoSuchName")
        bar.pressFindForTests(.forward)
        try await waitUntil({ bar.countTextForTests == L("Not found") }, "not found")
    }

    /// Done takes the bar away and the code gets its height back.
    func testDoneTakesTheBarAway() async throws {
        let (controller, code) = try codeTab()
        controller.findPattern()
        let bar = controller.findBar
        bar.setPatternTextForTests("Read")
        bar.pressFindForTests(.forward)
        try await waitUntil({ code.findSelection == "Read" }, "found")
        controller.frontFind.hide()
        XCTAssertTrue(bar.isHidden)
        XCTAssertFalse(code.isFindBarShown)
        XCTAssertNil(code.finder.highlightedMatches, "the showing goes with the bar")
    }

    /// ⌘E over the code takes the selected C, not the module's bytes.
    func testUseSelectionForFindTakesTheSelectedC() async throws {
        let (controller, code) = try codeTab()
        controller.findPattern()
        let bar = controller.findBar
        bar.setPatternTextForTests("Check")
        bar.pressFindForTests(.forward)
        try await waitUntil({ code.findSelection == "Check" }, "found")
        bar.setPatternTextForTests("something else")
        controller.useSelectionForFind()
        XCTAssertEqual(bar.patternTextForTests, "Check")
    }

    /// A code panel taken out over the dump has its own bar, over its code;
    /// the tab's dump keeps its byte bar.
    func testACodePanelsBarStandsOverItsCode() throws {
        let controller = MainViewController()
        let window = makeTestWindow(width: 1400, height: 700)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: 700))
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x400))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let bytes = CodeAgentTests.teModule()
        controller.openCode(
            named: "CpuPei body", from: controller.windowModel.pane1, source: 0x100..<0x160,
            manifest: manifest(for: bytes), artifact: try artifact(),
            codec: ReadOnlyPartCodec([UInt8](bytes), title: L("This cannot be put back"),
                                     reason: L("A code analysis is a snapshot; edit the dump and analyze the module again.")))
        let id = try XCTUnwrap(controller.fragments.expanded)
        cleanups.append {
            controller.fragments.close(id, animated: false)
            controller.windowModel.pane1.close()
            try? FileManager.default.removeItem(at: url)
            window.close()
        }
        window.layoutIfNeeded()
        let code = try XCTUnwrap(controller.fragments.codePane(id))
        let surface = try XCTUnwrap(controller.fragments.surface(id))

        controller.findPattern()
        XCTAssertTrue(controller.frontFind === surface.find, "the panel in front has the keyboard's bar")
        XCTAssertEqual(surface.find.bar.profile, .code)
        XCTAssertTrue(surface.find.bar.isDescendant(of: code))
        XCTAssertNil(surface.shownFindBar)
        XCTAssertEqual(controller.surface.find.bar.profile, .hexDump, "the tab's bar reads bytes")
    }
}
