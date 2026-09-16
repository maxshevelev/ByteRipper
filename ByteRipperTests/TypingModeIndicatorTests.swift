import ByteRipperCore
import XCTest
@testable import ByteRipper

/// §7.6 / §15: the pane's status bar carries the typing-mode indicator — `OVR`
/// in the bar's quiet grey, `INS` in the insert caret's red, bold in both, and
/// drawn in a box of its own, wearing the colour of the word inside it, because
/// a click on it flips the mode (§24.2). The mode is not a property of the file,
/// so the indicator follows the mode with or without one open, and it flips the
/// moment the mode does, without waiting for an edit.
@MainActor
final class TypingModeIndicatorTests: XCTestCase {
    private func makePane(_ bytes: [UInt8]) throws -> (FilePaneView, PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        let pane = FilePaneView(viewModel: viewModel)
        pane.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        pane.layoutSubtreeIfNeeded()
        return (pane, viewModel, url)
    }

    /// Red is judged the way the caret tests judge it: red minus blue, in
    /// device RGB. `secondaryLabelColor` is neutral grey, `systemRed` is not.
    private func redness(_ colour: NSColor?) -> CGFloat {
        guard let rgb = colour?.usingColorSpace(.deviceRGB) else { return 0 }
        return rgb.redComponent - rgb.blueComponent
    }

    /// What the label actually puts on the screen, as pixels. Everything about
    /// the box — that it is drawn, how thick, in what colour, and where the text
    /// sits inside it — is read out of this rather than out of the label's own
    /// arithmetic, because AppKit's cell decides where a borderless field's line
    /// goes and its answer is not the obvious one.
    private func render(_ label: NSTextField) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(label.bitmapImageRepForCachingDisplay(in: label.bounds))
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep
    }

    private func scale(of rep: NSBitmapImageRep, in label: NSTextField) -> CGFloat {
        CGFloat(rep.pixelsWide) / max(label.bounds.width, 1)
    }

    /// The indicator in both of its states, in the pane it belongs to: a fresh
    /// pane sits in overwrite mode and says so quietly, turning insert mode on
    /// makes it red, and turning it off goes back.
    func testTheStatusBarShowsOVRInGreyAndINSInRed() throws {
        let (pane, viewModel, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(pane.typingModeLabel.stringValue, "OVR")
        XCTAssertLessThan(redness(pane.typingModeLabel.textColor), 0.2,
                          "overwrite is the quiet default, not a warning")
        XCTAssertEqual(pane.typingModeLabel.accessibilityLabel(), "Overwrite mode")

        viewModel.isInsertMode = true

        XCTAssertEqual(pane.typingModeLabel.stringValue, "INS")
        XCTAssertGreaterThan(redness(pane.typingModeLabel.textColor), 0.4,
                             "INS is red — the mode grows the file on every keystroke")
        XCTAssertEqual(pane.typingModeLabel.accessibilityLabel(), "Insert mode")

        viewModel.isInsertMode = false
        XCTAssertEqual(pane.typingModeLabel.stringValue, "OVR")
        XCTAssertLessThan(redness(pane.typingModeLabel.textColor), 0.2)
        XCTAssertEqual(pane.typingModeLabel.accessibilityLabel(), "Overwrite mode",
                       "and the accessibility label goes back with it")
    }

    /// A pane built while the mode is already on shows INS immediately — the
    /// mode is session-global, so a file opened later inherits it.
    func testAPaneOpenedWhileInsertModeIsOnStartsAsINS() throws {
        let url = try tempFile([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = PaneViewModel()
        viewModel.isInsertMode = true
        try viewModel.open(url: url)

        let pane = FilePaneView(viewModel: viewModel)

        XCTAssertEqual(pane.typingModeLabel.stringValue, "INS")
    }

    /// The indicator is bold, in both states. It is a word at the end of a line
    /// of quiet grey that has to be caught without being read (§7.6).
    func testTheIndicatorIsBoldInBothStates() throws {
        let (pane, viewModel, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try XCTUnwrap(pane.typingModeLabel.font)
            .fontDescriptor.symbolicTraits.contains(.bold), "OVR is bold")

        viewModel.isInsertMode = true

        XCTAssertTrue(try XCTUnwrap(pane.typingModeLabel.font)
            .fontDescriptor.symbolicTraits.contains(.bold), "and INS is bold too")
        XCTAssertTrue(try XCTUnwrap(pane.typingModeLabel.font).isFixedPitch,
                      "still monospaced: INS and OVR have to be the same width")
    }

    /// The indicator is a box around three characters, not three characters
    /// (§24.2): the label asks for the room its frame needs, the frame is drawn
    /// visibly, and the text sits in the middle of it — across and down both.
    ///
    /// Read out of a rendering rather than out of the label's arithmetic. The
    /// measurements this guards are ones the code got wrong in exactly these
    /// ways: a frame in `separatorColor`, which resolves to 0.098 alpha — drawn,
    /// and invisible over the status bar; a text run measured 3 points from the
    /// box's left side and 13.5 from its right, because `NSTextField` assigns
    /// `.natural` to a label created with `labelWithString:` and threw away the
    /// alignment its own initializer had set; and the same run 3 points above
    /// the box's middle, because a borderless field draws its line from the top
    /// of its bounds and a line box is taller than a cap-height word.
    func testTheIndicatorIsDrawnInABox() throws {
        let (pane, _, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        let label = pane.typingModeLabel
        let text = (label.stringValue as NSString)
            .size(withAttributes: [.font: try XCTUnwrap(label.font)]).width

        XCTAssertGreaterThan(label.bounds.width, text + 8,
                             "the label holds more than its text: the box needs room around it")

        let rep = try render(label)
        let scale = scale(of: rep, in: label)
        // Along the middle of the label, where the frame's sides are straight
        // lines whatever the corner radius is — and where the text sits, which
        // is what tells a frame from a fill.
        let row = Int(label.bounds.midY * scale)
        func ink(atX x: CGFloat) -> CGFloat {
            rep.colorAt(x: min(Int(x * scale), rep.pixelsWide - 1), y: row)?.alphaComponent ?? 0
        }

        XCTAssertLessThan(ink(atX: 0.5), 0.02, "nothing outside the box")
        XCTAssertGreaterThan(ink(atX: 2), 0.3,
                             "the box's near side is drawn, and dark enough to be seen")
        XCTAssertGreaterThan(ink(atX: label.bounds.width - 2), 0.3, "and so is the far side")
        XCTAssertLessThan(ink(atX: 5), 0.02,
                          "and it is a frame, not a fill: the space before the text is bare")

        // The text is centred between the two sides it is drawn between. Read
        // from the ink itself, skirting the frame's own band on each edge.
        var firstInk: CGFloat?
        var lastInk: CGFloat?
        for pixel in 0..<rep.pixelsWide {
            let x = CGFloat(pixel) / scale
            guard x > 6, x < label.bounds.width - 6,
                  (rep.colorAt(x: pixel, y: row)?.alphaComponent ?? 0) > 0.02 else { continue }
            firstInk = firstInk ?? x
            lastInk = x
        }
        let textMiddle = ((try XCTUnwrap(firstInk)) + (try XCTUnwrap(lastInk))) / 2
        XCTAssertEqual(textMiddle, label.bounds.midX, accuracy: 1.5,
                       "the text sits in the middle of its box, not against one side")

        // And it is centred downwards too, in a run of rows taken from the
        // middle columns — the frame's top and bottom edges cross every column,
        // so the first and last three points of the height are left out. The
        // label is 20 points tall, so its own middle is the same number of
        // points from the top of the bitmap as from the bottom: this reads the
        // same whichever way round the pixels come back.
        let band: CGFloat = 3
        var firstRow: Int?
        var lastRow: Int?
        for y in 0..<rep.pixelsHigh {
            let fromEdge = CGFloat(y) / scale
            guard fromEdge > band, fromEdge < label.bounds.height - band else { continue }
            let inked = (Int(6 * scale)..<Int((label.bounds.width - 6) * scale)).contains {
                (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.02
            }
            if inked {
                firstRow = firstRow ?? y
                lastRow = y
            }
        }
        let textTop = CGFloat(try XCTUnwrap(firstRow)) / scale
        let textBottom = CGFloat(try XCTUnwrap(lastRow) + 1) / scale
        XCTAssertEqual((textTop + textBottom) / 2, label.bounds.midY, accuracy: 1,
                       "the text sits in the middle of its box, not against its top")
    }

    /// The word is drawn the right way up.
    ///
    /// Worth a test of its own because the other two measurements cannot see
    /// this: a run mirrored about its baseline has the same ink box, the same
    /// width and the same middle, and only its shape gives it away. The label
    /// draws its own line, and this view is flipped, as a label's is — a line
    /// drawn with `CTLineDraw` straight into this context comes out mirrored,
    /// which is what the first version of the box did.
    func testTheTextIsNotUpsideDown() throws {
        let label = TypingModeLabel(labelWithString: "T")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.frame = NSRect(origin: .zero, size: label.intrinsicContentSize)
        label.layoutSubtreeIfNeeded()

        let rep = try render(label)
        let scale = scale(of: rep, in: label)
        // "T" is a wide bar over a narrow stem: read downwards through the ink,
        // the upper half carries far more of it than the lower half. Mirrored,
        // that is the other way round.
        let band: CGFloat = 3
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            let fromEdge = CGFloat(y) / scale
            guard fromEdge > band, fromEdge < label.bounds.height - band else { continue }
            rows.append((Int(6 * scale)..<Int((label.bounds.width - 6) * scale))
                .reduce(0) { count, x in
                    count + ((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 ? 1 : 0)
                })
        }
        let inked = rows.filter { $0 > 0 }
        let half = inked.count / 2
        let upper = inked.prefix(half).reduce(0, +)
        let lower = inked.suffix(half).reduce(0, +)
        XCTAssertGreaterThan(upper, lower * 2,
                             "the crossbar of the T is at the top of the word, so the word is upright")
    }

    /// The box wears the mode's colour, the one the word inside it is written
    /// in: grey around `OVR`, the caret's red around `INS` (§3.4). One object,
    /// not a word saying one thing inside a frame saying another.
    func testTheBoxWearsTheModeColour() throws {
        let (pane, viewModel, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        let label = pane.typingModeLabel

        /// The colour of the box's near side, halfway down the label, where the
        /// side is a straight line of its full thickness.
        func boxColour() throws -> NSColor? {
            let rep = try render(label)
            return rep.colorAt(x: Int(2 * scale(of: rep, in: label)),
                               y: Int(label.bounds.midY * scale(of: rep, in: label)))
        }

        XCTAssertEqual(redness(try boxColour()), redness(label.textColor), accuracy: 0.05,
                       "overwrite draws its box in the grey its own word is drawn in")
        XCTAssertLessThan(redness(try boxColour()), 0.1, "which is no colour at all")

        viewModel.isInsertMode = true

        XCTAssertGreaterThan(redness(try boxColour()), 0.4,
                             "insert draws it red, with the caret — not a grey box round a red word")
        XCTAssertEqual(redness(try boxColour()), redness(label.textColor), accuracy: 0.05,
                       "and it follows the word into the other state")
    }

    /// The mode belongs to a pane, not to the window (§7.6): the Edit menu's
    /// toggle flips the active pane, and the other pane's indicator does not
    /// move. One file can be typed into while the other is read.
    func testTheEditMenuToggleFlipsOnlyTheActivePane() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)

        controller.toggleInsertMode(nil)

        XCTAssertTrue(controller.windowModel.pane1.status.isInsertMode, "the active pane")
        XCTAssertFalse(controller.windowModel.pane2.status.isInsertMode, "the other one")

        controller.toggleInsertMode(nil)

        XCTAssertFalse(controller.windowModel.pane1.status.isInsertMode)
        XCTAssertFalse(controller.windowModel.pane2.status.isInsertMode)
    }

}
