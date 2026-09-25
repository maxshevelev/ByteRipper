import AppKit
import HelpBook
import XCTest
@testable import HelpUI

/// The renderer: the values a view draws, checked without a window.
final class HelpTextTests: XCTestCase {
    func testLinkURLsRoundTrip() {
        for link: HelpLink in [.topic(.hexView), .term(HelpTermID("fpt"))] {
            XCTAssertEqual(HelpText.link(from: HelpText.url(for: link)), link)
        }
    }

    func testAForeignURLIsNotOneOfOurs() {
        XCTAssertNil(HelpText.link(from: URL(string: "https://example.com")!))
        XCTAssertNil(HelpText.link(from: URL(string: "byteripper-help://nonsense/x")!))
    }

    /// A link in the prose comes out as a clickable run carrying its
    /// destination — which is the whole mechanism behind every cross-reference
    /// in the book.
    func testRenderedLinksCarryTheirDestination() {
        let rendered = HelpText.render([.paragraph(HelpMarkup.spans("see [[topic:colors|colours]]"))])
        var found: HelpLink?
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { found = HelpText.link(from: url) }
        }
        XCTAssertEqual(found, .topic(.colors))
        XCTAssertTrue(rendered.string.contains("colours"))
    }

    func testAPageRendersItsTitleAndSummary() throws {
        let topic = try XCTUnwrap(Help.shared.topic(.overview))
        let rendered = HelpText.render(topic)
        XCTAssertTrue(rendered.string.hasPrefix(topic.title))
        XCTAssertTrue(rendered.string.contains(topic.summary))
    }

    /// A term's brief form is the popover's: the sentence and the body, and
    /// none of the see-also list the window shows.
    func testBriefFormLeavesOutSeeAlso() throws {
        let term = try XCTUnwrap(Help.shared.term(HelpTermID("fpt")))
        XCTAssertFalse(term.seeAlso.isEmpty)
        XCTAssertFalse(HelpText.renderBrief(term).string.contains("See also"))
        XCTAssertTrue(HelpText.render(term).string.contains("See also"))
    }
}

/// The `?` buttons: what they are and where each one goes.
@MainActor
final class HelpButtonTests: XCTestCase {
    func testStandardIsThePlatformsRoundHelpButton() {
        let button = HelpButton.standard(for: .topic(.settings))
        XCTAssertEqual(button.bezelStyle, .helpButton)
        XCTAssertEqual(button.opens, .topic(.settings))
    }

    func testInlineIsAQuietGlyph() {
        let button = HelpButton.inline(for: .term(HelpTermID("fpt")))
        XCTAssertFalse(button.isBordered)
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.opens, .term(HelpTermID("fpt")))
    }

    /// The tooltip names the destination rather than saying "Help": a button
    /// that does not say where it goes is a button nobody presses twice.
    func testTheTooltipNamesTheDestination() throws {
        let button = HelpButton.standard(for: .topic(.colors))
        let title = try XCTUnwrap(Help.shared.topic(.colors)).title
        XCTAssertEqual(button.toolTip, "Help: " + title)
        XCTAssertEqual(button.accessibilityLabel(), "Help: " + title)
    }

    /// A caller may override the tooltip where the surrounding text already
    /// says what the button is about.
    func testAnExplicitTooltipWins() {
        XCTAssertEqual(HelpButton.inline(for: .topic(.search), tooltip: "About finding bytes").toolTip,
                       "About finding bytes")
    }
}

/// The window: what it shows, what its contents lists, what Back does.
@MainActor
final class HelpWindowTests: XCTestCase {
    private var controller: HelpWindowController!

    override func setUp() {
        super.setUp()
        controller = HelpWindowController()
    }

    override func tearDown() {
        controller.close()
        controller = nil
        super.tearDown()
    }

    func testItOpensOnTheOverview() {
        XCTAssertEqual(controller.shownLink, .topic(.overview))
        XCTAssertTrue(controller.shownText.contains("ByteRipper"))
    }

    func testTheContentsListsEverySectionAndGlossary() {
        let titles = controller.listedTitles
        for section in Help.shared.sections {
            XCTAssertTrue(titles.contains(section.name), "\(section.name) is not in the contents")
        }
        for group in HelpTermGroup.allCases {
            XCTAssertTrue(titles.contains(Help.shared.glossaryName(group)))
        }
    }

    func testShowingATermShowsIt() throws {
        let term = try XCTUnwrap(Help.shared.term(HelpTermID("fpt")))
        controller.show(.term(term.id))
        XCTAssertEqual(controller.shownLink, .term(term.id))
        XCTAssertTrue(controller.shownText.contains(term.name))
    }

    func testBackAndForward() {
        controller.show(.topic(.colors))
        controller.show(.term(HelpTermID("fpt")))
        controller.goBack()
        XCTAssertEqual(controller.shownLink, .topic(.colors))
        controller.goBack()
        XCTAssertEqual(controller.shownLink, .topic(.overview))
        controller.goForward()
        XCTAssertEqual(controller.shownLink, .topic(.colors))
    }

    /// Back at the beginning does nothing rather than emptying the window.
    func testBackAtTheStartIsHarmless() {
        controller.goBack()
        XCTAssertEqual(controller.shownLink, .topic(.overview))
    }

    func testSearchFiltersTheContentsAndClearingRestoresIt() {
        controller.search("checksum")
        let hits = controller.listedTitles
        XCTAssertTrue(hits.contains { $0.localizedCaseInsensitiveContains("checksum") })
        XCTAssertFalse(hits.contains(Help.shared.sections[0].name),
                       "a search should replace the contents, not add to it")
        controller.search("")
        XCTAssertTrue(controller.listedTitles.contains(Help.shared.sections[0].name))
    }

    func testASearchWithNoHitsSaysSo() {
        controller.search("zzzzzznothing")
        XCTAssertEqual(controller.listedTitles, ["No results"])
    }
}

/// The popover a panel shows for one row's term.
@MainActor
final class HelpTermPopoverTests: XCTestCase {
    func testItRefusesATermTheBookDoesNotHave() {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertNil(HelpTermPopover.show(HelpTermID("no-such-term"), from: anchor))
    }

    /// Built for a real term, it is about that term. (It is not presented here:
    /// a popover needs a view in a window, and what is worth pinning is which
    /// entry it carries.)
    func testItCarriesTheTermItWasBuiltFor() throws {
        let term = try XCTUnwrap(Help.shared.term(HelpTermID("mfs")))
        let popover = HelpTermPopover(term: term)
        XCTAssertEqual(popover.shownTerm, term.id)
        XCTAssertTrue(popover.view.subviews.contains { ($0 as? NSTextField)?.stringValue == term.name })
    }
}
