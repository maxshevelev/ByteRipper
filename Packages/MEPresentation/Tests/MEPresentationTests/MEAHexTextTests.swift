import MEPresentation
import XCTest

/// The ME panel's numbers: whole past 32 bits, and a damaged negative field
/// at the width it was read in.
final class MEAHexTextTests: XCTestCase {
    func testValuesPast32BitsAreWhole() {
        XCTAssertEqual(MEAText.hex(0x1_2345_6780), "0x123456780")
        XCTAssertEqual(MEAText.size(0x1_0000_0000), "0x100000000 (4294967296 bytes)")
        XCTAssertEqual(MEAText.hexByte(0x0A), "0x0A")
        XCTAssertEqual(MEAText.hex16(0x2A), "0x002A")
    }

    func testANegativeFieldReadsAsItsWord() {
        XCTAssertEqual(MEAText.hex(-1), "0xFFFFFFFF")
        XCTAssertEqual(MEAText.hexByte(-1), "0xFFFFFFFF")
        XCTAssertEqual(MEAText.hex16(-2), "0xFFFFFFFE")
    }
}
