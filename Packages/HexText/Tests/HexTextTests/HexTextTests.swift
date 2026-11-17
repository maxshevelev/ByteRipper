import HexText
import XCTest

final class HexTextTests: XCTestCase {
    /// Nothing past 32 bits is lost, and nothing is padded.
    func testANumberIsWrittenWhole() {
        XCTAssertEqual(UInt64(0x1_2345_6780).hexNumber, "0x123456780")
        XCTAssertEqual(UInt64(0x1_2345_6780).bareHexNumber, "123456780")
        XCTAssertEqual(UInt64.max.hexNumber, "0xFFFFFFFFFFFFFFFF")
        XCTAssertEqual(UInt64(0).hexNumber, "0x0")
        XCTAssertEqual(UInt64(0x1FE028).hexNumber, "0x1FE028")
    }

    /// Any integer type: an `Int` size, a `UInt32` field.
    func testOtherIntegerTypes() {
        XCTAssertEqual(Int(0x1_0000_0000).hexNumber, "0x100000000")
        XCTAssertEqual(UInt32(0xDEADBEEF).hexNumber, "0xDEADBEEF")
        XCTAssertEqual(UInt8(0x0A).bareHexNumber, "A")
    }

    /// A negative value is its two's complement at its type's own width,
    /// never `0x-5`.
    func testANegativeValueIsTwosComplementAtItsOwnWidth() {
        XCTAssertEqual(Int(-5).hexNumber, "0xFFFFFFFFFFFFFFFB")
        XCTAssertEqual(Int64(-1).bareHexNumber, "FFFFFFFFFFFFFFFF")
        XCTAssertEqual(Int32(-1).hexNumber, "0xFFFFFFFF")
        XCTAssertEqual(Int16(-2).hexNumber, "0xFFFE")
        XCTAssertEqual(Int8(-5).hexNumber(digits: 2), "0xFB", "a padded byte keeps its two digits")
        XCTAssertEqual(Int32.min.hexNumber, "0x80000000")
        XCTAssertFalse(Int.min.hexNumber.contains("-"))
        XCTAssertEqual(Int.min.hexNumber, "0x8000000000000000")
    }

    /// The decimal form names the same number as the hex beside it.
    func testTheDecimalIsTheSameNumber() {
        XCTAssertEqual(Int32(-1).decimalNumber, "4294967295")
        XCTAssertEqual(Int(-1).decimalNumber, "18446744073709551615")
        XCTAssertEqual(UInt64(0x100).decimalNumber, "256")
        XCTAssertEqual(Int(0x1_0000_0000).decimalNumber, "4294967296")
    }

    /// A type wider than 64 bits keeps all of its digits.
    func testAWideNegativeValueKeepsItsWidth() {
        guard #available(macOS 15, *) else { return }
        #if compiler(>=6.0)
        XCTAssertEqual(Int128(-1).hexNumber, "0x" + String(repeating: "F", count: 32))
        XCTAssertEqual(Int128(-2).bareHexNumber.suffix(2), "FE")
        #endif
    }

    /// A range by its first and last byte.
    func testARangeByItsFirstAndLastByte() {
        XCTAssertEqual((UInt64(0x100)..<0x140).hexExtent, "0x100–0x13F")
        XCTAssertEqual((UInt64(0x20)..<0x21).hexExtent, "0x20", "one byte")
        XCTAssertEqual((UInt64(0x100)..<0x140).lastByte, 0x13F)
        XCTAssertEqual((UInt64(0)..<0).lastByte, 0, "an empty range gives its position, never traps")
        XCTAssertEqual((UInt64(0x100)..<0x140).halfOpenHexText, "[0x100, 0x140)", "an agent's terms")
        XCTAssertEqual((UInt64(0x20)..<0x20).hexExtent, "0x20", "empty: its position")
        XCTAssertEqual((0x1_0000_0000..<UInt64(0x1_0000_1000)).hexExtent, "0x100000000–0x100000FFF")
        // A signed range wider than the type's maximum does not trap.
        XCTAssertEqual((Int.min..<Int.max).hexExtent, "0x8000000000000000–0x7FFFFFFFFFFFFFFE")
        XCTAssertEqual((-5..<Int.max).hexExtent, "0xFFFFFFFFFFFFFFFB–0x7FFFFFFFFFFFFFFE")
    }

    /// The digit count agrees with the digits written.
    func testTheDigitCountMatchesTheText() {
        for value: UInt64 in [0, 1, 0xF, 0x10, 0xFFFF_FFFF, 0x1_0000_0000, .max] {
            XCTAssertEqual(value.hexDigitCount, value.bareHexNumber.count, "\(value)")
        }
        XCTAssertEqual(Int32(-1).hexDigitCount, 8)
        XCTAssertEqual(Int(0x1FF).hexDigitCount, 3)
    }

    /// Padded to a field's width, and never cut short of it.
    func testPaddedToAWidth() {
        XCTAssertEqual(UInt64(5).hexNumber(digits: 4), "0x0005")
        XCTAssertEqual(UInt64(0x24).bareHexNumber(digits: 8), "00000024")
        XCTAssertEqual(UInt64(0x1_2345_6780).bareHexNumber(digits: 8), "123456780", "wider than the field")
        XCTAssertEqual(UInt64(0xAB).hexNumber(digits: 0), "0xAB")
    }
}
