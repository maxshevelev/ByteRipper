import ByteRipperCore
import XCTest
@testable import ByteRipper

/// A note's dashed outline over a large stretch of the dump: drawn from the
/// part near the rows being painted, so a scroll over a note of megabytes
/// costs what a scroll over a small one does — and the dashes still stand
/// still while it scrolls.
@MainActor
final class NoteOutlineTests: XCTestCase {
    // MARK: - Folding the outline

    /// A tall rectangle is brought in to just outside the band, by whole dash
    /// periods, and what lies in the band is left where it was.
    func testATallOutlineIsBroughtInByWholePeriods() {
        let loop = [CGPoint(x: 10, y: -10_000), CGPoint(x: 90, y: -10_000),
                    CGPoint(x: 90, y: 50_000), CGPoint(x: 10, y: 50_000)]
        let band: ClosedRange<CGFloat> = 1000...1200
        let folded = HexView.outlinesFolded([loop], into: band, period: 7)[0]

        for (before, after) in zip(loop, folded) {
            XCTAssertEqual(before.x, after.x, "only heights move")
            let moved = abs(after.y - before.y)
            XCTAssertEqual(moved.truncatingRemainder(dividingBy: 7), 0, accuracy: 0.001,
                           "by whole periods, so the dashes keep their phase")
            XCTAssertFalse(band.contains(after.y), "and the moved corners stay outside the band")
        }
        XCTAssertGreaterThan(folded[0].y, band.lowerBound - 7, "no more than a period above it")
        XCTAssertLessThan(folded[2].y, band.upperBound + 7, "and no more than a period below")
    }

    /// An outline whose corners already lie within a period of the band is
    /// not touched.
    func testANearbyOutlineIsLeftAlone() {
        let loop = [CGPoint(x: 10, y: 995), CGPoint(x: 90, y: 995),
                    CGPoint(x: 90, y: 1205), CGPoint(x: 10, y: 1205)]
        XCTAssertEqual(HexView.outlinesFolded([loop], into: 1000...1200, period: 7)[0], loop)
    }

    /// A staircase — a note starting and ending mid-row — keeps its steps: the
    /// corners above the band move together, so their row's height between
    /// them is kept.
    func testAStaircaseKeepsItsSteps() {
        let loop = [CGPoint(x: 40, y: -5000), CGPoint(x: 90, y: -5000), CGPoint(x: 90, y: 40_000),
                    CGPoint(x: 60, y: 40_000), CGPoint(x: 60, y: 40_016), CGPoint(x: 10, y: 40_016),
                    CGPoint(x: 10, y: -4984), CGPoint(x: 40, y: -4984)]
        let folded = HexView.outlinesFolded([loop], into: 1000...1200, period: 7)[0]
        XCTAssertEqual(folded[7].y - folded[0].y, 16, "the first row's step is still a row tall")
        XCTAssertEqual(folded[4].y - folded[3].y, 16, "and so is the last row's")
    }

    // MARK: - In the dump

    private var url: URL?

    override func tearDown() {
        if let url { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    /// A pane over an 8 MB file with one note on `range` — by default across
    /// nearly all of it — scrolled to `offset`.
    private func makeNotedPane(range: Range<UInt64> = 0x1000..<UInt64((8 << 20) - 0x1000),
                               scrolledTo offset: UInt64 = 0x200000) throws -> HexView {
        let size = 8 << 20
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).bin")
        try Data(count: size).write(to: url)
        self.url = url
        let pane = PaneViewModel()
        try pane.open(url: url)
        let filePane = FilePaneView(viewModel: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        filePane.frame = try XCTUnwrap(window.contentView).bounds
        filePane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(filePane)
        window.layoutIfNeeded()
        let hexView = try XCTUnwrap(filePane.scrollView.documentView as? HexView)
        let document = try XCTUnwrap(pane.document)
        let source = PaneViewModel.annotationSource
        PaneViewModel.annotationSource = { _ in
            [AgentAnnotation(id: "a1", file: .document(WeakDocument(document)),
                             range: range, node: nil,
                             title: "Big", note: "", relatedTo: [])]
        }
        PaneViewModel.annotationGeneration += 1
        addTeardownBlock { @MainActor in
            PaneViewModel.annotationSource = source
            PaneViewModel.annotationGeneration += 1
            pane.close()
            window.orderOut(nil)
        }
        hexView.scrollRowToTop(containing: offset)
        return hexView
    }

    /// Whether a pixel is the outline's dash rather than the wash, the text or
    /// the paper: a strong violet.
    private func isDash(_ colour: NSColor?) -> Bool {
        guard let c = colour?.usingColorSpace(.sRGB) else { return false }
        return c.saturationComponent > 0.35 && c.hueComponent > 0.7 && c.hueComponent < 0.9
    }

    /// The pixel column, in the left third of `rep`, that holds the most dash
    /// pixels: the hex column's left edge.
    private func dashedColumn(in rep: NSBitmapImageRep) -> Int? {
        let counts = (0..<rep.pixelsWide / 3).map { x in
            (x, (0..<rep.pixelsHigh).filter { isDash(rep.colorAt(x: x, y: $0)) }.count)
        }
        guard let top = counts.max(by: { $0.1 < $1.1 }), top.1 > 0 else { return nil }
        return top.0
    }

    private func render(_ hexView: HexView, _ rect: NSRect) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(hexView.bitmapImageRepForCachingDisplay(in: rect))
        hexView.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// Rows painted as part of a small dirty rect — where the note's outline
    /// is folded in from far above and below — come out exactly as they do in
    /// a rect holding the whole note, where nothing is folded: pixel for
    /// pixel, dashes included. A fold that moved the dash phase would make the
    /// outline crawl as the pane scrolls.
    func testTheDashesStandStillWhateverIsRepainted() throws {
        // 256 rows: tall enough to be folded from the middle, short enough to
        // be painted whole.
        let hexView = try makeNotedPane(range: 0x1000..<0x2000, scrolledTo: 0x1000)
        let layout = hexView.hexLayout
        let width = layout.asciiX(column: 0) + layout.asciiColumnWidth + 8
        // Both on whole points, so the one lies a whole number of pixels into
        // the other and a dash's anti-aliased end falls the same way in both.
        let small = NSRect(x: 0, y: floor(384 * layout.rowHeight), width: width, height: 3 * layout.rowHeight)
        let whole = NSRect(x: 0, y: floor(250 * layout.rowHeight), width: width, height: 268 * layout.rowHeight)
        let a = try render(hexView, small)
        let b = try render(hexView, whole)
        // From the height, which is whole points: the width is not, and its
        // pixels are rounded up.
        let scale = CGFloat(a.pixelsHigh) / small.height
        let offset = Int(((small.minY - whole.minY) * scale).rounded())

        // The dashes down the hex column's left edge, as a run of on and off.
        let column = try XCTUnwrap(dashedColumn(in: a), "the note's left edge is drawn in the small rect")
        let edge = (0..<a.pixelsHigh).map { isDash(a.colorAt(x: column, y: $0)) }
        let mismatched = zip(edge, (0..<a.pixelsHigh).map { isDash(b.colorAt(x: column, y: $0 + offset)) })
            .filter { $0 != $1 }.count
        XCTAssertTrue(edge.contains(true) && edge.contains(false), "the edge is dashed here")
        XCTAssertEqual(mismatched, 0, "the folded outline's dashes are where the whole one's are")
    }

    /// The cost that made this worth doing: painting a screen of rows inside
    /// an 8 MB note took over half a second. The bound is loose — a machine
    /// under load is slower — but nowhere near what laying dashes along the
    /// whole note cost.
    func testPaintingInsideAHugeNoteIsCheap() throws {
        let hexView = try makeNotedPane()
        let start = Date()
        for step in 0..<10 {
            hexView.scrollRowToTop(containing: UInt64(0x200000 + step * 0x400))
            _ = try render(hexView, hexView.visibleRect)
        }
        let perStep = Date().timeIntervalSince(start) / 10
        XCTAssertLessThan(perStep, 0.2, "one screen of rows inside a note of megabytes: \(perStep) s")
    }
}
