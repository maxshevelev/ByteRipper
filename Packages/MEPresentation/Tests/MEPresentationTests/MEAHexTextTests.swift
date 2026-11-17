import MEPresentation
import XCTest

/// The ME panel's numbers: whole past 32 bits, and every field at its own
/// type's width.
final class MEAHexTextTests: XCTestCase {
    func testValuesPast32BitsAreWhole() {
        XCTAssertEqual((0x1_2345_6780).hexNumber, "0x123456780")
        XCTAssertEqual(MEAText.size(0x1_0000_0000), "0x100000000 (4294967296 bytes)")
        XCTAssertEqual((0x0A).hexNumber(digits: 2), "0x0A")
        XCTAssertEqual((0x2A).hexNumber(digits: 4), "0x002A")
    }

    /// A field is written at its own type's width, and a size's two halves
    /// name the same number.
    func testAFieldKeepsItsTypesWidth() {
        XCTAssertEqual(Int(-1).hexNumber, "0xFFFFFFFFFFFFFFFF", "an Int is 64 bits, never guessed down")
        XCTAssertEqual(Int(-2).hexNumber, "0xFFFFFFFFFFFFFFFE")
        XCTAssertEqual(UInt8(0xFF).hexNumber(digits: 2), "0xFF")
        XCTAssertEqual(Int16(-1).hexNumber(digits: 4), "0xFFFF")
        XCTAssertEqual(MEAText.size(-1), "0xFFFFFFFFFFFFFFFF (18446744073709551615 bytes)")
    }
}
