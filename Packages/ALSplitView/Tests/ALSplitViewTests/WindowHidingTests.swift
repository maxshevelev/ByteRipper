import AppKit
import XCTest

/// A window this package's tests make is transparent: the test bundle links
/// `TestWindowHiding`, whose constructor swizzles the window's initializer, so
/// a run of the suite shows nothing on the screen while the window stays
/// ordered in and visible. This test fails if that dependency is dropped.
@MainActor
final class WindowHidingTests: XCTestCase {
    func testAWindowThisPackageMakesStartsTransparent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertEqual(window.alphaValue, 0, "nothing of a test's window reaches the screen")
        XCTAssertEqual(window.animationBehavior, .none, "no order-in animation to wait for")
    }
}
