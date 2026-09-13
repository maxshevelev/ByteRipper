import AppKit
import XCTest
@testable import ToolModuleKit

/// The row marks every firmware panel shares (`Design/ROW_MARKS.md`): the
/// value, how a cell wears it, and the legend that explains it.
@MainActor
final class ToolRowMarksTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "ToolRowMarksTests"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        ToolPanelFont.defaults = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        ToolPanelFont.defaults = .standard
        super.tearDown()
    }

    // MARK: - The value

    func testTheWorstProblemIsTheOneShown() {
        XCTAssertNil(ToolRowMarks.Problem.worst(errors: [], cautions: []))
        XCTAssertEqual(ToolRowMarks.Problem.worst(errors: [], cautions: ["c"]), .caution(["c"]))
        XCTAssertEqual(ToolRowMarks.Problem.worst(errors: ["e"], cautions: ["c"]), .error(["e", "c"]),
                       "an error wins, and the caution is still in the tooltip")
    }

    /// Nothing is said by colour alone: the background and the rail are words
    /// in the row's tooltip.
    func testTheBackgroundAndTheRailAreSaidInWords() {
        XCTAssertNil(ToolRowMarks.none.summary)
        let marks = ToolRowMarks(protection: .ibb, decompressedFrom: "Decompressed from LZMA at 0x60")
        XCTAssertEqual(marks.summary, "Inside the Boot Guard IBB · Decompressed from LZMA at 0x60")
    }

    /// The compressed section that opens starts the rail its rows wear, and
    /// says so in words too.
    func testTheSectionThatOpensWearsTheRailAndSaysWhy() {
        let opener = ToolRowMarks(opensDecompressed: true)
        XCTAssertTrue(opener.hasRail)
        XCTAssertEqual(opener.summary, "Compressed: what it holds is listed under it, decompressed")
        XCTAssertFalse(ToolRowMarks.none.hasRail)
    }

    func testEveryIconMarkHasASymbolAndThePaintHasNone() {
        for mark in ToolRowMark.allCases {
            let isPaint = mark.channel == .background || mark.channel == .rail
            XCTAssertEqual(mark.symbol == nil, isPaint, "\(mark)")
            if let symbol = mark.symbol {
                XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                                "\(symbol) is not a symbol this system has")
            }
        }
    }

    // MARK: - The cell

    func testACellWearsTheProblemAndTheBadges() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("name"), warning: true, badges: true)
        let marks = ToolRowMarks(
            decompressedFrom: "Decompressed from LZMA at 0x60",
            problem: .caution(["did not decompress"]),
            roles: [.compressed(algorithm: "LZMA", decoded: false)]
        )
        ToolPanelTable.dress(cell, with: marks)

        let problem = try XCTUnwrap(cell.imageView)
        XCTAssertFalse(problem.isHidden)
        XCTAssertEqual(problem.toolTip, "did not decompress")
        let badges = ToolPanelTable.badgeTags.compactMap { cell.viewWithTag($0) as? NSImageView }
        XCTAssertEqual(badges.map(\.isHidden), [false, true], "one role, one badge")
        XCTAssertEqual(badges.first?.toolTip, "LZMA compressed data that does not open here")
        XCTAssertEqual(cell.toolTip, "Decompressed from LZMA at 0x60")

        // Recycled onto a row with nothing: nothing lingers.
        ToolPanelTable.dress(cell, with: .none)
        XCTAssertTrue(problem.isHidden)
        XCTAssertEqual(badges.map(\.isHidden), [true, true])
        XCTAssertNil(cell.toolTip)
    }

    /// The FIT panel's existing call still shows the red octagon, even on a
    /// cell last dressed with a caution.
    func testTheOldWarningCallStillShowsAnError() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("type"), warning: true)
        ToolPanelTable.setProblem(.caution(["later"]), on: cell)
        ToolPanelTable.setWarning(true, on: cell, explanation: "wrong")

        let icon = try XCTUnwrap(cell.imageView)
        XCTAssertFalse(icon.isHidden)
        XCTAssertEqual(icon.image?.accessibilityDescription, "Invalid")
        XCTAssertEqual(icon.toolTip, "wrong")
    }

    // MARK: - The row view

    /// What the row view paints, read back off a bitmap: the rail at the
    /// leading edge and nothing beside it — and nothing at all with the
    /// markings off.
    func testTheRowViewPaintsTheRailOnlyWhileMarkingsAreShown() throws {
        let row = ToolPanelRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        row.appearance = NSAppearance(named: .aqua)
        row.marks = ToolRowMarks(decompressedFrom: "Decompressed")

        func pixels() throws -> (rail: NSColor, beside: NSColor) {
            let rep = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / row.bounds.width
            let y = Int(10 * scale)
            return (try XCTUnwrap(rep.colorAt(x: Int(1 * scale), y: y)?.usingColorSpace(.sRGB)),
                    try XCTUnwrap(rep.colorAt(x: Int(50 * scale), y: y)?.usingColorSpace(.sRGB)))
        }

        let shown = try pixels()
        XCTAssertGreaterThan(shown.rail.blueComponent - shown.rail.greenComponent, 0.3,
                             "the rail is indigo: \(shown.rail)")
        XCTAssertNotEqual(shown.rail, shown.beside, "and only at the edge")

        row.showsMarkings = false
        let hidden = try pixels()
        XCTAssertEqual(hidden.rail.blueComponent, hidden.beside.blueComponent, accuracy: 0.02,
                       "with the markings off the row is a plain row")
    }

    // MARK: - The legend

    /// One line per mark the panel draws, in the channels' order, the panel's
    /// verdicts in theirs.
    func testTheLegendListsThePanelsMarksInChannelOrder() {
        let legend = ToolRowMarksLegend(
            panel: "test",
            marks: [.compressed, .error, .decompressed],
            verdicts: [.init(symbol: "checkmark.seal.fill", tint: .systemGreen, meaning: "Newest")]
        )
        XCTAssertEqual(legend.listedMeanings, [
            ToolRowMark.decompressed.meaning,
            "Newest",
            ToolRowMark.error.meaning,
            ToolRowMark.compressed.meaning
        ])
    }

    func testTheLegendStartsShutAndRemembersBeingOpened() {
        let first = ToolRowMarksLegend(panel: "test", marks: [.error])
        XCTAssertFalse(first.isExpanded)
        first.setExpanded(true)

        XCTAssertTrue(ToolRowMarksLegend(panel: "test", marks: [.error]).isExpanded)
        XCTAssertFalse(ToolRowMarksLegend(panel: "other", marks: [.error]).isExpanded,
                       "remembered per panel")
    }

    /// Shut or open, nothing inside the legend is left without a size or a place
    /// the layout engine can solve — the host panel's own test fails on any.
    func testTheLegendLaysOutWithoutAmbiguityShutOrOpen() {
        func ambiguous(_ view: NSView) -> [String] {
            (view.hasAmbiguousLayout ? ["\(type(of: view))"] : []) + view.subviews.flatMap(ambiguous)
        }
        let legend = ToolRowMarksLegend(panel: "test", marks: ToolRowMark.allCases)
        // In a window: outside one, the lines that came back ambiguous in the
        // UEFI panel did not (measured).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        window.contentView = host
        host.addSubview(legend)
        NSLayoutConstraint.activate([
            legend.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            legend.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        for expanded in [false, true, false] {
            legend.setExpanded(expanded)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(ambiguous(host), [], expanded ? "open" : "shut")
        }
    }

    /// Room above the header, below the strip, and between the header and the
    /// list — shut, the header and its margins alone.
    func testTheLegendLeavesRoomAroundAndBetweenHeaderAndList() throws {
        let legend = ToolRowMarksLegend(panel: "test", marks: [.decompressed, .error])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        window.contentView = host
        host.addSubview(legend)
        NSLayoutConstraint.activate([
            legend.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            legend.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        func frames() throws -> (legend: NSRect, header: NSRect, lines: [NSRect]) {
            host.layoutSubtreeIfNeeded()
            let stack = try XCTUnwrap(legend.subviews.first as? NSStackView)
            let header = try XCTUnwrap(stack.arrangedSubviews.first)
            let list = try XCTUnwrap(stack.arrangedSubviews.last as? NSStackView)
            return (legend.frame,
                    header.convert(header.bounds, to: legend),
                    list.isHidden ? [] : list.arrangedSubviews.map { $0.convert($0.bounds, to: legend) })
        }

        legend.setExpanded(false)
        let shut = try frames()
        XCTAssertEqual(shut.header.minY, ToolRowMarksLegend.margin, accuracy: 0.5, "below the header")
        XCTAssertEqual(shut.legend.height - shut.header.maxY, ToolRowMarksLegend.margin, accuracy: 0.5,
                       "above the header")

        legend.setExpanded(true)
        let open = try frames()
        let first = try XCTUnwrap(open.lines.first)
        let last = try XCTUnwrap(open.lines.last)
        // Unflipped: the header is on top, the last line at the bottom.
        XCTAssertEqual(open.legend.height - open.header.maxY, ToolRowMarksLegend.margin, accuracy: 0.5)
        XCTAssertEqual(open.header.minY - first.maxY, ToolRowMarksLegend.bodyGap, accuracy: 0.5,
                       "between the header and the list")
        XCTAssertEqual(last.minY, ToolRowMarksLegend.margin, accuracy: 0.5, "below the last line")
    }

    func testTheShowMarkingsSwitchIsRememberedAndReported() {
        let legend = ToolRowMarksLegend(panel: "test", marks: [.decompressed])
        XCTAssertTrue(legend.showsMarkings, "on until turned off")
        var reported: [Bool] = []
        legend.onShowMarkingsChanged = { reported.append($0) }

        legend.setShowsMarkings(false)
        XCTAssertEqual(reported, [false])
        XCTAssertFalse(ToolRowMarksLegend(panel: "test", marks: [.decompressed]).showsMarkings)
    }
}
