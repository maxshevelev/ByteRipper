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

    /// A negative value is its 64-bit two's complement, never `0x-5`.
    func testANegativeValueIsTwosComplement() {
        XCTAssertEqual(Int(-5).hexNumber, "0xFFFFFFFFFFFFFFFB")
        XCTAssertEqual(Int(-1).bareHexNumber, "FFFFFFFFFFFFFFFF")
        XCTAssertEqual(Int32(-1).hexNumber, "0xFFFFFFFFFFFFFFFF")
        XCTAssertFalse(Int.min.hexNumber.contains("-"))
    }

    /// Padded to a field's width, and never cut short of it.
    func testPaddedToAWidth() {
        XCTAssertEqual(UInt64(5).hexNumber(digits: 4), "0x0005")
        XCTAssertEqual(UInt64(0x24).bareHexNumber(digits: 8), "00000024")
        XCTAssertEqual(UInt64(0x1_2345_6780).bareHexNumber(digits: 8), "123456780", "wider than the field")
        XCTAssertEqual(UInt64(0xAB).hexNumber(digits: 0), "0xAB")
    }
}
