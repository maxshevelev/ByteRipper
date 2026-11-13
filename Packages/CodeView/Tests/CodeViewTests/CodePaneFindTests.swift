import AppKit
import XCTest
import CodeAnalysis
import Find
import Localization
import ToolModuleKit
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
        XCTAssertEqual(pane.findPlateRange?.side, .c, "the yellow stays on the match")
        XCTAssertEqual(pane.findPlateRange?.range, pane.cTextView.selectedRange())

        pane.cTextView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(pane.findPlateRange, "the selection moved off: the yellow goes")
        pane.showFindMatch(range)
        XCTAssertNotNil(pane.findPlateRange)

        pane.hideFindBar()
        XCTAssertNil(pane.findPlateRange, "Done takes the yellow away")
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

    // MARK: - The Search tab

    private func waitForSearch(_ pane: CodePaneView) async throws {
        for _ in 0..<400 where pane.isSearchingAllForTests {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The tab searches every function's C and lists the occurrences under
    /// each function, line by line.
    func testTheSearchTabListsEveryFunctionsOccurrences() async throws {
        let (pane, _) = try paneInWindow()
        var finished: (TextQuery, Bool)?
        pane.onSearchAllFinished = { finished = ($0, $1) }
        let query = TextQuery(text: "Status", caseSensitive: true, wholeWord: true)
        pane.searchAllFunctions(query)
        XCTAssertTrue(pane.showsSearchTab)
        try await waitForSearch(pane)
        XCTAssertEqual(pane.searchResultsForTests.map(\.function), ["First", "Second"])
        XCTAssertEqual(pane.searchResultsForTests[0].lines.count, 4)
        XCTAssertEqual(pane.searchResultsForTests[1].lines, ["return Status;"])
        XCTAssertEqual(finished?.0, query)
        XCTAssertEqual(finished?.1, true)

        pane.searchAllFunctions(TextQuery(text: "NoSuchName"))
        try await waitForSearch(pane)
        XCTAssertTrue(pane.searchResultsForTests.isEmpty)
        XCTAssertEqual(finished?.1, false)
    }

    /// A click on an occurrence opens its function on the C, with the
    /// occurrence selected — from the listing and from the description too.
    func testAnOccurrenceOpensItsFunctionOnTheMatch() async throws {
        let (pane, _) = try paneInWindow()
        pane.showDecompiledC(false)
        pane.searchAllFunctions(TextQuery(text: "Status", caseSensitive: true))
        try await waitForSearch(pane)
        // Rows: First, its four lines, Second, its one line.
        pane.chooseSearchRowForTests(6)
        XCTAssertEqual(pane.selectedFunction?.name, "Second")
        XCTAssertTrue(pane.showsDecompiledC)
        let text = pane.cTextView.string as NSString
        let selection = pane.cTextView.selectedRange()
        XCTAssertEqual(text.substring(with: selection), "Status")
        XCTAssertEqual(selection.location, text.range(of: "return Status").location + 7)

        pane.setModuleDescription("# CpuPei")
        pane.showDescription(true)
        pane.chooseSearchRowForTests(2)
        XCTAssertFalse(pane.showsDescription, "the code takes the description's place")
        XCTAssertEqual(pane.selectedFunction?.name, "First")
        XCTAssertEqual(text.length > 0, true)
        XCTAssertEqual((pane.cTextView.string as NSString).substring(with: pane.cTextView.selectedRange()), "Status")
    }

    /// A function or an occurrence opened from the tab shows every
    /// occurrence in the function under the find grey, the other function too; a cleared search takes it away.
    func testAnOpenedFunctionShowsEveryOccurrenceInGrey() async throws {
        let (pane, _) = try paneInWindow()
        pane.searchAllFunctions(TextQuery(text: "Status", caseSensitive: true, wholeWord: true))
        try await waitForSearch(pane)
        pane.chooseSearchRowForTests(0)
        let text = pane.cTextView.string as NSString
        XCTAssertEqual(pane.paintedFindRanges(.c).count, 4)
        XCTAssertTrue(pane.paintedFindRanges(.c).allSatisfy { text.substring(with: $0) == "Status" })
        pane.chooseSearchRowForTests(5)
        XCTAssertEqual(pane.selectedFunction?.name, "Second")
        XCTAssertEqual(pane.paintedFindRanges(.c).count, 1)

        // An occurrence: it is selected, and the others are grey around it.
        pane.chooseSearchRowForTests(3)
        XCTAssertEqual(pane.selectedFunction?.name, "First")
        XCTAssertEqual(pane.findSelection, "Status")
        XCTAssertEqual(pane.findPlateRange?.range, pane.cTextView.selectedRange(), "the yellow on it")
        XCTAssertEqual(pane.paintedFindRanges(.c).count, 3, "the other three grey; the yellow one has no grey under it")
        XCTAssertFalse(pane.paintedFindRanges(.c).contains(pane.cTextView.selectedRange()))
        pane.chooseSearchRowForTests(6)
        XCTAssertEqual(pane.findPlateRange?.side, .c, "another function: the yellow moves with it")
        XCTAssertEqual(pane.findPlateRange?.range, pane.cTextView.selectedRange())

        pane.searchAllFunctions(TextQuery(text: ""))
        XCTAssertEqual(pane.paintedFindRanges(.c), [])
    }

    /// The tab's rows follow the zoom, as the Functions list does: the
    /// names, the occurrences and their rows are drawn at the new size.
    func testTheTabFollowsTheZoom() async throws {
        let suite = "CodePaneFindTests.zoom"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let saved = ToolPanelFont.defaults
        ToolPanelFont.defaults = defaults
        defer {
            ToolPanelFont.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(13.0, forKey: ToolPanelFont.zoomSizeKey)
        let (pane, _) = try paneInWindow()
        pane.searchAllFunctions(TextQuery(text: "Status", caseSensitive: true))
        try await waitForSearch(pane)
        let outline = pane.searchPanel.outline
        func sizes() -> (name: CGFloat?, line: CGFloat?, row: CGFloat) {
            func size(_ row: Int) -> CGFloat? {
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
                let text = cell?.textField?.attributedStringValue
                return (text?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
            }
            return (size(0), size(1), outline.rect(ofRow: 1).height)
        }
        let small = sizes()
        XCTAssertEqual(small.name, CodePaneView.navigatorSize)

        defaults.set(18.0, forKey: ToolPanelFont.zoomSizeKey)
        NotificationCenter.default.post(name: ToolPanelFont.zoomDidChangeNotification, object: nil)
        pane.layoutSubtreeIfNeeded()
        let large = sizes()
        XCTAssertEqual(large.name, CodePaneView.navigatorSize, "the function's name")
        XCTAssertEqual(large.line, CodePaneView.navigatorSize, "the occurrence's line")
        XCTAssertGreaterThan(large.name ?? 0, small.name ?? 0)
        XCTAssertGreaterThan(large.row, small.row, "the row is measured again")
        XCTAssertEqual(pane.searchResultsForTests.count, 2, "the result stays")
        XCTAssertTrue(outline.isItemExpanded(outline.item(atRow: 0)))
    }

    /// A module the review placed wears its origin before its name.
    func testTheDescriptionRowWearsTheModulesOrigin() async throws {
        var placed = manifest()
        placed.reading = AnalysisReading(rev: 1, origin: ModuleOrigin(category: .edk2, confidence: .established))
        let pane = CodePaneView(manifest: placed, artifact: try artifact(), moduleBytes: moduleBytes, hexView: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane
        pane.setModuleDescription("# CpuPei\n\nReads the Status of the CPU.")
        pane.searchAllFunctions(TextQuery(text: "Status", caseSensitive: true))
        try await waitForSearch(pane)
        let row = try XCTUnwrap(pane.searchPanel.outline.view(atColumn: 0, row: 0, makeIfNecessary: true)
                                    as? CodeNavigatorCell)
        let words = try XCTUnwrap(row.textField?.attributedStringValue)
        let badge = try XCTUnwrap(words.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertNotNil(badge.image, "the origin's framed word before the name")
        XCTAssertTrue(words.string.hasSuffix("CpuPei " + L("Description")))
    }

    /// The chevron closes a group and opens it again.
    func testAGroupClosesAndOpens() async throws {
        let (pane, _) = try paneInWindow()
        pane.searchAllFunctions(TextQuery(text: "Status", caseSensitive: true))
        try await waitForSearch(pane)
        let panel = pane.searchPanel
        let first = try XCTUnwrap(panel.items.first)
        panel.toggle(first)
        XCTAssertFalse(panel.outline.isItemExpanded(first))
        XCTAssertEqual(panel.outline.numberOfRows, 3, "First, Second and its one line")
        panel.toggle(first)
        XCTAssertTrue(panel.outline.isItemExpanded(first))
        XCTAssertEqual(panel.outline.numberOfRows, 7)
    }

    /// The description is searched with the functions, listed first, and its
    /// occurrence opens the description on the match. The scope narrows the
    /// search to one or the other.
    func testTheSearchTabSearchesTheDescriptionToo() async throws {
        let (pane, _) = try paneInWindow()
        pane.setModuleDescription("# CpuPei\n\nReads the Status of the CPU.")
        pane.searchAllFunctions(TextQuery(text: "Status", caseSensitive: true, wholeWord: true))
        try await waitForSearch(pane)
        XCTAssertEqual(pane.searchResultsForTests.map(\.function), ["CpuPei", "First", "Second"],
                       "the description under the module's name")
        XCTAssertEqual(pane.searchResultsForTests[0].lines, ["Reads the Status of the CPU."])
        XCTAssertEqual(pane.searchSummaryForTests,
                       L("%1$@ results in %2$@ functions and the description", "6", "2"))

        let outline = pane.searchPanel.outline
        let row = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CodeNavigatorCell)
        XCTAssertEqual(row.iconName, "book")
        let words = try XCTUnwrap(row.textField?.attributedStringValue)
        XCTAssertTrue(words.string.hasSuffix("CpuPei " + L("Description")))
        XCTAssertTrue(words.string.hasPrefix("CpuPei"), "no origin: no badge before the name")
        let description = (words.string as NSString).range(of: L("Description"))
        XCTAssertEqual(words.attribute(.foregroundColor, at: description.location, effectiveRange: nil) as? NSColor,
                       .secondaryLabelColor)

        pane.chooseSearchRowForTests(1)
        XCTAssertTrue(pane.showsDescription)
        let view = pane.descriptionView.textView
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "Status")

        pane.setSearchScopeForTests(everywhere: false, functions: true)
        try await waitForSearch(pane)
        XCTAssertEqual(pane.searchResultsForTests.map(\.function), ["First", "Second"])
        pane.setSearchScopeForTests(everywhere: false, functions: false)
        try await waitForSearch(pane)
        XCTAssertEqual(pane.searchResultsForTests.map(\.function), ["CpuPei"])
        XCTAssertEqual(pane.searchSummaryForTests, L("1 result in the description"))
    }

    /// One result, or one function, is said in the singular.
    func testTheSummarySaysOneInTheSingular() {
        func line(_ hits: Int, _ functions: Int, description: Bool = false, truncated: Bool = false) -> String {
            CodeSearchPanel.summary(hits: hits, functions: functions, inDescription: description, truncated: truncated)
        }
        XCTAssertEqual(line(0, 0), "No results")
        XCTAssertEqual(line(1, 1), "1 result in 1 function")
        XCTAssertEqual(line(3, 1), "3 results in 1 function")
        XCTAssertEqual(line(3, 2), "3 results in 2 functions")
        XCTAssertEqual(line(1, 0, description: true), "1 result in the description")
        XCTAssertEqual(line(2, 0, description: true), "2 results in the description")
        XCTAssertEqual(line(2, 1, description: true), "2 results in 1 function and the description")
        XCTAssertEqual(line(5, 2, description: true), "5 results in 2 functions and the description")
        XCTAssertEqual(line(5000, 1, truncated: true), "The first 5000 results in 1 function — refine the pattern")
        XCTAssertEqual(line(5000, 7, truncated: true), "The first 5000 results in 7 functions — refine the pattern")
    }

    /// An occurrence is bold, with no fill under it; a match far into a
    /// long line is brought forward behind an ellipsis.
    func testAnOccurrenceIsBoldWithoutAFill() {
        let lineText = String(repeating: "word ", count: 20) + "Status = 0;"
        let start = (lineText as NSString).range(of: "Status").location
        let hit = TextSearchHit(range: 0..<6, line: 0, lineText: lineText, rangeInLine: start..<(start + 6))
        let line = CodeSearchPanel.line(of: hit)
        XCTAssertTrue(line.string.hasPrefix("…"))
        let at = (line.string as NSString).range(of: "Status")
        XCTAssertLessThan(at.location, CodeSearchPanel.leadingContext + 2)
        var effective = NSRange()
        let font = line.attribute(.font, at: at.location, effectiveRange: &effective) as? NSFont
        XCTAssertEqual(effective, at, "the match alone")
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertNil(line.attribute(.backgroundColor, at: at.location, effectiveRange: nil))
    }

    /// The tab takes the filter's bar away, and the keyboard out of the
    /// filter: its focus ring would be drawn over the tab.
    func testTheTabHidesTheFilterAndItsFocus() throws {
        let (pane, window) = try paneInWindow()
        let filter = try XCTUnwrap(all(NSSearchField.self, in: pane).first)
        window.makeFirstResponder(filter)
        pane.showSearchTab(true)
        XCTAssertTrue(filter.isHiddenOrHasHiddenAncestor)
        let responder = window.firstResponder as? NSView
        XCTAssertFalse(responder?.isDescendant(of: filter) ?? false, "the filter lets the keyboard go")
        pane.showSearchTab(false)
        XCTAssertFalse(filter.isHiddenOrHasHiddenAncestor)
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { all(type, in: $0) }
    }

    /// Choosing a list puts the lists back in front of the tab.
    func testAListTakesTheTabsPlace() throws {
        let (pane, _) = try paneInWindow()
        pane.showSearchTab(true)
        XCTAssertTrue(pane.showsSearchTab)
        pane.selectList(.strings)
        pane.showSearchTab(false)
        XCTAssertFalse(pane.showsSearchTab)
    }
}
