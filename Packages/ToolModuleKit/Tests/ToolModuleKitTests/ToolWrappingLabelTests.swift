import AppKit
import XCTest
@testable import ToolModuleKit

/// `ToolWrappingLabel` — the one thing it does beyond drawing a value: keeping
/// the value's drawing when the value is clicked.
///
/// A selectable field keeps two drawings of one value, the cell's font and
/// colour and the string's own attributes, and the field editor — which AppKit
/// puts over the text on a click — draws the cell's pair. A value drawn only in
/// the string (a verdict in its tone with the evidence in brackets beside it in
/// the ordinary one, a configuration cell whose two copies differ) went plain
/// the moment it was clicked. Adopting the string's first attributes into the
/// cell is what keeps the two drawings one; measured on a window with a real
/// editor, which is why this asserts the cell and not the drawing.
@MainActor
final class ToolWrappingLabelTests: XCTestCase {

    private func label(_ attributed: NSAttributedString?) -> ToolWrappingLabel {
        let label = ToolWrappingLabel(string: "value")
        label.font = ToolPanelFont.body()
        label.textColor = .labelColor
        if let attributed { label.attributedStringValue = attributed }
        return label
    }

    /// The status the click has to survive: bold and green, and the tick a
    /// passed check carries ahead of the text.
    func testTheStringsOwnFontAndColourAreAdopted() {
        let label = label(ToolValueTone.good.attributedValue("Configured"))
        XCTAssertEqual(label.font?.fontDescriptor.symbolicTraits.contains(.bold), true,
                       "the tone's weight is the cell's as well as the string's")
        XCTAssertEqual(label.textColor, ToolValueTone.good.color)
        // The idle drawing is still the string's own, tick and all.
        XCTAssertTrue(label.attributedStringValue.string.contains("Configured"))
    }

    /// A two-colour string — a verdict in its tone, the evidence in the ordinary
    /// colour — gives the cell the *first* pair: the cell carries one font and
    /// one colour, and the half that carries the answer is the one to edit in.
    func testATwoColourStringGivesTheCellItsFirstPair() {
        let drawn = NSMutableAttributedString(
            attributedString: ToolValueTone.caution.attributedValue("Will close on the EOM flag"))
        drawn.append(ToolValueTone.standard.attributedValue(" (EOM: on, descriptor: locked)"))
        let label = label(drawn)
        XCTAssertEqual(label.textColor, ToolValueTone.caution.color)
        XCTAssertEqual(label.font?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertEqual(label.attributedStringValue.length, drawn.length,
                       "and the string it draws is untouched")
    }

    /// An ordinary value stays ordinary, in the string and in the cell.
    func testAnOrdinaryValueKeepsTheCellAsItWas() {
        let label = label(ToolValueTone.standard.attributedValue("15.0.30.1716"))
        XCTAssertEqual(label.textColor, ToolValueTone.standard.color)
        XCTAssertEqual(label.font?.fontDescriptor.symbolicTraits.contains(.bold), false)
    }

    /// An empty string has no attributes to take, and a view that asked for one
    /// keeps the font it set rather than losing it.
    func testAnEmptyStringLeavesTheCellAlone() {
        let label = label(NSAttributedString(string: ""))
        XCTAssertEqual(label.font, ToolPanelFont.body())
        XCTAssertEqual(label.textColor, .labelColor)
    }
}
