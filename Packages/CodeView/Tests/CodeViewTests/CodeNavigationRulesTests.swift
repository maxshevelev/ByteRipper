@testable import CodeView
import CodeAnalysis
import XCTest

/// Back and Forward, and the step through a name's occurrences, without a
/// window.
final class CodeNavigationRulesTests: XCTestCase {
    func testAMoveDropsWhatWasAheadAndBackAndForwardWalk() {
        var history = CodeNavigationHistory(places: ["a"])
        XCTAssertTrue(history.move(to: "b"))
        XCTAssertTrue(history.move(to: "c"))
        XCTAssertEqual(history.back(), "b")
        XCTAssertTrue(history.canGoForward)
        XCTAssertTrue(history.move(to: "d"))
        XCTAssertEqual(history.places, ["a", "b", "d"], "what was ahead goes")
        XCTAssertNil(history.forward())
        XCTAssertEqual(history.back(), "b")
        XCTAssertEqual(history.back(), "a")
        XCTAssertNil(history.back(), "nothing before the first")
        XCTAssertFalse(history.move(to: "a") { $0 == $1 }, "the same place is no move")
    }

    func testAStepGoesRoundAndStartsFromTheReader() {
        let positions = [10, 20, 30]
        XCTAssertEqual(CodeSymbolMatch.step(forward: true, current: nil, positions: positions, anchor: 15)?.index, 1)
        XCTAssertEqual(CodeSymbolMatch.step(forward: false, current: nil, positions: positions, anchor: 15)?.index, 0)
        let round = CodeSymbolMatch.step(forward: true, current: 2, positions: positions, anchor: 0)
        XCTAssertEqual(round?.index, 0)
        XCTAssertEqual(round?.wrapped, true)
        let back = CodeSymbolMatch.step(forward: false, current: nil, positions: positions, anchor: 5)
        XCTAssertEqual(back?.index, 2, "before the first: round to the last")
        XCTAssertEqual(back?.wrapped, true)
        XCTAssertNil(CodeSymbolMatch.step(forward: true, current: nil, positions: [], anchor: 0))
    }
}

/// The Stubs group starts closed.
final class CodeStubGroupTests: XCTestCase {
    func testTheStubsGroupStartsClosed() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":11,"functions":[{"entry":"0x10","name":"Isr_Stub","review_level":"stub",
          "instructions":[{"address":"0x10","bytes":"C3","text":"RET"}]}]}
        """.utf8))
        let state = CodeReaderState(model: CodeModel(artifact: artifact, moduleBytes: nil))
        XCTAssertFalse(state.isGroupExpanded(.stub))
        XCTAssertTrue(state.isGroupExpanded(.full))
    }
}
