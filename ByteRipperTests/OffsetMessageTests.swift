import AppKit
import XCTest
@testable import ByteRipper

/// Offsets and sizes quoted in messages: whole past 4 GB, and each in its
/// place in the sentence.
@MainActor
final class OffsetMessageTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        MainViewController.modalResponder = nil
        EditingSettings.resetToDefaults()
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        super.tearDown()
    }

    /// A file of `count` bytes in a shown window, its caret at `caret`, with
    /// the shifting-edit warnings on and every alert's text kept.
    private func makeController(count: Int = 0x40, caret: UInt64)
        throws -> (MainViewController, PaneViewModel, () -> [String]) {
        let url = try tempFile([UInt8](repeating: 0x11, count: count))
        urls.append(url)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let pane = controller.windowModel.pane1
        try pane.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            pane.close()
            window.orderOut(nil)
        }
        pane.moveCaret(to: caret)
        EditingSettings.set(warnsBeforeShiftingEdits: true)
        var messages: [String] = []
        MainViewController.modalResponder = { alert in
            messages.append(alert.informativeText)
            return .alertSecondButtonReturn   // Cancel: the file stays as it is
        }
        return (controller, pane, { messages })
    }

    func testTheDeleteConfirmationQuotesTheOffset() throws {
        let (controller, pane, messages) = try makeController(caret: 0x24)
        controller.deleteBytes()
        XCTAssertEqual(messages(), ["Bytes from offset 0x24 will be removed. Subsequent offsets will shift "
                                    + "— the file structure may be affected."])
        XCTAssertEqual(pane.fileSize, 0x40, "cancelled")
    }

    func testTheInsertWarningQuotesTheOffset() throws {
        let (controller, pane, messages) = try makeController(caret: 0x24)
        controller.flipInsertMode(of: pane)
        _ = pane.confirmInsertModeWarning?()
        XCTAssertEqual(messages(), ["Inserting at offset 0x24 shifts every byte from here on "
                                    + "— the file structure may be affected."])
    }

    func testThePasteInsertConfirmationQuotesTheCountAndTheOffset() throws {
        let (controller, pane, messages) = try makeController(caret: 0x24)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("DE AD", forType: .string)

        controller.pasteInsert()
        XCTAssertEqual(messages(), ["Insert 2 byte(s) at offset 0x24. Existing bytes from this offset on will shift."])
        XCTAssertEqual(pane.fileSize, 0x40, "cancelled")
    }
}
