import AppKit
import XCTest
import TestWindowHiding

/// A window a test creates is invisible to the person running the suite, and
/// still a window as far as the test is concerned: ordered in, visible, able
/// to take the keyboard.
@MainActor
final class TestWindowHidingTests: XCTestCase {
    func testAWindowStartsTransparentAndStaysVisible() {
        XCTAssertEqual(testWindowHidingInstalled(), 1, "the swizzle is in place before the first test")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertEqual(window.alphaValue, 0, "nothing of a test's window reaches the screen")
        XCTAssertEqual(window.animationBehavior, .none, "no order-in animation to wait for")

        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible, "ordered in all the same")
    }

    func testAPanelIsHiddenTheSameWay() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }

        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertEqual(panel.animationBehavior, .none)
    }
}
