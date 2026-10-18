import ByteRipperCore
import XCTest
@testable import ByteRipper

/// The hover callout (§19.4.3, §20.3): where the capsule goes, and — in the
/// dump — when it is up and every event that takes it away. The minimap's
/// side of it is in `BookmarkMinimapTests`.
@MainActor
final class HoverCalloutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppDefaults.store.set(1, forKey: WordSize.userDefaultsKey)
    }

    // MARK: - Placement

    private let size = NSSize(width: 80, height: 20)
    private let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

    func testItOpensOnTheSideItIsAskedTo() {
        let anchor = NSRect(x: 100, y: 100, width: 10, height: 10)

        let right = HoverCallout.capsuleFrame(size: size, beside: anchor, opensRight: true, within: bounds)
        XCTAssertEqual(right.minX, anchor.maxX + HoverCallout.gap)
        XCTAssertEqual(right.midY, anchor.midY, "level with what it names")

        let left = HoverCallout.capsuleFrame(size: size, beside: anchor, opensRight: false, within: bounds)
        XCTAssertEqual(left.maxX, anchor.minX - HoverCallout.gap)
    }

    /// A side without room is given up for the other one rather than cut off.
    func testItTurnsToTheOtherSideWhenOneHasNoRoom() {
        let nearTheRight = NSRect(x: 360, y: 100, width: 10, height: 10)
        let frame = HoverCallout.capsuleFrame(size: size, beside: nearTheRight, opensRight: true, within: bounds)
        XCTAssertEqual(frame.maxX, nearTheRight.minX - HoverCallout.gap)

        let nearTheLeft = NSRect(x: 20, y: 100, width: 10, height: 10)
        let other = HoverCallout.capsuleFrame(size: size, beside: nearTheLeft, opensRight: false, within: bounds)
        XCTAssertEqual(other.minX, nearTheLeft.maxX + HoverCallout.gap)
    }

    /// Next to the top or bottom edge it is moved in, never cut off.
    func testItStaysInsideTheWindow() {
        let atTheTop = NSRect(x: 100, y: 295, width: 10, height: 10)
        XCTAssertEqual(HoverCallout.capsuleFrame(size: size, beside: atTheTop, opensRight: true,
                                                 within: bounds).maxY, bounds.maxY)
        let atTheBottom = NSRect(x: 100, y: -5, width: 10, height: 10)
        XCTAssertEqual(HoverCallout.capsuleFrame(size: size, beside: atTheBottom, opensRight: true,
                                                 within: bounds).minY, bounds.minY)
    }

    // MARK: - The dump's marks (§20.3)

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    /// A pane hosting a real hex view in a real key window, with a bookmark
    /// store wired the way `WindowViewModel` wires one.
    private func makePane() throws -> (hexView: HexView, window: NSWindow, store: BookmarkStore) {
        try makePaneAndModel().map
    }

    private func makePaneAndModel() throws
        -> (map: (hexView: HexView, window: NSWindow, store: BookmarkStore), pane: PaneViewModel) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callout-\(UUID().uuidString).bin")
        try Data([UInt8](repeating: 0x11, count: 0x10000)).write(to: url)
        tempFiles.append(url)

        let pane = PaneViewModel()
        let store = BookmarkStore()
        pane.bookmarks = BookmarkSpace(store: store)
        store.onChange = { [weak pane] row in pane?.onBookmarksChanged?(row) }
        try pane.open(url: url)

        let filePane = FilePaneView(viewModel: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        filePane.translatesAutoresizingMaskIntoConstraints = false
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(filePane)
        NSLayoutConstraint.activate([
            filePane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filePane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filePane.topAnchor.constraint(equalTo: content.topAnchor),
            filePane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        let hexView = try XCTUnwrap(filePane.scrollView.documentView as? HexView)
        addTeardownBlock { @MainActor in
            pane.close()
            window.orderOut(nil)
        }
        return ((hexView, window, store), pane)
    }

    /// The pointer arriving over the address of `row`.
    private func hoverAddress(_ hexView: HexView, row: Int, window: NSWindow) {
        let frame = hexView.hexLayout.offsetColumnFrame(row: row)
        let point = hexView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        hexView.mouseMoved(with: mouse(.mouseMoved, at: point, window: window))
    }

    /// A named mark's address says the name at once, beside the mark and over
    /// the row's bytes — never over the address it stands for. An unmarked
    /// row, and a mark with no name, say nothing.
    func testAMarkedAddressSaysItsNameAtOnce() throws {
        let (hexView, window, store) = try makePane()
        store.add(rowContaining: 0x10, name: "ME region")
        store.add(rowContaining: 0x30)

        hoverAddress(hexView, row: 1, window: window)
        let callout = hexView.hoverCallout
        XCTAssertTrue(callout.isShowing)
        XCTAssertEqual(callout.text, "ME region")
        XCTAssertEqual(callout.mark, .bookmark, "wearing the mark it names")
        let capsule = hexView.convert(callout.capsuleFrame, from: callout.superview)
        let mark = hexView.bookmarkMarkRect(forRowContaining: 0x10)
        XCTAssertGreaterThan(capsule.minX, mark.maxX, "it opens to the right of the address")
        XCTAssertEqual(capsule.midY, mark.midY, accuracy: 1, "level with the row")

        hoverAddress(hexView, row: 2, window: window)
        XCTAssertFalse(callout.isShowing, "an unmarked row has nothing to say")
        hoverAddress(hexView, row: 1, window: window)
        XCTAssertTrue(callout.isShowing)
        hoverAddress(hexView, row: 3, window: window)
        XCTAssertFalse(callout.isShowing, "nor has a mark with no name")
    }

    /// Every event after which the callout would be naming the wrong row, or a
    /// row the pointer is no longer on, takes it away. Each is tried from a
    /// fresh hover, so one rule cannot pass on another's account.
    func testTheCalloutGoesWithEveryEventThatWouldMakeItWrong() throws {
        let (hexView, window, store) = try makePane()
        store.add(rowContaining: 0x10, name: "ME region")
        let callout = hexView.hoverCallout

        func showThen(_ what: String, _ act: () throws -> Void) rethrows {
            hexView.scrollRowToTop(containing: 0)
            hoverAddress(hexView, row: 1, window: window)
            XCTAssertTrue(callout.isShowing, "shown before: \(what)")
            try act()
            XCTAssertFalse(callout.isShowing, "hidden after: \(what)")
        }

        showThen("the pointer leaving the dump") {
            hexView.mouseExited(with: mouse(.mouseMoved, at: .zero, window: window))
        }
        showThen("a scroll") {
            hexView.scrollRowToTop(containing: 0x800)
        }
        showThen("a press on the mark, which may start dragging it") {
            let frame = hexView.hexLayout.offsetColumnFrame(row: 1)
            let point = hexView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            hexView.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))
            hexView.mouseUp(with: mouse(.leftMouseUp, at: point, window: window))
        }
        showThen("the bookmark being renamed") {
            store.rename(rowContaining: 0x10, to: "ME firmware")
        }
        showThen("the bookmark being removed") {
            store.remove(rowContaining: 0x10)
            store.add(rowContaining: 0x10, name: "ME region")
        }
        showThen("the window stopping being key") {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        try showThen("the dump leaving its window") {
            let scroll = try XCTUnwrap(hexView.enclosingScrollView)
            scroll.documentView = nil
            scroll.documentView = hexView
        }
    }

    /// A mark being dragged is a row further on with every step, so the
    /// callout does not come back while the drag is on.
    func testNoCalloutWhileAMarkIsDragged() throws {
        let (hexView, window, store) = try makePane()
        store.add(rowContaining: 0x10, name: "ME region")
        let frame = hexView.hexLayout.offsetColumnFrame(row: 1)
        let point = hexView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)

        hexView.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))
        hoverAddress(hexView, row: 1, window: window)
        XCTAssertFalse(hexView.hoverCallout.isShowing)
        hexView.mouseUp(with: mouse(.leftMouseUp, at: point, window: window))
        hoverAddress(hexView, row: 1, window: window)
        XCTAssertTrue(hexView.hoverCallout.isShowing, "and is back once it is dropped")
    }

    // MARK: - Notes on the bytes

    /// A note speaks on its outline, at once, with its author's dashed frame
    /// for a glyph, and follows the pointer along the line — and says nothing
    /// over the bytes inside it, which it would otherwise keep covering.
    func testANoteSpeaksOnItsOutlineOnly() throws {
        let (hexView, window) = try makeAnnotatedPane(by: .person)
        let layout = hexView.hexLayout
        let callout = hexView.hoverCallout

        let edge = try XCTUnwrap(topEdgeY(hexView, column: 3), "the note's top edge is somewhere near row 4's top")
        hover(hexView, at: NSPoint(x: byteX(layout, column: 3), y: edge), window: window)
        XCTAssertTrue(callout.isShowing, "on the outline the note speaks")
        XCTAssertEqual(callout.text, "Signature\nMagic.")
        XCTAssertEqual(callout.mark, .annotation(HexTheme.personMark), "in the person's hue")

        let first = callout.capsuleFrame
        hover(hexView, at: NSPoint(x: byteX(layout, column: 10), y: edge), window: window)
        XCTAssertTrue(callout.isShowing)
        XCTAssertEqual(callout.capsuleFrame.midX - first.midX,
                       byteX(layout, column: 10) - byteX(layout, column: 3), accuracy: 1,
                       "it follows the pointer along the line")

        hover(hexView, at: NSPoint(x: byteX(layout, column: 7), y: 5 * layout.rowHeight), window: window)
        XCTAssertFalse(callout.isShowing, "inside the note, over its bytes, nothing covers them")
        hover(hexView, at: NSPoint(x: byteX(layout, column: 7), y: 8.5 * layout.rowHeight), window: window)
        XCTAssertFalse(callout.isShowing, "and nothing outside it either")
    }

    /// The outline answers the same distance either side of it on both of its
    /// edges: the left one lies against the Offset column, and the part of its
    /// reach over that column is the note's as much as the part over the
    /// bytes — the right edge has the same reach over the gap before the
    /// decoded text.
    func testBothEdgesOfANoteAnswerAsFarOut() throws {
        let (hexView, window) = try makeAnnotatedPane(by: .person)
        let layout = hexView.hexLayout
        // Halfway down the note's two rows, on its vertical edges.
        let y = 5 * layout.rowHeight
        // Measured round each line only: the decoded text's own outline starts
        // a few points past the hex column's right edge, and is another edge.
        let pad = HexView.mirrorContourPadding
        func reach(around x: CGFloat) -> [CGFloat] {
            stride(from: x - 5.5, through: x + 5.5, by: 0.5)
                .filter { hexView.noteContour(at: NSPoint(x: $0, y: y)) != nil }
        }
        let left = reach(around: layout.hexByteX(column: 0) - pad)
        let right = reach(around: layout.hexByteX(column: 15) + layout.hexByteWidth + pad)
        XCTAssertFalse(left.isEmpty)
        XCTAssertEqual(left.count, right.count, "the two edges reach as far")

        for x in left + right {
            hover(hexView, at: NSPoint(x: x, y: y), window: window)
            XCTAssertTrue(hexView.hoverCallout.isShowing, "the note answers at x = \(x)")
        }
        let outside = try XCTUnwrap(left.first) - 2
        hover(hexView, at: NSPoint(x: outside, y: y), window: window)
        XCTAssertFalse(hexView.hoverCallout.isShowing, "and an address beyond its reach says nothing")
    }

    /// An agent's note wears the agent's hue, not the person's: the two are
    /// told apart in the callout as they are in the dump.
    func testAnAgentsNoteWearsTheAgentsHue() throws {
        let (hexView, window) = try makeAnnotatedPane(by: .agent)

        let edge = try XCTUnwrap(topEdgeY(hexView, column: 3))
        hover(hexView, at: NSPoint(x: byteX(hexView.hexLayout, column: 3), y: edge), window: window)
        XCTAssertTrue(hexView.hoverCallout.isShowing)
        XCTAssertEqual(hexView.hoverCallout.mark, .annotation(HexTheme.agentMark))
        XCTAssertNotEqual(HexTheme.agentMark, HexTheme.personMark, "and the two hues are different colours")
    }

    /// A pane with one note, by `author`, on 0x40..<0x60 — rows 4 and 5.
    private func makeAnnotatedPane(by author: AgentAnnotation.Author) throws -> (HexView, NSWindow) {
        let (made, pane) = try makePaneAndModel()
        let document = try XCTUnwrap(pane.document)
        let source = PaneViewModel.annotationSource
        PaneViewModel.annotationSource = { _ in
            [AgentAnnotation(id: "a1", file: .document(WeakDocument(document)), range: 0x40..<0x60, node: nil,
                             title: "Signature", note: "Magic.", relatedTo: [], author: author)]
        }
        PaneViewModel.annotationGeneration += 1
        addTeardownBlock { @MainActor in
            PaneViewModel.annotationSource = source
            PaneViewModel.annotationGeneration += 1
        }
        return (made.hexView, made.window)
    }

    /// The middle of the hex byte in `column`.
    private func byteX(_ layout: HexLayout, column: Int) -> CGFloat {
        layout.hexByteX(column: column) + layout.charWidth
    }

    /// The pointer arriving at `point`, in the hex view's coordinates.
    private func hover(_ hexView: HexView, at point: NSPoint, window: NSWindow) {
        hexView.mouseMoved(with: mouse(.mouseMoved, at: hexView.convert(point, to: nil), window: window))
    }

    /// The y of the note's top edge above `column`: the middle of the band
    /// round row 4's top that `noteContour` answers in — found rather than
    /// computed, so the test holds whatever padding the outline is drawn with.
    private func topEdgeY(_ hexView: HexView, column: Int) -> CGFloat? {
        let layout = hexView.hexLayout
        let x = byteX(layout, column: column)
        let top = 4 * layout.rowHeight
        let hits = stride(from: top - 10, through: top + 10, by: 0.5)
            .filter { hexView.noteContour(at: NSPoint(x: x, y: $0)) != nil }
        guard let low = hits.first, let high = hits.last else { return nil }
        return (low + high) / 2
    }
}
