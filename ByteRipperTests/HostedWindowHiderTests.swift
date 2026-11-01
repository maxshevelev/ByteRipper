import AppKit
import XCTest

/// A window a test creates is invisible to the person running the suite, and
/// still a window as far as the test is concerned: ordered in, visible, able
/// to take the keyboard.
@MainActor
final class HostedWindowHiderTests: XCTestCase {
    func testAWindowCreatedInTheHostStartsTransparent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertEqual(window.alphaValue, 0, "nothing of a test's window reaches the screen")
        XCTAssertEqual(window.animationBehavior, .none, "no order-in animation to wait for")
    }

    func testAPanelStartsTransparentAndStillOrdersFront() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }

        panel.orderFrontRegardless()

        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.isVisible, "ordered in all the same")
    }

    /// The app's own window is made by the app before the test bundle loads,
    /// so the swizzle alone would leave it drawn; the principal class takes it
    /// with the rest when it installs.
    func testTheAppsOwnWindowsAreTransparent() throws {
        let windows = NSApplication.shared.windows.filter { $0.isVisible }
        try XCTSkipIf(windows.isEmpty, "this launch put up no window to hide")
        for window in windows {
            XCTAssertEqual(window.alphaValue, 0, "\(window.title) reaches the screen")
        }
    }
}
