import XCTest
@testable import UEFITool

/// How two values of one variable are said to differ: half-open runs of
/// offsets into the value, the tail only the longer one has among them.
final class UEFIAgentVariablesTests: XCTestCase {
    func testRunsOfDifferingBytes() {
        XCTAssertEqual(UEFIAgentVariables.differingRuns([1, 2, 3, 4], [1, 9, 9, 4]), [1..<3])
        XCTAssertEqual(UEFIAgentVariables.differingRuns([1, 2, 3, 4], [0, 2, 3, 0]), [0..<1, 3..<4])
        XCTAssertEqual(UEFIAgentVariables.differingRuns([1, 2], [1, 2]), [])
    }

    func testTheLongerValuesTailIsARun() {
        XCTAssertEqual(UEFIAgentVariables.differingRuns([1, 2], [1, 2, 3]), [2..<3])
        XCTAssertEqual(UEFIAgentVariables.differingRuns([1, 1], [1, 2, 3]), [1..<3], "joined to the run before it")
        XCTAssertEqual(UEFIAgentVariables.differingRuns([], [7]), [0..<1])
    }
}
