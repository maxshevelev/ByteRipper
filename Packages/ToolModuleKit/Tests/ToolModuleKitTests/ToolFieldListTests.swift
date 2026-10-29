import AppKit
import XCTest
@testable import ToolModuleKit

/// A detail's name/value rows: a view per row, a name too long for its column
/// wrapped onto a further line, and the text selected across the rows.
@MainActor
final class ToolFieldListTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: ToolPanelFont.body()])
    }

    /// A list `width` wide, laid out in the window.
    private func list(_ fields: [(String, NSAttributedString)], width: CGFloat = 360,
                      nameWidth: CGFloat = 80) -> ToolFieldList {
        let list = ToolFieldList(fields: fields.map { .init(label: $0.0, value: $0.1) },
                                 nameWidth: nameWidth)
        let root = window.contentView!
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: width),
        ])
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return list
    }

    /// A list whose first row carries help, laid out the same way.
    private func helpList(_ fields: [(String, NSAttributedString, FieldHelp?)],
                          width: CGFloat = 360, nameWidth: CGFloat = 80) -> ToolFieldList {
        let list = ToolFieldList(
            fields: fields.map { .init(label: $0.0, value: $0.1, help: $0.2) },
            nameWidth: nameWidth)
        let root = window.contentView!
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: width),
        ])
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return list
    }

    /// The `?` a row carries where the tool it came from has something to say
    /// about it, and no button at all where it has nothing: a control that
    /// opens an empty popover is worse than no control.
    func testOnlyARowWithHelpCarriesAButton() {
        let help = FieldHelp(identifier: "MELanPowerWell", text: "LAN Power Well.",
                             buttonName: "Setting help", buttonTooltip: "What the tool says")
        let list = helpList([("LAN Power Well", plain("Enabled"), help),
                             ("Auto", plain("No"), nil)])

        XCTAssertNotNil(list.rows[0].helpButton)
        XCTAssertNil(list.rows[1].helpButton)
        XCTAssertEqual(list.rows[0].fieldHelp, help)
        XCTAssertEqual(list.subviews.count, 2, "the rows, and no button on the list itself")
        XCTAssertEqual(list.rows[0].subviews.count, 1, "the button is the row's own")
        // The button's words are the panel's, carried on the help: the list
        // is shared, and only the panel knows whose words the button opens.
        XCTAssertEqual(list.rows[0].helpButton?.toolTip, "What the tool says")
        XCTAssertEqual(list.rows[0].helpButton?.accessibilityLabel(), "Setting help")
    }

    /// The button follows the name, right after its last word, and the name is
    /// drawn in what the column has less the button's room.
    func testTheButtonFollowsTheName() throws {
        let help = FieldHelp(identifier: "MELanPowerWell", text: "LAN Power Well.",
                             buttonName: "Setting help", buttonTooltip: "What the tool says")
        let name = "LAN Power Well"
        let list = helpList([(name, plain("Enabled"), help)], nameWidth: 300)
        let row = list.rows[0]
        let button = try XCTUnwrap(row.helpButton)
        let nameWidth = ToolFieldList.nameWidth(for: [name], atLeast: 0)

        XCTAssertGreaterThan(row.nameColumnWidth, ToolFieldList.helpButtonReserve)
        XCTAssertEqual(button.frame.minX, nameWidth + ToolFieldRow.helpButtonGap, accuracy: 1,
                       "the button sits right after the name")
        XCTAssertLessThan(button.frame.maxX, row.nameColumnWidth - 20,
                          "not at the far end of a wide column")
        XCTAssertEqual(row.nameLayoutWidth, row.nameColumnWidth - ToolFieldList.helpButtonReserve,
                       accuracy: 0.5, "and the name is laid out in what the button leaves")

        // A name that wraps puts the button after its last line, inside the column.
        let long = "LAN Power Well and then some more of it"
        let wrapped = helpList([(long, plain("Enabled"), help)], nameWidth: 90).rows[0]
        let wrappedButton = try XCTUnwrap(wrapped.helpButton)
        XCTAssertGreaterThan(wrappedButton.frame.minY, 5, "on the name's last line")
        XCTAssertLessThanOrEqual(wrappedButton.frame.maxX, wrapped.nameColumnWidth + 0.5)
        // A column measured for rows with buttons keeps their width back.
        XCTAssertEqual(ToolFieldList.nameWidth(for: [name], reservingHelp: true),
                       ToolFieldList.nameWidth(for: [name]) + ToolFieldList.helpButtonReserve)
        XCTAssertEqual(ToolFieldList.nameWidth(for: [name], reservingHelp: false),
                       ToolFieldList.nameWidth(for: [name]))
    }

    /// The pointer over the `?` is an arrow, not the text's I-beam.
    func testTheButtonIsNotUnderTheIBeam() throws {
        let help = FieldHelp(identifier: "MELanPowerWell", text: "LAN Power Well.",
                             buttonName: "Setting help")
        let row = helpList([("LAN Power Well", plain("Enabled"), help)], nameWidth: 300).rows[0]
        let button = try XCTUnwrap(row.helpButton)

        let rects = row.iBeamRects
        XCTAssertFalse(rects.isEmpty)
        XCTAssertFalse(rects.contains { $0.intersects(button.frame) },
                       "no I-beam over the button")
        XCTAssertTrue(rects.contains { $0.contains(NSPoint(x: 2, y: button.frame.midY)) },
                      "the name keeps it")
        XCTAssertTrue(button is ToolInfoButton, "and the button sets its own arrow")
    }

    /// Pressing the button hands the panel the words and the button to hang a
    /// popover off.
    func testPressingTheButtonAsksThePanelForTheHelp() throws {
        let help = FieldHelp(identifier: "MELanPowerWell", text: "LAN Power Well.",
                             buttonName: "Setting help", buttonTooltip: "What the tool says")
        let list = helpList([("LAN Power Well", plain("Enabled"), help)])
        var asked: [(FieldHelp, NSView)] = []
        list.onHelp = { asked.append(($0, $1)) }

        let button = try XCTUnwrap(list.rows[0].helpButton)
        button.performClick(nil)

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, help)
        XCTAssertTrue(asked.first?.1 === button, "the popover hangs off the button that was pressed")
    }

    func testAViewPerRowAndNothingElse() {
        let list = list([("Kind", plain("File")), ("Size", plain("0x10")), ("GUID", plain("8C8CE578"))])
        XCTAssertEqual(list.subviews.count, 3)
        XCTAssertEqual(list.rows.map(\.texts), [["Kind", "File"], ["Size", "0x10"], ["GUID", "8C8CE578"]])
        XCTAssertEqual(list.rows[1].frame.minY, list.rows[0].frame.maxY, "the rows follow one another")
        XCTAssertEqual(list.frame.height, list.rows.last!.frame.maxY, "and the list is as tall as they are")
    }

    /// A name longer than its column goes on onto a further line rather than
    /// being cut short, and the row is as tall as the two lines.
    func testANameTooLongForItsColumnWraps() {
        let list = list([("Kind", plain("File")),
                         ("Integrity check of the whole volume", plain("Valid"))])
        let one = list.rows[0].frame.height - ToolFieldList.rowSpacing
        let wrapped = list.rows[1].frame.height
        XCTAssertGreaterThan(wrapped, one * 1.5, "the long name takes two lines or more")
    }

    /// A value wraps inside what is left of the width, and a narrower list
    /// gives it more lines.
    func testAValueWrapsInsideTheRestOfTheWidth() {
        let hash = plain(String(repeating: "0123456789ABCDEF ", count: 6))
        let wide = list([("Hash", hash)], width: 1_000)
        let wideHeight = wide.frame.height
        wide.removeFromSuperview()
        let narrow = list([("Hash", hash)], width: 240)
        XCTAssertGreaterThan(narrow.frame.height, wideHeight * 1.5)
        XCTAssertLessThanOrEqual(narrow.rows[0].frame.maxX, 240)
    }

    /// The name column a list of names wants: as wide as its widest name when
    /// that is wider than the shared default, and the default when it is not.
    func testAColumnIsAsWideAsItsWidestName() {
        let long = "checksumsVerificationOfTheWholeRegion"
        XCTAssertEqual(ToolFieldList.nameWidth(for: ["Kind", "Size"]),
                       ToolPanelFont.detailLabelWidth,
                       "short names leave the column at the shared default")

        let wanted = (long as NSString)
            .size(withAttributes: [.font: ToolPanelFont.body()]).width
        let column = ToolFieldList.nameWidth(for: ["Kind", long])
        XCTAssertGreaterThan(column, ToolPanelFont.detailLabelWidth)
        XCTAssertGreaterThanOrEqual(column, wanted, "the longest name is shown whole")

        // And a list built with it draws every row in that one column.
        let drawn = list([("Kind", plain("File")), (long, plain("yes"))],
                         width: 600, nameWidth: column)
        XCTAssertEqual(drawn.rows.map(\.nameColumnWidth), [column, column])
    }

    /// A name that does not fit half the row wraps inside that half rather than
    /// taking more of the row from the value — the cap every panel's rows are
    /// held to, whatever column the panel asked for.
    func testANameThatDoesNotFitHalfTheRowWraps() {
        let long = "systemHeaderCRCValidAndSomethingElseEntirely"
        let drawn = list([(long, plain("yes"))], width: 240, nameWidth: 1_000)
        let row = drawn.rows[0]
        XCTAssertEqual(row.nameColumnWidth, (240 - ToolFieldRow.columnSpacing) / 2,
                       "the column stops at half the row")
        XCTAssertGreaterThan(row.textHeight, ToolPanelFont.body().boundingRectForFont.height,
                             "and the name takes a second line")
    }

    /// A row that compares two copies of one thing: the second value is a
    /// column of its own — the same width as the first, so the two line up down
    /// the list — and the copy of a row carries the three parts, a tab apart.
    func testASecondValueIsAColumnOfItsOwn() {
        let list = threePartList([("EomFirstBootEnabled", "No", "Yes"),
                                  ("FlexibleEomSettings", "Lock Descriptor Only", "Lock Descriptor Only")])
        let row = list.rows[0]
        XCTAssertEqual(row.texts, ["EomFirstBootEnabled", "No", "Yes"])
        XCTAssertEqual(row.valueColumnWidth, list.rows[1].valueColumnWidth,
                       "the two value columns are one width down the list")
        XCTAssertEqual(list.rows[1].valueColumnWidth, (360 - row.nameColumnWidth
                                                       - ToolFieldRow.columnSpacing * 2) / 2,
                       accuracy: 1)

        // A mark in the second value's column is a mark in part 2, and a copy
        // from the value into it takes both.
        let secondX = row.nameColumnWidth + ToolFieldRow.columnSpacing
            + row.valueColumnWidth + ToolFieldRow.columnSpacing
        XCTAssertEqual(row.mark(at: NSPoint(x: secondX + 1, y: 2)).part, 2)
        let from = ToolTextMark(part: 1, index: 1)
        XCTAssertEqual(row.text(in: from..<ToolTextMark(part: 2, index: 1)), "o\tY")

        list.selectAll(nil)
        XCTAssertEqual(list.selectedText,
                       "EomFirstBootEnabled\tNo\tYes\nFlexibleEomSettings\tLock Descriptor Only\tLock Descriptor Only")
    }

    /// A row without a second value is the plain name/value row: the value has
    /// everything the name column leaves, and there is no third part to select.
    func testARowWithoutASecondValueIsUnchanged() {
        let list = list([("Kind", plain("File"))])
        let row = list.rows[0]
        XCTAssertNil(row.secondText)
        XCTAssertNil(row.attributedSecond)
        XCTAssertEqual(row.valueColumnWidth, 0)
        XCTAssertEqual(row.texts, ["Kind", "File"])
        list.selectAll(nil)
        XCTAssertEqual(list.selectedText, "Kind\tFile")
    }

    /// A drag selects across the second value of one row into the name of the
    /// next, as it does across the parts of a plain row.
    func testADragIntoTheSecondValueTakesIt() {
        let list = threePartList([("A", "1", "2"), ("B", "3", "4")])
        let start = list.spot(at: NSPoint(x: 0, y: list.rows[0].frame.midY))
        let row = list.rows[1]
        let to = NSPoint(x: row.frame.maxX - 1, y: row.frame.midY)
        XCTAssertEqual(row.mark(at: to).part, 2, "the point is in the second value's column")
        list.extend(start..<start, to: to)
        XCTAssertEqual(list.selectedText, "A\t1\t2\nB\t3\t4")
        XCTAssertNotNil(list.rows[0].selectedRange)
    }

    /// The list `width` wide, its rows each carrying a second value.
    private func threePartList(_ fields: [(String, String, String)],
                               width: CGFloat = 360, nameWidth: CGFloat = 80) -> ToolFieldList {
        let list = ToolFieldList(
            fields: fields.map { .init(label: $0.0, value: plain($0.1), second: plain($0.2)) },
            nameWidth: nameWidth)
        let root = window.contentView!
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: width),
        ])
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return list
    }

    /// A drag from the first row into the value of the last selects both, the
    /// name and value of a row a tab apart and each row on its line.
    func testADragSelectsAcrossRows() {
        let list = list([("Kind", plain("File")), ("Size", plain("0x10"))])
        let start = list.spot(at: NSPoint(x: 0, y: list.rows[0].frame.midY))
        list.extend(start..<start, to: NSPoint(x: 400, y: list.rows[1].frame.midY))
        XCTAssertEqual(list.selectedText, "Kind\tFile\nSize\t0x10")
        XCTAssertNotNil(list.rows[0].selectedRange)

        // From the value of the first: its name is left out.
        let value = list.spot(at: NSPoint(x: 80 + ToolFieldRow.columnSpacing, y: list.rows[0].frame.midY))
        XCTAssertEqual(value.mark, ToolTextMark(part: 1, index: 0))
        list.extend(value..<value, to: NSPoint(x: 400, y: list.rows[0].frame.midY))
        XCTAssertEqual(list.selectedText, "File")
    }

    /// The tick a passed check carries is drawn, not copied: it is the one
    /// character a reader did not read.
    func testThePassedChecksTickIsNotCopied() {
        let list = list([("Checksum", ToolValueTone.good.attributedValue("Valid"))])
        XCTAssertTrue(list.rows[0].attributedValue.string.contains("\u{FFFC}"), "the tick is drawn")
        XCTAssertEqual(list.rows[0].valueText, "Valid")
        list.selectAll(nil)
        XCTAssertEqual(list.selectedText, "Checksum\tValid")
    }

    /// ⌘C copies while the list has the focus, and the focus leaving takes
    /// the selection with it.
    func testCommandCCopiesAndTheFocusLeavingClears() throws {
        let list = list([("Kind", plain("File"))])
        let other = NSTextField()
        window.contentView!.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(list))
        list.selectAll(nil)

        let copy = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(list.performKeyEquivalent(with: copy))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Kind\tFile")

        window.makeFirstResponder(other)
        XCTAssertNil(list.selection)
        XCTAssertNil(list.rows[0].selectedRange)
        XCTAssertFalse(list.performKeyEquivalent(with: copy), "⌘C is someone else's again")
    }
}
