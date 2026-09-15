import AppKit
import XCTest
@testable import ToolModuleKit

/// A legend installed under a list in a split's pane, where the pane is laid
/// out at nothing first — the tool panel opening from zero — and at its real
/// size after.
@MainActor
final class ToolRowMarksLegendPaneTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? [] + buttons(in: subview)
        }
    }

    /// The header comes back on one line: squeezed while the pane was zero
    /// wide, a title that wrapped stays one letter a line once it has grown.
    func testALegendLaidOutAtZeroFirstKeepsItsHeaderOnOneLine() throws {
        let pane = NSView(frame: .zero)
        let legend = ToolRowMarksLegend(panel: "test", marks: [.error, .caution, .protectedIBB])
        legend.install(below: NSScrollView(), in: pane)
        pane.layoutSubtreeIfNeeded()

        pane.setFrameSize(NSSize(width: 420, height: 400))
        pane.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(buttons(in: legend).first { $0.attributedTitle.string == "Legend" })
        XCTAssertEqual((title.cell as? NSButtonCell)?.wraps, false, "a title cut short, never wrapped")
        XCTAssertGreaterThanOrEqual(title.frame.width, title.intrinsicContentSize.width - 0.5,
                                    "the title has its whole width back")
        XCTAssertLessThan(title.frame.height, 30, "one line, not a column of letters: \(title.frame)")

        let showMarkings = try XCTUnwrap(buttons(in: legend).first { $0.title == "Show markings" })
        XCTAssertEqual((showMarkings.cell as? NSButtonCell)?.wraps, false)
        XCTAssertLessThan(showMarkings.frame.height, 30, "\(showMarkings.frame)")

        XCTAssertEqual(legend.frame.width, 420, accuracy: 0.5, "as wide as the pane")
        XCTAssertEqual(legend.frame.minY, 0, accuracy: 0.5, "against the pane's bottom")
    }
}
