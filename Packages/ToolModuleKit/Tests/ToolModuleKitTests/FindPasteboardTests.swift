import AppKit
import XCTest
@testable import ToolModuleKit

/// `FindPasteboard`: one search string for the Mac, and each field's own
/// sense of whether the string there is new to it.
@MainActor
final class FindPasteboardTests: XCTestCase {
    private var saved: NSPasteboard!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        saved = FindPasteboard.pasteboard
        pasteboard = NSPasteboard.withUniqueName()
        FindPasteboard.pasteboard = pasteboard
    }

    override func tearDown() {
        FindPasteboard.pasteboard = saved
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    /// A write is the string, and its count is the writer's to keep: its own
    /// string is not news to it.
    func testAWriterHasSeenItsOwnString() {
        var seen = FindPasteboard.write("BIOS")
        XCTAssertEqual(FindPasteboard.string, "BIOS")
        XCTAssertNil(FindPasteboard.take(ifChangedSince: &seen))
    }

    /// Another field's string is news, once.
    func testAnotherFieldsStringIsNewOnce() {
        var mine = FindPasteboard.changeCount
        FindPasteboard.write("EFI")
        XCTAssertEqual(FindPasteboard.take(ifChangedSince: &mine), "EFI")
        XCTAssertNil(FindPasteboard.take(ifChangedSince: &mine), "and then it is not")
    }

    /// Each field keeps its own count: one field taking the string leaves it
    /// new to the rest.
    func testOneFieldTakingItLeavesItNewToAnother() {
        var first = FindPasteboard.changeCount
        var second = first
        FindPasteboard.write("_FVH")
        XCTAssertEqual(FindPasteboard.take(ifChangedSince: &first), "_FVH")
        XCTAssertEqual(FindPasteboard.take(ifChangedSince: &second), "_FVH")
    }

    /// Nothing is written for an empty string or for the one already there —
    /// a search run again is not news to anyone.
    func testTheSameStringOrNoneIsNotWritten() {
        var seen = FindPasteboard.write("$FPT")
        let count = FindPasteboard.changeCount
        XCTAssertEqual(FindPasteboard.write("$FPT"), count)
        XCTAssertEqual(FindPasteboard.write(""), count)
        XCTAssertNil(FindPasteboard.take(ifChangedSince: &seen))
        XCTAssertEqual(FindPasteboard.string, "$FPT")
    }
}
