import XCTest
@testable import AgentKit

final class JSONValueTests: XCTestCase {
    private func parse(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    func testEveryKindReadsBack() throws {
        let value = try parse(#"{"a":null,"b":true,"c":12,"d":1.5,"e":"x","f":[1,"2"],"g":{"h":false}}"#)
        XCTAssertEqual(value, [
            "a": nil, "b": true, "c": 12, "d": 1.5, "e": "x", "f": [1, "2"], "g": ["h": false]
        ])
    }

    /// An address must come back as the integer it was, not as a double that
    /// prints with a fraction.
    func testAnIntegerStaysAnInteger() throws {
        XCTAssertEqual(try parse("2044928"), .int(2_044_928))
        XCTAssertEqual(JSONValue.int(2_044_928).jsonText, "2044928")
        XCTAssertEqual(JSONValue.uint(0xFFFF_FFFF).jsonText, "4294967295")
    }

    func testABooleanIsNotANumber() throws {
        XCTAssertEqual(try parse("true"), .bool(true))
        XCTAssertEqual(try parse("1"), .int(1))
    }

    func testAWholeDoubleReadsAsAnInteger() {
        XCTAssertEqual(JSONValue.double(16).int64Value, 16)
        XCTAssertNil(JSONValue.double(16.5).int64Value)
    }

    func testKeysAreSortedSoTheSameAnswerIsTheSameBytes() {
        let value: JSONValue = ["zeta": 1, "alpha": 2, "mid": ["b": 1, "a": 2]]
        XCTAssertEqual(value.jsonText, #"{"alpha":2,"mid":{"a":2,"b":1},"zeta":1}"#)
    }

    /// One message, one line: a string's own newline must not end the line.
    func testANewlineInAStringIsEscaped() {
        let text = JSONValue.string("two\nlines").jsonText
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(text, #""two\nlines""#)
    }

    func testSlashesAreNotEscaped() {
        XCTAssertEqual(JSONValue.string("Window/Agent").jsonText, #""Window/Agent""#)
    }

    func testANonFiniteDoubleIsWrittenAsNull() {
        XCTAssertEqual(JSONValue.double(.nan).jsonText, "null")
        XCTAssertEqual(JSONValue.array([.double(.infinity)]).jsonText, "[null]")
    }

    func testTextThatIsNotJSONThrows() {
        XCTAssertThrowsError(try parse("{not json"))
        XCTAssertThrowsError(try parse(""))
    }
}
