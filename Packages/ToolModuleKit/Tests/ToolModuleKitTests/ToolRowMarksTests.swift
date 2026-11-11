import AppKit
import CodeAnalysis
import Localization
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
        // Clear the domain so the next test (and a re-run) starts empty. The
        // suite's *file* is not deleted here: a `swift test` run is not
        // sandboxed, so `cfprefsd` persists it into the developer's own
        // `~/Library/Preferences/` and re-flushes the file the instant this
        // process exits, after this runs — a deletion here cannot stick
        // (measured with the full `CFPreferences` removal API). `Scripts/run-
        // tests.sh` deletes the leftover after the run, from a process that is
        // no longer a `cfprefsd` client.
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

    /// A row's tooltip shows over the row and not over a panel lying on it:
    /// AppKit would show it there too, so the row asks the hit test first.
    func testARowCoveredByAPanelSaysNothing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = content
        let cell = try XCTUnwrap(ToolPanelTable.makeCell(identifier: .init("name")) as? ToolPanelCellView)
        cell.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        content.addSubview(cell)
        ToolPanelTable.dress(cell, with: ToolRowMarks(decompressedFrom: "Decompressed from LZMA at 0x60"))
        let point = NSPoint(x: 150, y: 10)
        XCTAssertEqual(cell.shownToolTip(at: point), "Decompressed from LZMA at 0x60")

        let panel = NSView(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        content.addSubview(panel)
        XCTAssertEqual(cell.shownToolTip(at: point), "", "under the panel")
        XCTAssertEqual(cell.shownToolTip(at: NSPoint(x: 50, y: 10)), "Decompressed from LZMA at 0x60",
                       "beside it")
    }

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

    /// The code badge is a role mark, but it stands after the name: it says a
    /// stored analysis exists for the module the name denotes.
    func testTheCodeBadgeStandsAfterTheName() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("name"),
                                           warning: true, badges: true)
        cell.textField?.stringValue = "CpuPei"
        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysis(.complete)]))

        let leading = ToolPanelTable.badgeTags.compactMap {
            cell.viewWithTag($0) as? NSImageView
        }
        XCTAssertEqual(leading.map(\.isHidden), [true, true],
                       "the code badge does not take a leading slot")
        let code = try XCTUnwrap(
            cell.viewWithTag(ToolPanelTable.codeBadgeTag) as? NSImageView)
        XCTAssertFalse(code.isHidden)
        XCTAssertEqual(code.toolTip, ToolRowMarks.Role.codeAnalysis(.complete).toolTip)
        XCTAssertEqual(code.contentTintColor, ToolRowMark.codeAnalysis.tint, "the reviewed function's colour")
        XCTAssertEqual(code.image?.accessibilityDescription, ToolRowMarks.Role.codeAnalysis(.complete).toolTip)
        // A circle four fifths of the text's size, and the view as large as that picture.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        window.contentView?.addSubview(cell)
        cell.layoutSubtreeIfNeeded()
        let picture = try XCTUnwrap(code.image?.size)
        // Constraints place the alignment rect; a symbol image view pads its frame around it.
        XCTAssertEqual(code.alignmentRect(forFrame: code.frame).size, picture)
        XCTAssertLessThan(picture.height, ToolPanelFont.size, "smaller than the name beside it")

        let stack = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSStackView }.first)
        let field = try XCTUnwrap(cell.textField)
        let fieldIndex = try XCTUnwrap(stack.arrangedSubviews.firstIndex(of: field))
        let codeIndex = try XCTUnwrap(stack.arrangedSubviews.firstIndex(of: code))
        XCTAssertEqual(codeIndex, fieldIndex + 1, "directly after the name")

        ToolPanelTable.dress(cell, with: .none)
        XCTAssertTrue(code.isHidden)
        XCTAssertNil(code.toolTip)
    }

    /// The origin stands after the code badge: a framed word, dashed when the
    /// review only inferred it, none for `unknown`, and gone with the marks.
    func testTheOriginIsAFramedWordAfterTheCodeBadge() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("name"), warning: true, badges: true)
        cell.textField?.stringValue = "CapsulePei"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        window.contentView?.addSubview(cell)
        let established = ModuleOrigin(category: .edk2Modified, confidence: .established, vendor: "Insyde")
        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysis(.complete)], origin: established))
        cell.layoutSubtreeIfNeeded()
        let badge = try XCTUnwrap(cell.viewWithTag(ToolPanelTable.codeOriginTag) as? ToolPanelOriginBadge)
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual(badge.word, "EDK2*")
        XCTAssertFalse(badge.isDashed)
        XCTAssertEqual(badge.toolTip, established.badgeToolTip)
        XCTAssertTrue(established.badgeToolTip.contains("Insyde"))
        let stack = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSStackView }.first)
        let code = try XCTUnwrap(cell.viewWithTag(ToolPanelTable.codeBadgeTag))
        XCTAssertEqual(stack.arrangedSubviews.firstIndex(of: badge), stack.arrangedSubviews.firstIndex(of: code).map { $0 + 1 })
        XCTAssertGreaterThan(badge.frame.width, 0)
        XCTAssertLessThanOrEqual(badge.frame.height, cell.frame.height)
        Self.snapshot(cell, "origin-established")

        let inferred = ModuleOrigin(category: .vendor, confidence: .inferred, vendor: "Lenovo")
        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysis(.partial)], origin: inferred))
        XCTAssertEqual(badge.word, "Lenovo")
        XCTAssertTrue(badge.isDashed)
        cell.layoutSubtreeIfNeeded()
        Self.snapshot(cell, "origin-inferred")

        // On a selected row it takes the selection's text colour, as the glyphs do.
        cell.backgroundStyle = .emphasized
        XCTAssertTrue(badge.isEmphasized)
        Self.snapshot(Self.selected(cell), "origin-selected")
        cell.backgroundStyle = .normal
        XCTAssertFalse(badge.isEmphasized)

        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysis(.partial)],
                                                      origin: ModuleOrigin(category: .unknown, confidence: nil)))
        XCTAssertTrue(badge.isHidden, "unknown draws nothing")
        ToolPanelTable.dress(cell, with: .none)
        XCTAssertTrue(badge.isHidden)
        XCTAssertNil(badge.toolTip)
    }

    func testEachCategoryHasItsWord() {
        XCTAssertEqual(ModuleOrigin.Category.allCases.map {
            ModuleOrigin(category: $0, confidence: .established).badgeWord
        }, ["EDK2", "EDK2*", "AMD", "Intel", "Vendor", nil])
    }

    /// The cell on the accent colour, as a selected row draws it.
    private static func selected(_ cell: NSView) -> NSView {
        let row = NSView(frame: cell.bounds)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        cell.removeFromSuperview()
        row.addSubview(cell)
        cell.frame = row.bounds
        row.layoutSubtreeIfNeeded()
        return row
    }

    /// Where `BR_SNAPSHOT_DIR` names a folder, a picture of the cell for a
    /// person to look at; nothing otherwise.
    private static func snapshot(_ view: NSView, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["BR_SNAPSHOT_DIR"],
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    /// A shut file holding an analyzed module wears the same badge in the same
    /// place, and says the analysis is further in.
    func testTheBadgeOnAShutFileSaysTheCodeIsInside() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("name"),
                                           warning: true, badges: true)
        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysisInside(.partial)]))

        let leading = ToolPanelTable.badgeTags.compactMap {
            cell.viewWithTag($0) as? NSImageView
        }
        XCTAssertEqual(leading.map(\.isHidden), [true, true])
        let code = try XCTUnwrap(
            cell.viewWithTag(ToolPanelTable.codeBadgeTag) as? NSImageView)
        XCTAssertFalse(code.isHidden)
        XCTAssertNotEqual(code.toolTip, ToolRowMarks.Role.codeAnalysis(.partial).toolTip)
        XCTAssertEqual(code.toolTip, ToolRowMarks.Role.codeAnalysisInside(.partial).toolTip)
    }

    /// A module's own file wears the same circle, open or shut, and its words
    /// say the module is this file, not something further in.
    func testTheBadgeOnAModuleFileSaysItIsTheModule() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("name"),
                                           warning: true, badges: true)
        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysisModule(.complete)]))
        let code = try XCTUnwrap(
            cell.viewWithTag(ToolPanelTable.codeBadgeTag) as? NSImageView)
        XCTAssertFalse(code.isHidden)
        XCTAssertEqual(code.toolTip, ToolRowMarks.Role.codeAnalysisModule(.complete).toolTip)
        for readiness in [ToolRowMarks.CodeReadiness.mechanical, .partial, .complete] {
            XCTAssertNotEqual(ToolRowMarks.Role.codeAnalysisModule(readiness).toolTip,
                              ToolRowMarks.Role.codeAnalysisInside(readiness).toolTip)
            XCTAssertEqual(ToolRowMarks.Role.codeAnalysisModule(readiness).mark, .codeAnalysis)
        }
    }

    /// A described module's row wears the (i) after the origin; it asks the
    /// responder chain, and inverts with the row's selection.
    func testTheInfoButtonComesAfterTheOriginAndAsksTheResponderChain() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("name"), warning: true, badges: true)
        let info = try XCTUnwrap(cell.viewWithTag(ToolPanelTable.codeInfoTag) as? ToolPanelModuleInfoButton)
        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysisModule(.complete)]))
        XCTAssertTrue(info.isHidden)
        ToolPanelTable.dress(cell, with: ToolRowMarks(roles: [.codeAnalysisModule(.complete)],
                                                      origin: ModuleOrigin(category: .edk2, confidence: .established),
                                                      moduleInfo: true))
        XCTAssertFalse(info.isHidden)
        XCTAssertNil(info.target)
        XCTAssertEqual(info.action, #selector(ToolPanelModuleInfoResponder.showModuleInfo(_:)))
        XCTAssertEqual(info.accessibilityLabel(), L("Module summary"))

        let row = try XCTUnwrap(info.superview as? NSStackView)
        let origin = try XCTUnwrap(cell.viewWithTag(ToolPanelTable.codeOriginTag))
        let views = row.arrangedSubviews
        XCTAssertEqual(views.firstIndex(of: info), try XCTUnwrap(views.firstIndex(of: origin)) + 1)

        cell.backgroundStyle = .emphasized
        XCTAssertEqual(info.contentTintColor, .alternateSelectedControlTextColor)
        cell.backgroundStyle = .normal
        XCTAssertEqual(info.contentTintColor, .secondaryLabelColor)
    }

    /// The popover says the module's name and summary, and its button opens
    /// the code it was given.
    func testTheSummaryPopoverOpensTheCodeItWasGiven() throws {
        var opened = 0
        let popover = ToolPanelModuleSummaryPopover(name: "PeiVariable", summary: "Reads variables.") { opened += 1 }
        popover.loadView()
        let fields = popover.view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertEqual(fields, ["PeiVariable", "Reads variables."])
        let button = try XCTUnwrap(popover.view.subviews.compactMap { $0 as? NSButton }
            .first { $0.title == L("Open with Code") })
        button.performClick(nil)
        XCTAssertEqual(opened, 1)
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

    /// A panel's verdicts are marks of the catalogue too: listed in their
    /// channel's place, drawn in the symbol and tint the cells use.
    func testVerdictsAreMarksOfTheCatalogue() {
        let legend = ToolRowMarksLegend(panel: "test", marks: [.error, .newerListed, .newest])
        XCTAssertEqual(legend.listedMeanings, [
            ToolRowMark.newerListed.meaning, ToolRowMark.newest.meaning, ToolRowMark.error.meaning
        ])
        XCTAssertEqual(ToolRowMark.newerListed.symbol, "arrow.down.circle")
        let problemSymbols = [ToolRowMark.error, .caution].compactMap(\.symbol)
        for verdict in ToolRowMark.allCases where verdict.channel == .verdict {
            XCTAssertFalse(problemSymbols.contains(verdict.symbol ?? ""),
                           "a verdict never takes a problem's shape")
        }
    }

    /// The Show Markings switch is offered only where there is paint to hide.
    func testTheSwitchIsOfferedOnlyToAPanelThatPaints() {
        XCTAssertFalse(ToolRowMarksLegend(panel: "test", marks: [.newest, .error]).offersShowMarkings)
        let legend = ToolRowMarksLegend(panel: "test", marks: [.error, .decompressed])
        XCTAssertTrue(legend.offersShowMarkings)
        legend.setMarks([.error])
        XCTAssertFalse(legend.offersShowMarkings)
    }

    /// The verdict call draws the catalogue's mark, and hides the slot for a
    /// mark that is not a verdict.
    func testTheVerdictCallDrawsTheCataloguesMark() throws {
        let cell = ToolPanelTable.makeCell(identifier: .init("type"), warning: true, marker: true)
        ToolPanelTable.setVerdict(.newest, toolTip: "newest", on: cell)
        let marker = try XCTUnwrap(cell.viewWithTag(ToolPanelTable.markerTag) as? NSImageView)
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(marker.contentTintColor, ToolRowMark.newest.tint)
        XCTAssertEqual(marker.toolTip, "newest")

        ToolPanelTable.setVerdict(.error, on: cell)
        XCTAssertTrue(marker.isHidden)
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
