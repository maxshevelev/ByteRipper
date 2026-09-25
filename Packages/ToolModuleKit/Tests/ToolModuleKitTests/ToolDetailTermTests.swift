import AppKit
import HelpBook
import XCTest
@testable import ToolModuleKit

/// The `?` the detail list carries for the row in focus — the panels' answer to
/// "what *is* this row".
@MainActor
final class ToolDetailTermTests: XCTestCase {
    private func makeList(in window: NSWindow) -> ToolDetailScroll {
        let list = ToolDetailScroll()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return list
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                 styleMask: [.titled], backing: .buffered, defer: true)
    }

    func testNoTermIsNoButton() {
        let window = makeWindow()
        let list = makeList(in: window)
        XCTAssertNil(list.shownTerm)
    }

    func testATermTheBookHoldsGivesAButton() {
        let window = makeWindow()
        let list = makeList(in: window)
        list.setTerm(HelpTermID("fpt"))
        XCTAssertEqual(list.shownTerm, HelpTermID("fpt"))
    }

    /// A panel may name a row the glossary has not caught up with. That is the
    /// same as naming none: a `?` opening an empty popover is worse than no `?`.
    func testATermTheBookDoesNotHoldIsNoButton() {
        let window = makeWindow()
        let list = makeList(in: window)
        list.setTerm(HelpTermID("no-such-term"))
        XCTAssertNil(list.shownTerm)
    }

    func testClearingTakesTheButtonAway() {
        let window = makeWindow()
        let list = makeList(in: window)
        list.setTerm(HelpTermID("fpt"))
        list.setTerm(nil)
        XCTAssertNil(list.shownTerm)
    }

    /// The `?` is somewhere a click and VoiceOver can both reach it.
    ///
    /// This is the test the two earlier homes failed. A plain subview of the
    /// scroll view was never laid out; a floating subview was drawn but left
    /// out of the view hierarchy and of the accessibility tree — so a walk of
    /// the window found no such button while it was visibly on screen.
    func testTheButtonIsReachable() throws {
        let window = makeWindow()
        let list = makeList(in: window)
        list.setTerm(HelpTermID("fpt"))
        window.layoutIfNeeded()

        let button = list.termButtonForTesting
        XCTAssertFalse(button.isHidden)
        XCTAssertNotNil(button.window, "the button is not in the window at all")

        // In the view hierarchy, which is what a walk of the window — and the
        // accessibility tree behind it — descends.
        var walked: [NSView] = []
        func walk(_ view: NSView) {
            walked.append(view)
            view.subviews.forEach(walk)
        }
        walk(try XCTUnwrap(window.contentView))
        XCTAssertTrue(walked.contains { $0 === button },
                      "the button is drawn but is not in the window's view tree")

        // And a click at its centre finds it rather than falling through to
        // whatever is behind.
        let point = try XCTUnwrap(button.superview).convert(button.frame, to: nil)
        let hit = window.contentView?.hitTest(
            try XCTUnwrap(window.contentView).convert(
                NSPoint(x: point.midX, y: point.midY), from: nil)
        )
        XCTAssertTrue(hit === button, "a click at the button's centre lands on \(String(describing: hit))")

        XCTAssertEqual(button.accessibilityLabel()?.isEmpty, false,
                       "the button says nothing to VoiceOver")
    }

    /// The button sits in the list's top trailing corner.
    ///
    /// Measured in the **window's** coordinates, which is the only space that
    /// answers "where does the reader see it". A scroll view lays out its own
    /// subviews rather than solving constraints for them, and the host a
    /// floating subview lands in is flipped — two chances to be at the bottom
    /// while a frame read in the wrong space insists it is at the top. Both
    /// were taken, in order, before this test was believed.
    func testTheButtonSitsInTheListsTopCorner() throws {
        let window = makeWindow()
        let list = makeList(in: window)
        list.setTerm(HelpTermID("fpt"))
        window.layoutIfNeeded()

        let button = try XCTUnwrap(list.termButtonFrameInWindow)
        let box = try XCTUnwrap(list.frameInWindow)
        XCTAssertFalse(button.isEmpty, "the button was laid out at no size")
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(button),
                      "the button landed outside the list: \(button) in \(box)")
        XCTAssertGreaterThan(button.minX, box.midX,
                             "it belongs in the trailing half, out of the rows' way")
        // A window's space is not flipped, so the top of the list is its high
        // edge whatever the views inside it do.
        XCTAssertGreaterThan(button.maxY, box.maxY - 30,
                             "the button is not in the list's top band")
    }
}
