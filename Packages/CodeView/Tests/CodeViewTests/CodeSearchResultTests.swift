@testable import CodeView
import Find
import XCTest

/// The Search tab's words without a window.
final class CodeSearchResultTests: XCTestCase {
    func testAMatchFarIntoALineIsBroughtForwardFromAWordsStart() {
        let line = String(repeating: "alpha ", count: 12) + "Target rest"
        let start = (line as NSString).range(of: "Target").location
        let hit = TextSearchHit(range: 0..<6, line: 0, lineText: line, rangeInLine: start..<(start + 6))
        let shown = CodeSearchResult.shownLine(of: hit)
        XCTAssertTrue(shown.text.hasPrefix("…alpha"), shown.text)
        XCTAssertEqual((shown.text as NSString).substring(with: NSRange(shown.match)), "Target")
    }

    func testANearMatchAndATabStayAsTheyAre() {
        let hit = TextSearchHit(range: 0..<3, line: 0, lineText: "•\tone two", rangeInLine: 2..<5)
        let shown = CodeSearchResult.shownLine(of: hit)
        XCTAssertEqual(shown.text, "• one two")
        XCTAssertEqual(shown.match, 2..<5)
    }
}
