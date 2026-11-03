import ByteRipperCore
import Localization
import XCTest
@testable import ByteRipper

/// §3.4 pane header: a system document glyph sits before the file name —
/// "document" (outline) while the file is clean, "document.fill" once there
/// are unsaved changes. The fill replaces the "*" the title used to append.
@MainActor
final class PaneHeaderIconTests: XCTestCase {
    /// The pane's document glyph: the NSImageView inside the PaneHeaderView.
    private func documentIcon(of pane: FilePaneView) throws -> NSImageView {
        let header = try XCTUnwrap(descendants(of: pane, PaneHeaderView.self).first)
        return try XCTUnwrap(descendants(of: header, NSImageView.self).first,
                             "the header must contain the document glyph")
    }

    /// A pane with a small file open.
    private func makePane(_ bytes: [UInt8]) throws -> (FilePaneView, URL) {
        let url = try tempFile(bytes)
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        let pane = FilePaneView(viewModel: viewModel)
        return (pane, url)
    }

    private func button(_ label: String, in view: NSView) -> NSView? {
        if view is NSButton, view.accessibilityLabel() == label { return view }
        return view.subviews.lazy.compactMap { self.button(label, in: $0) }.first
    }

    /// A code screen's help stands before the panel's own buttons, and comes to
    /// the header's end when a window's code screen has none of them.
    func testTheAccessoryStandsBeforeThePanelsButtons() throws {
        let (pane, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        pane.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
        pane.onCollapse = {}
        pane.onOpenInTab = {}
        let help = NSView()
        help.widthAnchor.constraint(equalToConstant: 16).isActive = true
        help.heightAnchor.constraint(equalToConstant: 16).isActive = true
        pane.setHeaderAccessory(help)
        pane.layoutSubtreeIfNeeded()

        let helpFrame = help.convert(help.bounds, to: pane)
        for label in [L("Open in New Tab"), L("Collapse panel"), L("Close pane")] {
            let control = try XCTUnwrap(button(label, in: pane), label)
            XCTAssertFalse(control.isHidden, label)
            XCTAssertGreaterThanOrEqual(control.convert(control.bounds, to: pane).minX, helpFrame.maxX, label)
        }

        pane.onCollapse = nil
        pane.onOpenInTab = nil
        pane.hidesCloseButton = true
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(help.convert(help.bounds, to: pane).maxX, pane.bounds.maxX - 8, accuracy: 1)
    }

    /// The glyph's state machine, walked in one pane: a clean file shows the
    /// rendered "document" outline before its name, an unsaved edit fills it in,
    /// and saving takes it back to the outline.
    func testTheDocumentGlyphFollowsTheUnsavedState() throws {
        let (pane, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }

        let icon = try documentIcon(of: pane)
        XCTAssertNotNil(icon.image, "the header must render a document glyph")
        XCTAssertEqual(pane.documentSymbolName, "document",
                       "a clean file gets the outline")

        pane.viewModel.moveCaret(to: 0)
        pane.viewModel.typeHexNibble(0xA)
        pane.viewModel.typeHexNibble(0x5)
        XCTAssertEqual(pane.documentSymbolName, "document.fill",
                       "an unsaved edit must switch the glyph to document.fill")

        try pane.viewModel.save()
        XCTAssertEqual(pane.documentSymbolName, "document",
                       "saving clears the dirty state, so the glyph returns to the outline")
    }
}
