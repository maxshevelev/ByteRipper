import HelpBook
import HelpUI
import XCTest
@testable import ByteRipper

/// The Help menu: what it offers and where each item goes.
///
/// The book's own tests prove every page exists and every link resolves; these
/// prove the app points at pages that are in it — a menu item naming a page
/// nobody wrote would otherwise open an empty window on a bench.
@MainActor
final class HelpMenuTests: XCTestCase {
    func testTheMenuOffersTheBenchsOwnDoors() {
        let titles = MainMenu.makeHelpMenu().items.map(\.title)
        XCTAssertEqual(titles.first, "ByteRipper Help")
        XCTAssertTrue(titles.contains("Bench Rules"))
        XCTAssertTrue(titles.contains("Glossary: Intel ME"))
    }

    /// ⌘? — the key every Mac app opens its help on.
    func testTheFirstItemCarriesTheStandardKey() throws {
        let first = try XCTUnwrap(MainMenu.makeHelpMenu().items.first)
        XCTAssertEqual(first.keyEquivalent, "?")
        XCTAssertEqual(first.keyEquivalentModifierMask, [.command])
    }

    /// Every row carries its destination, and every destination is in the book.
    func testEveryItemPointsAtSomethingTheBookHolds() {
        for item in MainMenu.makeHelpMenu().items where !item.isSeparatorItem {
            guard let link = item.representedObject as? HelpLink else {
                return XCTFail("“\(item.title)” carries no destination")
            }
            XCTAssertTrue(Help.shared.destinationExists(link),
                          "“\(item.title)” points at \(link), which the book does not hold")
        }
    }

    /// Two guards against AppKit answering for the menu instead of the app,
    /// both of which it did: `showHelp(_:)` is `NSApplication`'s own action and
    /// was answered by AppKit with "Help isn't available for ByteRipper", and
    /// an item with no target is left to a responder chain that reaches
    /// `NSApplication` first.
    func testEveryItemIsAddressedToTheAppRatherThanToAppKit() {
        let target = AppDelegate()
        for item in MainMenu.makeHelpMenu(target: target).items where !item.isSeparatorItem {
            XCTAssertEqual(item.action, #selector(AppDelegate.showHelpBook(_:)),
                           "“\(item.title)” is wired to something else")
            XCTAssertNotEqual(item.action, Selector(("showHelp:")),
                              "“\(item.title)” is wired to NSApplication's own action")
            XCTAssertTrue(item.target === target,
                          "“\(item.title)” has no target, so AppKit answers for it")
        }
    }

    /// The bar as the app actually builds it: the Help items must carry the
    /// target there too, not only when the submenu is built on its own.
    func testTheBarWiresTheHelpMenuToTheApp() throws {
        let delegate = AppDelegate()
        let bar = MainMenu.build(appTarget: delegate)
        let help = try XCTUnwrap(bar.items.last?.submenu, "a Help submenu at the end of the bar")
        for item in help.items where !item.isSeparatorItem {
            XCTAssertTrue(item.target === delegate, "“\(item.title)” is not addressed to the app")
        }
    }
}

/// The `?` buttons the app puts beside the things they explain.
@MainActor
final class HelpButtonWiringTests: XCTestCase {
    /// The panel header's `?` names the page the running tool-module declared.
    func testTheToolPanelHeaderOffersTheRunningModulesPage() {
        let panel = ToolPanelView()
        panel.setHelpTopic(StubToolA.helpTopic)
        XCTAssertEqual(panel.shownHelpTopic, .toolsOverview)
    }

    /// A tool-module with nothing written about it leaves the header without a
    /// button, rather than with one that opens nothing.
    func testAModuleWithNoPageLeavesNoButton() {
        let panel = ToolPanelView()
        panel.setHelpTopic(StubToolB.helpTopic)
        XCTAssertNil(panel.shownHelpTopic)
    }

    /// The header's `?` lands inside the 28-point bar, between the file
    /// selector and the ✕. The bar is five ranked constraints deep and gives
    /// its pieces up in a set order when squeezed, so a button added to it is
    /// worth measuring rather than assuming.
    func testTheHeadersButtonSitsBesideTheCloseButton() throws {
        let panel = ToolPanelView()
        panel.setHelpTopic(.toolsOverview)
        panel.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
        let window = makeTestWindow()
        window.contentView?.addSubview(panel)
        window.layoutIfNeeded()

        let help = try XCTUnwrap(panel.helpButtonFrameInHeader)
        XCTAssertFalse(help.frame.isEmpty, "the button was laid out at no size")
        XCTAssertLessThan(help.frame.maxY, ToolPanelView.headerHeight + 1,
                          "it must stay inside the header bar")
        XCTAssertLessThanOrEqual(help.frame.maxX, help.closeFrame.minX,
                                 "the ✕ owns the trailing end; the ? sits inside it")
    }

    /// Starting a session tells the header which page to offer — the wiring
    /// between the registry's declaration and the button.
    func testActivatingAToolSetsTheHeadersPage() throws {
        installToolStubs()
        let controller = MainViewController()
        let window = makeTestWindow()
        window.contentViewController = controller
        let url = try tempFile([0x41, 0x42, 0x43])
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)

        controller.activateTool(menuItem(for: StubToolA.identifier))
        XCTAssertEqual(controller.frontTools.panel.shownHelpTopic, StubToolA.helpTopic)

        controller.activateTool(menuItem(for: StubToolB.identifier))
        XCTAssertNil(controller.frontTools.panel.shownHelpTopic,
                     "the header must drop the page with the tool-module that named it")
    }

    private func menuItem(for identifier: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = identifier
        return item
    }
}

/// Every page and term the app's own code names, checked against the book.
///
/// The compiler already guarantees a `HelpTopicID` is spelled right; what it
/// cannot guarantee is that a page was written for it. This is the test that
/// fails when a `?` is added before its page is.
@MainActor
final class HelpDestinationsTests: XCTestCase {
    /// The pages the forms, the panels and the landing screen point at.
    func testEveryPageTheAppPointsAtExists() {
        let pointed: [HelpTopicID] = [
            .overview, .firstComparison, .benchSafety, .provenance,
            .search, .segments, .bookmarks, .editing, .settings,
            .toolsOverview, .toolUEFI, .toolME, .toolFIT, .toolZones
        ]
        for id in pointed {
            XCTAssertNotNil(Help.shared.topic(id), "no page for \(id.rawValue)")
        }
    }

    /// Every tool-module the app ships names a page, and every one of those
    /// pages is written. A panel nobody explained is a panel with a `?` that
    /// opens nothing.
    func testEveryShippedToolModuleHasItsPage() {
        for module in ToolRegistry.modules {
            guard let topic = module.helpTopic else {
                return XCTFail("\(module.title) names no help page")
            }
            XCTAssertNotNil(Help.shared.topic(topic),
                            "\(module.title) points at \(topic.rawValue), which is not written")
        }
    }
}
