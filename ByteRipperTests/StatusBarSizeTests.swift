import ByteRipperCore
import XCTest
@testable import ByteRipper

/// The status bar's file size as the one part of it the pointer can act on
/// (§3.4): the pointer turning it into the exact count in place, each half of
/// that count copying itself, the dot that separates it from the OVR/INS
/// indicator, and the indicator flipping the mode of the pane it is drawn in
/// (§7.6).
@MainActor
final class StatusBarSizeTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// A label in a container, laid out at a real width — the way the pane's
    /// status stack gives it one. The container is also the room the label may
    /// grow into, which the bar would otherwise supply.
    private func makeLabel(width: CGFloat, parts: [String], sizeIndex: Int,
                           fileSize: UInt64) -> (StatusLabel, NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 18))
        let label = StatusLabel(labelWithString: "")
        label.font = font
        label.frame = NSRect(x: 0, y: 0, width: width, height: 18)
        label.roomProvider = { width }
        container.addSubview(label)
        label.show(parts: parts, sizeIndex: sizeIndex, fileSize: fileSize)
        return (label, container)
    }

    /// One character's advance. The bar's font is monospaced, so a position in
    /// the line is a character index and a point on the size can be named by
    /// the character it is over — which is how the tests below aim at the hex
    /// half and at the decimal half of the exact form.
    private var advance: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The exact size in the Details view's form. The 64-bit case is the point
    /// of the format string: `%d` would print the low half of a file over 2 GB.
    func testTheExactSizeIsHexAndDecimal() {
        XCTAssertEqual(StatusLabel.exactSizeText(0), "0x0 (0 bytes)")
        XCTAssertEqual(StatusLabel.exactSizeText(2 * 1024 * 1024), "0x200000 (2097152 bytes)")
        XCTAssertEqual(StatusLabel.exactSizeText(0x1_0000_0001), "0x100000001 (4294967297 bytes)")
    }

    /// What each half of the exact form puts on the clipboard: that half on its
    /// own — the hex address without the `0x` prefix the readout beside it
    /// wears, the decimal count without the word that follows it in the bar.
    /// The prefix belongs to the field the value is pasted into, which adds it.
    func testEachHalfOfTheExactFormIsCopiedInItsOwnFormat() {
        let size: UInt64 = 2 * 1024 * 1024
        XCTAssertEqual(StatusLabel.copyText(size, as: .hex), "200000")
        XCTAssertEqual(StatusLabel.copyText(size, as: .decimal), "2097152")
        XCTAssertEqual(StatusLabel.copyText(0x1_0000_0001, as: .hex), "100000001")
        XCTAssertEqual(StatusLabel.copyText(0x1_0000_0001, as: .decimal), "4294967297")
    }

    /// The region covers the size's own text — measured out of the label's
    /// rendered string, not out of the label's own arithmetic: the characters
    /// that fall inside it are exactly the size, separated from its neighbours
    /// by the hit slack the cell's drawing inset needs.
    func testTheRegionCoversTheSizeAndNothingElse() throws {
        let size: UInt64 = 2 * 1024 * 1024
        let (label, _) = makeLabel(width: 800,
                                   parts: ["Offset 0000", "2 MB", "Modified"],
                                   sizeIndex: 1, fileSize: size)
        let region = try XCTUnwrap(label.sizeRegion)

        let first = Int(((region.minX + StatusLabel.hitSlack) / advance).rounded())
        let last = Int(((region.maxX - StatusLabel.hitSlack) / advance).rounded())
        let covered = (label.stringValue as NSString)
            .substring(with: NSRange(location: first, length: last - first))

        XCTAssertEqual(covered, "2 MB", "the region must be the size and nothing either side of it")
        XCTAssertEqual(label.stringValue, "Offset 0000  ·  2 MB  ·  Modified")
    }

    /// The pointer on the size turns the size into the exact count, in place —
    /// the abbreviation is what a glance wants and the exact form is what the
    /// pointer is asking for — and taking the pointer away puts the line back.
    func testThePointerTurnsTheSizeIntoTheExactCountInPlace() throws {
        let size: UInt64 = 2 * 1024 * 1024
        let (label, _) = makeLabel(width: 800,
                                   parts: ["Offset 0000", "2 MB", "Modified"],
                                   sizeIndex: 1, fileSize: size)
        let abbreviated = try XCTUnwrap(label.sizeRegion)

        label.pointerIsAt(NSPoint(x: abbreviated.midX, y: 9))

        XCTAssertTrue(label.isExpanded)
        XCTAssertEqual(label.stringValue,
                       "Offset 0000  ·  0x200000 (2097152 bytes)  ·  Modified",
                       "the readout itself becomes the exact count")
        // The whole exact form is the region now, not just the part of it the
        // abbreviation used to occupy: the pointer is on all of it.
        let expanded = try XCTUnwrap(label.sizeRegion)
        XCTAssertGreaterThan(expanded.maxX, abbreviated.maxX + advance,
                             "the exact form is longer, and all of it answers")

        label.pointerIsAt(nil)
        XCTAssertFalse(label.isExpanded)
        XCTAssertEqual(label.stringValue, "Offset 0000  ·  2 MB  ·  Modified")
    }

    /// A pointer beside the size is not on it: the bar answers only under the
    /// size, and a pointer that has merely entered the bar's own area — which
    /// reaches a little past the size in both forms — leaves it abbreviated.
    func testAPointerOffTheSizeLeavesItAbbreviated() throws {
        let (label, _) = makeLabel(width: 800,
                                   parts: ["Offset 0000", "2 MB"],
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        let region = try XCTUnwrap(label.sizeRegion)

        label.pointerIsAt(NSPoint(x: region.minX - 30, y: 9))
        XCTAssertFalse(label.isExpanded)
        XCTAssertEqual(label.stringValue, "Offset 0000  ·  2 MB")

        label.pointerIsAt(NSPoint(x: region.minX - 1, y: 9))
        XCTAssertFalse(label.isExpanded, "the slack around the size is not the size")
    }

    /// The region is the label's whole mouse surface, and the rest of the bar
    /// is left to the pane behind it — a click beside the size focuses the
    /// dump, exactly as it did before the size was interactive (§3.3).
    func testOnlyTheSizeIsHitAndTheRestOfTheBarPassesThrough() throws {
        let (label, container) = makeLabel(width: 800,
                                           parts: ["Offset 0000", "2 MB"],
                                           sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        let region = try XCTUnwrap(label.sizeRegion)

        let onSize = NSPoint(x: region.midX, y: 9)
        let besideSize = NSPoint(x: region.maxX + 20, y: 9)

        XCTAssertTrue(container.hitTest(onSize) === label, "the size takes the pointer")
        XCTAssertTrue(container.hitTest(besideSize) === container,
                      "the rest of the bar belongs to the pane")
        XCTAssertTrue(label.hitTest(onSize) === label)
        XCTAssertNil(label.hitTest(besideSize))
    }

    /// A line the label had to cut short has no size on screen: the tail is
    /// gone, so there is nothing there to hover or right-click.
    func testATruncatedSizeIsNotAimedAt() throws {
        let (label, container) = makeLabel(width: 60,
                                           parts: ["Offset 0000", "2 MB", "Modified"],
                                           sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        XCTAssertNil(label.sizeRegion, "the size is past the truncation")
        XCTAssertTrue(container.hitTest(NSPoint(x: 10, y: 9)) === container)
    }

    /// A label with no width yet has nothing to aim at either: a bar that has
    /// not been laid out has no idea where its line truncates, and the pane
    /// composes the line before the bar exists (§3.4).
    func testALabelWithNoWidthHasNothingToAimAt() throws {
        let (label, _) = makeLabel(width: 0,
                                   parts: ["Offset 0000", "2 MB"],
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        XCTAssertNil(label.sizeRegion)
        XCTAssertTrue(label.trackingAreas.isEmpty)

        label.pointerIsAt(NSPoint(x: 0, y: 0))
        XCTAssertFalse(label.isExpanded)
    }

    /// Where the abbreviation fits but the exact form does not, the pointer
    /// gets the abbreviation and nothing else. An expansion cut off by the
    /// bar's own tail would say less than what it replaced — and it would
    /// chase its own tail, expanding into a truncation that collapses it again.
    func testAnExactFormThatWouldNotFitIsNotOffered() throws {
        let (label, _) = makeLabel(width: 150,
                                   parts: ["Offset 0000", "2 MB"],
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        let region = try XCTUnwrap(label.sizeRegion)

        label.pointerIsAt(NSPoint(x: region.midX, y: 9))

        XCTAssertFalse(label.isExpanded)
        XCTAssertEqual(label.stringValue, "Offset 0000  ·  2 MB",
                       "the bar keeps the form that fits")
    }

    /// The room a bar gives is its own to change, and a bar that narrows under
    /// an expanded size takes the exact form with it rather than leaving a
    /// readout cut off in the middle.
    func testANarrowingBarTakesTheExactFormAway() throws {
        var room: CGFloat = 800
        let (label, _) = makeLabel(width: 800,
                                   parts: ["Offset 0000", "2 MB"],
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        label.roomProvider = { room }
        let region = try XCTUnwrap(label.sizeRegion)
        label.pointerIsAt(NSPoint(x: region.midX, y: 9))
        XCTAssertTrue(label.isExpanded)

        // A narrowing bar is a narrower label AND a smaller grant: the readout
        // falls back to its own width when the bar offers nothing, so a test
        // that only shrank the grant would still leave it 800 points wide.
        room = 150
        label.frame.size.width = 150
        label.needsLayout = true
        label.layoutSubtreeIfNeeded()

        XCTAssertFalse(label.isExpanded, "a bar too narrow for the exact form shows the abbreviation")
        XCTAssertEqual(label.stringValue, "Offset 0000  ·  2 MB")
    }

    /// A transient message (§11) takes the size off screen with it: while "No
    /// match found." is up, the pointer where the size was must find nothing —
    /// no region, no hover, no menu naming a size that is not being shown.
    func testATransientMessageLeavesNothingToAimAt() throws {
        let (label, _) = makeLabel(width: 800,
                                   parts: ["Offset 0000", "2 MB"],
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        let region = try XCTUnwrap(label.sizeRegion)
        // The hover is not merely answerable but armed: it is a tracking area
        // over the size, and nothing else on a label puts one there.
        XCTAssertFalse(label.trackingAreas.isEmpty, "the hover is armed over the size")

        label.showTransient("No match found.")
        label.pointerIsAt(NSPoint(x: region.midX, y: 9))

        XCTAssertNil(label.sizeRegion)
        XCTAssertTrue(label.trackingAreas.isEmpty, "and disarmed with it")
        XCTAssertEqual(label.stringValue, "No match found.",
                       "a hover armed over the message would expand text that is not there")
        XCTAssertNil(label.sizeMenu(at: NSPoint(x: region.midX, y: 9)))
    }

    /// The message stays up across a layout pass. The readout is composed from
    /// the parts it was given, and a pass that composed them again would take
    /// the message down before its own timer does — the duplicate report (§11)
    /// is the case that caught this.
    func testATransientMessageSurvivesALayoutPass() throws {
        let (label, _) = makeLabel(width: 800,
                                   parts: ["Offset 0000", "2 MB"],
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024)
        label.showTransient("Duplicated report.bin as report-2.bin. Size: 32 bytes.")

        label.needsLayout = true
        label.layoutSubtreeIfNeeded()

        XCTAssertEqual(label.stringValue, "Duplicated report.bin as report-2.bin. Size: 32 bytes.")
        XCTAssertNil(label.sizeRegion, "and the size is still off screen with it")
    }

    /// The right-click copies the half it landed on, and only from a point that
    /// is on the size at all: the hex address where the address is drawn, the
    /// decimal count where the count is drawn.
    func testTheRightClickCopiesTheHalfItLandedOn() throws {
        let size: UInt64 = 0x200000
        let (label, _) = makeLabel(width: 800,
                                   parts: ["Offset 0000", "2 MB"],
                                   sizeIndex: 1, fileSize: size)
        var asked: [(UInt64, StatusLabel.SizeForm)] = []
        label.sizeMenuProvider = { asked.append(($0, $1)); return NSMenu(title: "File Size") }

        let region = try XCTUnwrap(label.sizeRegion)
        XCTAssertNil(label.sizeMenu(at: NSPoint(x: region.minX - 20, y: 9)))
        XCTAssertTrue(asked.isEmpty, "the menu is not built for a point that is not on the size")

        // The pointer being on the size is what draws the exact form, so the
        // halves the right-click chooses between are the ones on screen.
        label.pointerIsAt(NSPoint(x: region.midX, y: 9))
        let expanded = try XCTUnwrap(label.sizeRegion)
        let text = expanded.minX + StatusLabel.hitSlack
        XCTAssertEqual((label.stringValue as NSString)
            .substring(with: NSRange(location: 16, length: 8)), "0x200000",
                       "the hex half is where the test thinks it is")

        XCTAssertNotNil(label.sizeMenu(at: NSPoint(x: text + 4 * advance, y: 9)),
                        "four characters into the form is the middle of the address")
        XCTAssertNotNil(label.sizeMenu(at: NSPoint(x: text + 13 * advance, y: 9)),
                        "thirteen characters in is the decimal count")
        XCTAssertEqual(asked.map(\.1), [.hex, .decimal])
        XCTAssertEqual(asked.map(\.0), [size, size])
    }

    /// The whole way through, in a pane as the app builds one: the bar composes
    /// its line, publishes the size's region against the label's real width,
    /// gives the readout room to grow into, and hands the right-click to the
    /// controller's menu — which offers the half that was clicked, in that
    /// half's format. And the mode indicator is pinned to the bar's other end,
    /// with the readout's growth stopping short of it.
    func testThePanePublishesTheSizesRegionRoomAndMenu() throws {
        let urlA = try tempFile([UInt8](repeating: 0x41, count: 300))
        let urlB = try tempFile([UInt8](repeating: 0x42, count: 300))
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer {
            // The window goes first, as every other suite here does: a window
            // left ordered front outlives the test, and releasing one that is
            // still key — with its panes already closed under it — is how a
            // test host dies inside XCTest's scope teardown instead of ending.
            window.orderOut(nil)
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }
        let pane = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self)
            .first { $0.viewModel === controller.windowModel.pane1 })
        let label = pane.statusLabel
        let region = try XCTUnwrap(label.sizeRegion, "the bar has a width, so the size is on screen")
        XCTAssertFalse(label.trackingAreas.isEmpty, "the pane's own bar arms the hover")

        // And the region is over the size the bar reads: "300 B", the
        // abbreviation the friendly form gives three hundred bytes.
        let first = Int(((region.minX + StatusLabel.hitSlack) / advance).rounded())
        let last = Int(((region.maxX - StatusLabel.hitSlack) / advance).rounded())
        let covered = (label.stringValue as NSString)
            .substring(with: NSRange(location: first, length: last - first))
        XCTAssertEqual(covered, FilePaneView.friendlySize(300))

        label.pointerIsAt(NSPoint(x: region.midX, y: region.midY))
        XCTAssertTrue(label.isExpanded,
                      "the pane is wide enough for the exact form of three hundred bytes")
        XCTAssertEqual(label.stringValue,
                       label.stringValue.replacingOccurrences(of: "300 B",
                                                              with: "0x12C (300 bytes)"),
                       "the line keeps its other parts and swaps only the size")

        // The bar gave the readout the room to say it: the readout is sized to
        // its content, and it grew by the twelve characters the exact form is
        // longer than the abbreviation. A readout limited to its own frame —
        // its own width is all it can see — would still be "300 B" wide.
        window.layoutIfNeeded()
        XCTAssertGreaterThan(label.frame.width, region.width + 8 * advance,
                             "the readout was allowed to grow, so nothing is cut off")

        // The controller's own menu, reached by the right-click: the hex half
        // where the address is drawn, the decimal half where the count is.
        let expanded = try XCTUnwrap(label.sizeRegion)
        let text = expanded.minX + StatusLabel.hitSlack
        XCTAssertEqual(label.sizeMenu(at: NSPoint(x: text + 2 * advance, y: 9))?
            .items.first?.title, "Copy hex size 12C")
        XCTAssertEqual(label.sizeMenu(at: NSPoint(x: text + 12 * advance, y: 9))?
            .items.first?.title, "Copy size 300")

        // The indicator is the bar's own right corner, not a third thing in the
        // readout's row: it ends at the trailing inset, and the readout — which
        // grows towards it as the pointer asks for the exact form — stops short
        // of it rather than running under it (§3.4).
        let indicator = pane.typingModeLabel
        let bar = try XCTUnwrap(indicator.superview, "the indicator is pinned to the bar")
        XCTAssertEqual(bar.bounds.maxX - indicator.frame.maxX, 10, accuracy: 0.5,
                       "the indicator sits at the bar's trailing inset")
        XCTAssertEqual(indicator.frame.midY, bar.bounds.midY, accuracy: 0.5)
        let readout = label.convert(label.bounds, to: bar)
        XCTAssertLessThan(readout.maxX, indicator.frame.minX,
                          "and nothing is drawn between the readout and the indicator")
    }

    /// With one file open the app is in single-file mode (§3.2): the bar still
    /// reads a size, and the pointer still acts on it there. This is the shape
    /// the pane's window is in for most of a session — half the app's states —
    /// and the mode a window's own teardown has to survive.
    func testASingleFilePaneStillOffersItsSize() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 300))
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            controller.windowModel.pane1.close()
            try? FileManager.default.removeItem(at: url)
        }
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }

        let pane = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self)
            .first { $0.viewModel === controller.windowModel.pane1 })
        let label = pane.statusLabel
        let region = try XCTUnwrap(label.sizeRegion, "the size is on screen in single-file mode")
        let first = Int(((region.minX + StatusLabel.hitSlack) / advance).rounded())
        let last = Int(((region.maxX - StatusLabel.hitSlack) / advance).rounded())
        XCTAssertEqual((label.stringValue as NSString)
            .substring(with: NSRange(location: first, length: last - first)),
                       FilePaneView.friendlySize(300))

        label.pointerIsAt(NSPoint(x: region.midX, y: region.midY))
        XCTAssertTrue(label.stringValue.contains("\(StatusLabel.exactSizeText(300))"),
                      "and the pointer turns it into the exact count here too")
    }

    /// The controller's menu: one item, naming the form it copies and then the
    /// value, and the pasteboard ends up holding that half of the size and
    /// nothing else — the hex one bare, with no `0x` for a field to double.
    func testTheMenuCopiesTheSizeInTheFormItWasOpenedOn() {
        let controller = MainViewController()
        let size: UInt64 = 2 * 1024 * 1024

        let hexItem = try? XCTUnwrap(controller.makeSizeMenu(size: size, form: .hex).items.first)
        XCTAssertEqual(hexItem?.title, "Copy hex size 200000")
        controller.copyStatusValue(hexItem)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "200000")

        let decimalItem = try? XCTUnwrap(
            controller.makeSizeMenu(size: size, form: .decimal).items.first)
        XCTAssertEqual(decimalItem?.title, "Copy size 2097152")
        controller.copyStatusValue(decimalItem)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "2097152")
    }

    /// A click on a pane's OVR/INS indicator flips that pane's mode — and the
    /// pane it is drawn in becomes the typing target, which is what the click
    /// means (§3.3, §7.6).
    func testClickingTheIndicatorFlipsTheModeOfItsOwnPane() throws {
        let urlA = try tempFile([UInt8](repeating: 0x11, count: 64))
        let urlB = try tempFile([UInt8](repeating: 0x22, count: 64))
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer {
            // The window goes first, as every other suite here does: a window
            // left ordered front outlives the test, and releasing one that is
            // still key — with its panes already closed under it — is how a
            // test host dies inside XCTest's scope teardown instead of ending.
            window.orderOut(nil)
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }

        XCTAssertTrue(controller.windowModel.activePane === controller.windowModel.pane1,
                      "pane 1 is active to begin with")
        let pane2View = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self)
            .first { $0.viewModel === controller.windowModel.pane2 })
        let indicator = pane2View.typingModeLabel
        XCTAssertEqual(indicator.stringValue, "OVR")

        indicator.mouseDown(with: try XCTUnwrap(
            NSEvent.mouseEvent(with: .leftMouseDown,
                               location: indicator.convert(NSPoint(x: indicator.bounds.midX,
                                                                   y: indicator.bounds.midY),
                                                           to: nil),
                               modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)))

        XCTAssertTrue(controller.windowModel.pane2.status.isInsertMode,
                      "the clicked pane's mode flips")
        XCTAssertFalse(controller.windowModel.pane1.status.isInsertMode,
                       "and the other pane's does not")
        XCTAssertEqual(indicator.stringValue, "INS")
        XCTAssertTrue(controller.windowModel.activePane === controller.windowModel.pane2,
                      "the pane that was clicked is the one the keys now go to")

        // Clicking it again flips back, so it is a toggle rather than a switch
        // that only ever turns insert mode on.
        indicator.mouseDown(with: try XCTUnwrap(
            NSEvent.mouseEvent(with: .leftMouseDown,
                               location: indicator.convert(NSPoint(x: indicator.bounds.midX,
                                                                   y: indicator.bounds.midY),
                                                           to: nil),
                               modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)))
        XCTAssertFalse(controller.windowModel.pane2.status.isInsertMode)
        XCTAssertEqual(indicator.stringValue, "OVR")
    }
}
