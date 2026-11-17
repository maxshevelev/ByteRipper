import MEPresentation
import XCTest

/// The ME panel's numbers: whole past 32 bits, and every field at its own
/// type's width.
final class MEAHexTextTests: XCTestCase {
    func testValuesPast32BitsAreWhole() {
        XCTAssertEqual(MEAText.hex(0x1_2345_6780), "0x123456780")
        XCTAssertEqual(MEAText.size(0x1_0000_0000), "0x100000000 (4294967296 bytes)")
        XCTAssertEqual(MEAText.hexByte(0x0A), "0x0A")
        XCTAssertEqual(MEAText.hex16(0x2A), "0x002A")
    }

    /// A field is written at its own type's width, and a size's two halves
    /// name the same number.
    func testAFieldKeepsItsTypesWidth() {
        XCTAssertEqual(MEAText.hex(Int(-1)), "0xFFFFFFFFFFFFFFFF", "an Int is 64 bits, never guessed down")
        XCTAssertEqual(MEAText.hex(Int(-2)), "0xFFFFFFFFFFFFFFFE")
        XCTAssertEqual(MEAText.hexByte(UInt8(0xFF)), "0xFF")
        XCTAssertEqual(MEAText.hex16(Int16(-1)), "0xFFFF")
        XCTAssertEqual(MEAText.size(-1), "0xFFFFFFFFFFFFFFFF (18446744073709551615 bytes)")
    }
}
