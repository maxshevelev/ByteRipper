import Cocoa
import XCTest
@testable import ByteRipper

/// The Settings window is wide enough to show every tab as a button.
///
/// The tabs used to pin themselves to 480 pt — a width measured against the
/// English labels, and not even wide enough for those: at 480 pt AppKit showed
/// five of the eight items and folded the rest into the overflow chevron. A
/// translated label is wider again, so the width is now measured from the
/// labels themselves, and this is what keeps it honest.
@MainActor
final class SettingsToolbarFitTests: XCTestCase {
    /// How many toolbar items AppKit laid out as buttons. An item in the
    /// overflow menu has no viewer in the window.
    private func visibleItems(in window: NSWindow) -> Int {
        var count = 0
        func walk(_ view: NSView) {
            if String(describing: type(of: view)) == "NSToolbarItemViewer" { count += 1 }
            view.subviews.forEach(walk)
        }
        if let frame = window.contentView?.superview { walk(frame) }
        return count
    }

    func testEveryTabIsAButtonAndNotAnOverflowRow() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(visibleItems(in: window),
                       SettingsWindowController.tabIdentifiers.count,
                       "every Settings tab must be a visible toolbar button")
    }

    /// The measurement follows the labels: a longer set of words asks for a
    /// wider window. This is what makes a translation fit rather than the
    /// number 480 happening to be enough.
    func testTheWidthFollowsTheLabels() {
        let short = SettingsMetrics.toolbarWidth(for: ["A", "B", "C"])
        let long = SettingsMetrics.toolbarWidth(
            for: ["Декодирование текста", "Расположение файловых панелей", "Шаблоны поиска"])
        XCTAssertGreaterThan(long, short)
    }

    /// A tab that wants more than the toolbar keeps what it wants.
    func testATabMayAskForMoreThanTheToolbarNeeds() {
        XCTAssertGreaterThanOrEqual(SettingsMetrics.width(preferring: 2000), 2000)
        XCTAssertGreaterThanOrEqual(SettingsMetrics.width(preferring: 100),
                                    SettingsMetrics.width())
    }
}

/// The Language tab's notice row: a long sentence beside a button, in a
/// language whose words are longer than the English the layout was drawn for.
@MainActor
final class LanguageNoticeFitTests: XCTestCase {
    /// «Перезапустить» is half again as wide as "Relaunch Now". The stack used
    /// to take that difference out of the button, which then read as half a
    /// word; the notice is what gives way now.
    func testTheRelaunchButtonIsNotSqueezedByTheNotice() throws {
        let tab = LanguageSettingsViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = tab
        tab.showRelaunchNoticeForTesting()
        window.layoutIfNeeded()

        let button = try XCTUnwrap(tab.relaunchButtonForTesting)
        XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width,
                                    "the Relaunch button must keep its whole title")
        let root = try XCTUnwrap(tab.view as NSView?)
        XCTAssertLessThanOrEqual(button.frame.maxX, root.frame.maxX,
                                 "the Relaunch button must stay inside the tab")
    }
}
