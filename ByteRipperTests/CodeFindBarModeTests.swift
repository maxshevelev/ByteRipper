import XCTest
import Localization
@testable import ByteRipper

/// The Find bar in the code panel's mode (#41): what it shows, what it asks
/// for, and its own history of recent queries.
@MainActor
final class CodeFindBarModeTests: XCTestCase {
    private var defaultsName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        FindHistoryStore.defaults = defaults
        CodeFindHistoryStore.defaults = defaults
        FindBarView.defaults = defaults
    }

    override func tearDown() {
        FindHistoryStore.defaults = AppDefaults.store
        CodeFindHistoryStore.defaults = AppDefaults.store
        FindBarView.defaults = AppDefaults.store
        discardIsolatedDefaults(defaultsName, defaults)
        defaults = nil
        super.tearDown()
    }

    private func codeBar() -> FindBarView {
        let bar = FindBarView()
        bar.mode = .code
        return bar
    }

    private func isShown(_ view: NSView) -> Bool { !view.isHidden }

    func testCodeShowsTheTextControlsAndNotTheDumpOnes() {
        let bar = codeBar()
        XCTAssertFalse(isShown(bar.query.encodingPopup), "no encoding to choose in C")
        XCTAssertFalse(isShown(bar.smartButton))
        XCTAssertTrue(isShown(bar.caseButton))
        XCTAssertTrue(isShown(bar.wordButton))
        XCTAssertFalse(isShown(bar.findAllButtonForTests),
                       "no results button: the code's list is the navigator's")
    }

    func testTheDumpBarHasNoWholeWordToggle() {
        let bar = FindBarView()
        XCTAssertFalse(isShown(bar.wordButton))
        XCTAssertTrue(isShown(bar.query.encodingPopup))
        XCTAssertTrue(isShown(bar.findAllButtonForTests))
    }

    func testCodeAsksForTextUnderBothRules() {
        let bar = codeBar()
        bar.setPatternTextForTests("Status")
        bar.query.caseRule = true
        bar.wholeWordRule = true
        XCTAssertEqual(bar.query.searchRequest(), .text("Status", caseSensitive: true, wholeWord: true))
        bar.setPatternTextForTests("DE AD")
        bar.query.caseRule = false
        bar.wholeWordRule = false
        XCTAssertEqual(bar.query.searchRequest(), .text("DE AD", caseSensitive: false, wholeWord: false),
                       "hex digits are text in C")
    }

    func testAnEmptyFieldAsksForNothing() {
        let bar = codeBar()
        var said: String?
        bar.onError = { said = $0 }
        bar.setPatternTextForTests("")
        XCTAssertNil(bar.query.searchRequest())
        XCTAssertNotNil(said)
    }

    func testCodeKeepsItsOwnRecents() {
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)
        let bar = codeBar()
        bar.setPatternTextForTests("EfiStatus")
        bar.wholeWordRule = true
        bar.query.noteSearchStarted(recording: true)
        bar.query.recordFoundCodeSearch()

        XCTAssertEqual(CodeFindHistoryStore.recent,
                       [CodeQueryEntry(pattern: "EfiStatus", caseSensitive: false, wholeWord: true)])
        XCTAssertEqual(FindHistoryStore.recent.map(\.pattern), ["DE AD"], "the dump's list is untouched")
        let rows = bar.patternMenuRowsForTests
        XCTAssertTrue(rows.contains { $0.hasPrefix("\"EfiStatus\"") })
        XCTAssertFalse(rows.contains { $0.hasPrefix("\"DE AD\"") }, "a byte pattern is not offered in C")
        XCTAssertFalse(rows.contains(L("Manage Search Patterns…")), "no pattern library in C")

        let dumpBar = FindBarView()
        XCTAssertFalse(dumpBar.patternMenuRowsForTests.contains { $0.hasPrefix("\"EfiStatus\"") },
                       "and a name is not offered in a dump")
    }

    func testPickingARecentLoadsItsRulesAndRunsIt() {
        CodeFindHistoryStore.record(CodeQueryEntry(pattern: "Size", caseSensitive: true, wholeWord: true))
        let bar = codeBar()
        var ran: FindBarView.Request?
        bar.onSearch = { request, _ in ran = request }
        XCTAssertTrue(bar.pickPatternRowForTests(startingWith: "\"Size\""))
        XCTAssertEqual(ran, .text("Size", caseSensitive: true, wholeWord: true))
    }

    func testOpeningOffersTheLastCodeQuery() {
        FindHistoryStore.record(pattern: "DE AD", encoding: .hex)
        CodeFindHistoryStore.record(CodeQueryEntry(pattern: "gBS", caseSensitive: false, wholeWord: false))
        let bar = codeBar()
        bar.prepareForShow()
        XCTAssertEqual(bar.patternTextForTests, "gBS")
    }

    func testAToggleOfOneBarDoesNotMoveAnother() {
        let first = codeBar()
        let second = codeBar()
        first.wordButton.performClick(nil)
        XCTAssertTrue(first.wholeWordRule)
        second.prepareForShow()
        XCTAssertFalse(second.wholeWordRule, "each bar keeps its own rule")
        XCTAssertTrue(codeBar().wholeWordRule, "a new bar starts with the last choice")
    }
}
