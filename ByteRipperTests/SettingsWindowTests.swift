import Cocoa
import HelpBook
import XCTest
@testable import ByteRipper

/// The Settings window's own behaviour (§3.2): it closes on Escape, like a
/// sheet — every preference is applied and persisted live the moment it
/// changes, so there is nothing to confirm or lose.
@MainActor
final class SettingsWindowTests: XCTestCase {
    /// `cancelOperation` is the responder-chain hook AppKit sends for Escape.
    /// The Settings window overrides it to close, so a synthetic Esc must take
    /// the window down.
    func testEscapeClosesTheSettingsWindow() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible, "precondition: the window is open")

        window.cancelOperation(nil)

        XCTAssertFalse(window.isVisible, "Escape must close the Settings window")
    }

    /// The window is the `SettingsWindow` subclass (the one that overrides
    /// `cancelOperation`), not a plain `NSWindow` whose default no-ops.
    func testTheWindowIsTheEscClosableSubclass() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        XCTAssertTrue(window is SettingsWindow,
                      "the Settings window must be the subclass that closes on Escape")
    }

    /// Appearance, Layout and Language share the View tab, and each section is
    /// still a live view controller: its own observers run there, so a font
    /// size changed from the View menu shows in the Appearance section while
    /// the window is open.
    func testTheViewTabCarriesTheSectionsLive() throws {
        AppearanceSettings.resetToDefaults()
        defer { AppearanceSettings.resetToDefaults() }
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        settings.showWindow(nil)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentViewController as? ViewSettingsViewController)
        XCTAssertEqual(content.children.count, 3, "the View tab holds three sections")

        var steppers: [NSStepper] = []
        func walk(_ view: NSView) {
            if let stepper = view as? NSStepper { steppers.append(stepper) }
            view.subviews.forEach(walk)
        }
        walk(content.view)
        let stepper = try XCTUnwrap(steppers.first)
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: AppearanceSettings.fontSize + 2)
        XCTAssertEqual(CGFloat(stepper.integerValue), AppearanceSettings.fontSize,
                       "the Appearance section must follow the setting")
    }

    /// The Language section's relaunch notice grows the View tab, and the
    /// window grows with it rather than clipping the button.
    func testTheRelaunchNoticeGrowsTheWindow() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        settings.showWindow(nil)
        defer { window.close() }
        let before = window.frame.height

        settings.language.showRelaunchNoticeForTesting()

        XCTAssertGreaterThan(window.frame.height, before,
                             "the window must grow to the notice")
    }

    /// One `?` for the whole window, in the title's row beside the traffic
    /// lights, leading to the Settings page — the same on every tab.
    func testTheHelpButtonSitsInTheTitleRow() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        settings.showWindow(nil)
        defer { window.close() }
        window.layoutIfNeeded()

        let help = settings.helpButtonForTesting
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertTrue(help.superview === close.superview, "the ? must sit in the title row")
        XCTAssertEqual(help.convert(help.bounds, to: nil).midY,
                       close.convert(close.bounds, to: nil).midY, accuracy: 1,
                       "the ? must be level with the traffic lights")
        XCTAssertEqual(help.opens, .topic(.settings))
    }
}
