import XCTest
@testable import ByteRipperCore

final class OffsetExpressionTests: XCTestCase {
    private typealias ParseError = OffsetExpression.ParseError

    /// The case the feature exists for (issue #9): an address in hex and a
    /// length known in decimal, in one expression, neither converted by hand.
    func testHexAddressAndDecimalLength() throws {
        XCTAssertEqual(try OffsetExpression.parse("0x1FE000 + 4096").value, 0x1FF000)
        XCTAssertEqual(try OffsetExpression.parse("0x2C0000 - 1024").value, 0x2BFC00)
        XCTAssertEqual(try OffsetExpression.parse("196608 - 0x200").value, 0x2FE00)
    }

    func testValues() {
        let cases: [(input: String, expected: UInt64)] = [
            // One number is an expression of one term, read as the field
            // always read it.
            ("0", 0),
            ("4096", 4096),
            ("0x10", 16),
            ("FF", 255),
            ("  0x1F  ", 31),
            // Each term by the same rule: `beef` is hex, `10` is decimal.
            ("beef + 10", 0xbeef + 10),
            ("10 + 10", 20),
            ("0x10 + 0X10", 32),
            // Left to right, any number of terms, spacing free.
            ("0x100-0x10+1", 0xF1),
            ("\t1 +\t2  -  3 ", 0),
            ("1+2+3+4", 10),
            // Below zero on the way is not below zero at the end.
            ("0x100 - 0x200 + 0x200", 0x100),
            // Past 64 bits on the way is not past 64 bits at the end.
            ("0xFFFFFFFFFFFFFFFF + 1 - 1", UInt64.max),
            ("0xFFFFFFFFFFFFFFFF + 0xFFFFFFFFFFFFFFFF - 0xFFFFFFFFFFFFFFFF", UInt64.max),
            ("5 - 5", 0),
        ]
        for testCase in cases {
            XCTAssertEqual(try? OffsetExpression.parse(testCase.input).value, testCase.expected,
                           "\"\(testCase.input)\"")
        }
    }

    func testErrors() {
        let cases: [(input: String, expected: ParseError)] = [
            // Nothing typed, or only the prefix the field opens with.
            ("", .invalidInput),
            ("   ", .invalidInput),
            ("0x", .invalidInput),
            ("0X", .invalidInput),
            // Still being typed: wait for the rest.
            ("0x1FE000 +", .incomplete),
            ("0x1FE000 -  ", .incomplete),
            ("0x1FE000 + 0x", .incomplete),
            ("0x1FE000 + 0X", .incomplete),
            // A sign in front is kept free, not guessed at.
            ("+5", .invalidInput),
            ("-1", .invalidInput),
            ("+", .invalidInput),
            ("-", .invalidInput),
            // Two operators in a row, in the middle or at the end.
            ("1 + + 2", .invalidInput),
            ("1 - - 2", .invalidInput),
            ("1 + -", .invalidInput),
            // A prefix with no digits is unfinished only where the typing is.
            ("0x + 1", .invalidInput),
            // Not numbers.
            ("1 + G", .invalidInput),
            ("1 * 2", .invalidInput),
            ("(1 + 2)", .invalidInput),
            ("1.5 + 1", .invalidInput),
            ("0x1F E0 + 1", .invalidInput),
            // The sum itself.
            ("1 - 2", .negative),
            ("0x100 - 0x200 + 0xFF", .negative),
            ("0xFFFFFFFFFFFFFFFF + 1", .outOfRange),
            ("0x10000000000000000 + 1", .outOfRange),
            ("1 + 99999999999999999999", .outOfRange),
        ]
        for testCase in cases {
            XCTAssertThrowsError(try OffsetExpression.parse(testCase.input), "\"\(testCase.input)\"") { error in
                XCTAssertEqual(error as? ParseError, testCase.expected, "\"\(testCase.input)\"")
            }
        }
    }

    /// The sum as it was read, every term in hex: how a `40` that was meant as
    /// `0x40` shows before the result is used.
    func testHexText() throws {
        let sum = try OffsetExpression.parse("0x1fe000+40")
        XCTAssertEqual(sum.hexText, "0x1FE000 + 0x28")
        XCTAssertEqual(sum.hexValue, "0x1FE028")
        XCTAssertTrue(sum.isSum)
        XCTAssertEqual(sum.terms, [.init(isSubtracted: false, value: 0x1FE000),
                                   .init(isSubtracted: false, value: 40)])

        XCTAssertEqual(try OffsetExpression.parse("beef - 10 + 0x1").hexText, "0xBEEF - 0xA + 0x1")

        let number = try OffsetExpression.parse("4096")
        XCTAssertFalse(number.isSum)
        XCTAssertEqual(number.hexText, "0x1000")
        XCTAssertEqual(number.hexValue, "0x1000")
    }
}
