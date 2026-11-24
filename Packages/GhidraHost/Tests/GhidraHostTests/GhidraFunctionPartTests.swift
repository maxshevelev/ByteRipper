import AgentKit
import XCTest
@testable import GhidraHost

/// Issue e52b0972: a large function reads within the answer bound in parts.
final class GhidraFunctionPartTests: XCTestCase {
    private let function: JSONValue = .object([
        "name": "Big", "c": .string((1...10).map { "line \($0)" }.joined(separator: "\n")),
        "locals": .array([.string("uVar1")]), "leftovers": .array([.string("uVar1")])
    ])

    func testLinesOfTheCComeWithWhereTheNextPageStarts() {
        guard case .object(let body) = GhidraTools.functionPart(function, cFrom: 4, cLimit: 3, omit: []) else { return XCTFail() }
        XCTAssertEqual(body["c"], .string("line 4\nline 5\nline 6"))
        XCTAssertEqual(body["c_lines"], .object(["from": .int(4), "count": .int(3), "total": .int(10), "next": .int(7)]))
        guard case .object(let last) = GhidraTools.functionPart(function, cFrom: 9, cLimit: 5, omit: []) else { return XCTFail() }
        XCTAssertEqual(last["c"], .string("line 9\nline 10"))
        guard case .object(let lines)? = last["c_lines"] else { return XCTFail() }
        XCTAssertEqual(lines["next"], .null)
    }

    func testOmittedListsAreLeftOutAndTheRestStays() {
        guard case .object(let body) = GhidraTools.functionPart(function, cFrom: nil, cLimit: nil,
                                                                omit: ["locals", "leftovers"]) else { return XCTFail() }
        XCTAssertNil(body["locals"]); XCTAssertNil(body["leftovers"])
        XCTAssertEqual(body["name"], "Big"); XCTAssertNil(body["c_lines"])
    }

    func testTheToolTakesTheNewArguments() throws {
        XCTAssertTrue(GhidraTools.functionOmittable.contains("locals"))
    }
}
