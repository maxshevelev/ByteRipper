import ByteRipperCore
import XCTest
@testable import ByteRipper

/// The caret's offset as the other part of the status bar the pointer acts on
/// (§3.4): a right-click on the address copies it, as the bar draws it, and
/// nothing else on the line answers — the bar's own hover readout belongs to
/// the size beside it.
///
/// The address is the tail of the line's first part, so its region is measured
/// against the rendered string here too: the characters that fall inside it are
/// the digits, not the word in front of them.
@MainActor
final class StatusBarOffsetTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// A label in a container, laid out at a real width, showing a line whose
    /// first part carries `digits` as the caret's address — the shape the pane
    /// composes (§21.3).
    private func makeLabel(width: CGFloat, parts: [String], sizeIndex: Int,
                           fileSize: UInt64, digits: String,
                           offsetIndex: Int = 0) -> (StatusLabel, NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 18))
        let label = StatusLabel(labelWithString: "")
        label.font = font
        label.frame = NSRect(x: 0, y: 0, width: width, height: 18)
        label.roomProvider = { width }
        container.addSubview(label)
        label.show(parts: parts, sizeIndex: sizeIndex, fileSize: fileSize,
                   offset: .init(index: offsetIndex, digits: digits))
        return (label, container)
    }

    /// The line the tests below use: an address, the size the pointer hovers,
    /// and the state behind them.
    private func line(digits: String) -> [String] {
        ["Offset \(digits)", "2 MB", "Modified"]
    }

    /// One character's advance — the bar's font is monospaced, so a point in
    /// the line can be named by the character it is over.
    private var advance: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The characters `region` covers, read out of the string the label is
    /// actually drawing: the hit slack comes off both edges, exactly the way
    /// the size's region is read in `StatusBarSizeTests`. The address sits
    /// mid-line behind the word "Offset", so the four points of slack land in
    /// the space between them and cover no character.
    private func covered(_ region: NSRect, in label: StatusLabel) -> String {
        let first = Int(((region.minX + StatusLabel.hitSlack) / advance).rounded())
        let last = Int(((region.maxX - StatusLabel.hitSlack) / advance).rounded())
        return (label.stringValue as NSString)
            .substring(with: NSRange(location: first, length: last - first))
    }

    /// The region is the address's digits and nothing else: not the word beside
    /// them, and not the separator after them — a right-click on the label
    /// "Offset" is a right-click on the bar like any other.
    func testTheRegionCoversTheAddressAndNothingElse() throws {
        let (label, _) = makeLabel(width: 800, parts: line(digits: "0002E6"),
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024,
                                   digits: "0002E6")
        let region = try XCTUnwrap(label.offsetRegion)

        XCTAssertEqual(covered(region, in: label), "0002E6",
                       "the region is the digits, without the word in front of them")
        XCTAssertEqual(label.stringValue, "Offset 0002E6  ·  2 MB  ·  Modified")
    }

    /// The address is not a hover readout: the pointer on it changes nothing.
    /// The bar has one expansion, and it belongs to the size — an address that
    /// grew under the pointer would be a second readout fighting the first for
    /// the same line (§3.4).
    func testTheAddressIsNotAHoverReadout() throws {
        let (label, _) = makeLabel(width: 800, parts: line(digits: "0002E6"),
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024,
                                   digits: "0002E6")
        let region = try XCTUnwrap(label.offsetRegion)

        label.pointerIsAt(NSPoint(x: region.midX, y: 9))

        XCTAssertFalse(label.isExpanded)
        XCTAssertEqual(label.stringValue, "Offset 0002E6  ·  2 MB  ·  Modified")

        // And the hover the label does arm is the size's, which is not here.
        let size = try XCTUnwrap(label.sizeRegion)
        XCTAssertFalse(size.intersects(region), "the two regions do not overlap")
        label.pointerIsAt(NSPoint(x: size.midX, y: 9))
        XCTAssertTrue(label.isExpanded, "the size still answers where it is drawn")
    }

    /// An address the bar had to cut short is not on screen: there is nothing
    /// there to right-click, and no menu naming digits the user cannot read.
    func testATruncatedAddressIsNotAimedAt() throws {
        let (label, container) = makeLabel(width: 30, parts: line(digits: "0002E6"),
                                           sizeIndex: 1, fileSize: 2 * 1024 * 1024,
                                           digits: "0002E6")

        XCTAssertNil(label.offsetRegion, "the address is past the truncation")
        XCTAssertNil(label.offsetMenu(at: NSPoint(x: 10, y: 9)))
        XCTAssertTrue(container.hitTest(NSPoint(x: 10, y: 9)) === container)
    }

    /// A bar told about an offset it has no part for aims at nothing, rather
    /// than at whatever character position the arithmetic lands on.
    func testAnOffsetTheLineDoesNotHoldIsNotAimedAt() throws {
        let (label, _) = makeLabel(width: 800, parts: line(digits: "0002E6"),
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024,
                                   digits: "0002E6", offsetIndex: 9)
        XCTAssertNil(label.offsetRegion)
    }

    /// The region is the address's own mouse surface, and the rest of the bar is
    /// left to the pane behind it — a click beside the address focuses the dump,
    /// exactly as it did before the offset was interactive (§3.3).
    func testOnlyTheAddressIsHitAndTheRestOfTheBarPassesThrough() throws {
        let (label, container) = makeLabel(width: 800, parts: line(digits: "0002E6"),
                                           sizeIndex: 1, fileSize: 2 * 1024 * 1024,
                                           digits: "0002E6")
        let region = try XCTUnwrap(label.offsetRegion)

        let onAddress = NSPoint(x: region.midX, y: 9)
        let besideAddress = NSPoint(x: region.maxX + 20, y: 9)

        XCTAssertTrue(container.hitTest(onAddress) === label, "the address takes the pointer")
        XCTAssertTrue(container.hitTest(besideAddress) === container,
                      "the rest of the bar belongs to the pane")
        XCTAssertTrue(label.hitTest(onAddress) === label)
        XCTAssertNil(label.hitTest(besideAddress))
    }

    /// The right-click asks for the digits the bar is drawing — the drawn
    /// address, not a second formatting of the offset read again at click time,
    /// which the bar may have changed under the open menu — and only for a point
    /// that is on the address at all.
    func testTheRightClickAsksForTheDigitsTheBarDraws() throws {
        let (label, _) = makeLabel(width: 800, parts: line(digits: "0002E6"),
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024,
                                   digits: "0002E6")
        var asked: [String] = []
        label.offsetMenuProvider = { asked.append($0); return NSMenu(title: "Offset") }

        let region = try XCTUnwrap(label.offsetRegion)
        XCTAssertNil(label.offsetMenu(at: NSPoint(x: region.maxX + 20, y: 9)))
        XCTAssertTrue(asked.isEmpty, "the menu is not built for a point off the address")

        XCTAssertNotNil(label.offsetMenu(at: NSPoint(x: region.midX, y: 9)))
        XCTAssertEqual(asked, ["0002E6"])

        // The size's own region does not answer with the address: the two menus
        // are two subjects, and the right-click picks by where it landed.
        let size = try XCTUnwrap(label.sizeRegion)
        XCTAssertNil(label.offsetMenu(at: NSPoint(x: size.midX, y: 9)))
        XCTAssertEqual(asked, ["0002E6"])
    }

    /// A transient message (§11) takes the address off screen with it: while
    /// "No match found." is up there is no offset to right-click.
    func testATransientMessageLeavesNoAddressToAimAt() throws {
        let (label, _) = makeLabel(width: 800, parts: line(digits: "0002E6"),
                                   sizeIndex: 1, fileSize: 2 * 1024 * 1024,
                                   digits: "0002E6")
        let region = try XCTUnwrap(label.offsetRegion)

        label.showTransient("No match found.")

        XCTAssertNil(label.offsetRegion)
        XCTAssertNil(label.offsetMenu(at: NSPoint(x: region.midX, y: 9)))
        XCTAssertEqual(label.stringValue, "No match found.")
    }

    /// The controller's menu: one item, titled with the address it will copy,
    /// and the pasteboard ends up holding exactly the digits the bar drew — no
    /// "0x", no padding the bar did not show, nothing else.
    func testTheMenuCopiesTheAddressAsTheBarDrawsIt() throws {
        let controller = MainViewController()
        let digits = "0002E6"

        let item = try XCTUnwrap(controller.makeStatusOffsetMenu(digits: digits).items.first)
        XCTAssertEqual(item.title, "Copy offset \(digits)")
        XCTAssertEqual(controller.makeStatusOffsetMenu(digits: digits).numberOfItems, 1,
                       "copying is all this menu does — the dump's own menu is where blocks live (§10.2)")

        controller.copyStatusValue(item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "0002E6")
    }

    /// The whole way through, in a pane as the app builds one: the bar composes
    /// its line, publishes the address's region against the label's real width,
    /// and hands the right-click to the controller's menu — which puts the
    /// address the bar is drawing on the clipboard.
    func testThePanePublishesTheAddressRegionAndMenu() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 300))
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer {
            // The window goes first, as every other suite here does: a window
            // left ordered front outlives the test, and releasing one that is
            // still key is how a test host dies inside XCTest's scope teardown.
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
        let region = try XCTUnwrap(label.offsetRegion, "the bar has a width, so the address is on screen")

        // Three hundred bytes is three hex digits wide, so the caret at zero is
        // drawn "000" (§21.3) — and the region is over those digits, not over
        // the word "Offset" in front of them.
        XCTAssertEqual(covered(region, in: label), "000")
        XCTAssertTrue(label.stringValue.hasPrefix("Offset 000  ·  "), "the offset leads the line")

        let item = try XCTUnwrap(label.offsetMenu(at: NSPoint(x: region.midX, y: region.midY))?
            .items.first, "the pane wired the controller's menu onto the bar")
        XCTAssertEqual(item.title, "Copy offset 000")

        controller.copyStatusValue(item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "000")
    }
}
