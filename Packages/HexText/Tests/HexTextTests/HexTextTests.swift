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
}
