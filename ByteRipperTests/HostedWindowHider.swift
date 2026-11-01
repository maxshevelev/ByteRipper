import AppKit
import ObjectiveC

/// The test bundle's principal class: XCTest makes one at bundle load, before
/// any test runs. Every window this process creates from then on starts fully
/// transparent and without an order-in animation, while it stays ordered in,
/// key-eligible and `isVisible` to AppKit — a run of the suite does not draw
/// its windows over whatever the person at the Mac is doing.
///
/// The window the app puts up before the bundle loads is made transparent here
/// too: the app has started by the time XCTest loads the bundle, so the
/// swizzle alone would leave that one on the screen.
///
/// A window is made transparent rather than ordered out, which would exit the
/// app under test before XCTest connects. The order-in animation is turned off
/// as well: it does not finish on a sleeping display, and each one left running
/// parks a dispatch worker until every later dispatch callback starves.
@objc(HostedWindowHider)
final class HostedWindowHider: NSObject {
    private typealias Initializer = @convention(c) (UnsafeRawPointer, Selector, NSRect, UInt, UInt, Bool) -> UnsafeRawPointer?

    private typealias Replacement = @convention(block) (UnsafeRawPointer, NSRect, UInt, UInt, Bool) -> UnsafeRawPointer?

    /// Raw pointers keep ARC out of an initializer, which consumes self and
    /// returns a retained object.
    override init() {
        super.init()
        _ = Self.installed
    }

    /// Puts the swizzle in place once, whichever instance asks for it. XCTest
    /// makes the principal class on the main thread, which is where a window
    /// is made.
    private static let installed: Void = {
        let selector = NSSelectorFromString("initWithContentRect:styleMask:backing:defer:")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return () }
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let replacement: Replacement = { allocated, rect, style, backing, deferred in
            guard let made = original(allocated, selector, rect, style, backing, deferred) else {
                return nil
            }
            guard Thread.isMainThread else { return made }
            nonisolated(unsafe) let raw = made
            MainActor.assumeIsolated {
                let window = Unmanaged<NSWindow>.fromOpaque(raw).takeUnretainedValue()
                window.alphaValue = 0
                window.animationBehavior = .none
            }
            return made
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        MainActor.assumeIsolated {
            for window in NSApplication.shared.windows {
                window.alphaValue = 0
                window.animationBehavior = .none
            }
        }
        return ()
    }()
}
