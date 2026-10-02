import XCTest
@testable import UEFIImage

final class FirmwareTextBlockTests: XCTestCase {
    private func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
    }

    func testABIOSIDIsTakenApartIntoItsFiveParts() throws {
        let id = try XCTUnwrap(BIOSIdentifier.read(
            Array("$IBIOSI$".utf8) + utf16("   MBA71.88Z.F000.B00.1906140921") + Array("Copyright".utf8)))

        XCTAssertEqual(id.text, "MBA71.88Z.F000.B00.1906140921")
        XCTAssertEqual([id.board, id.oem, id.majorVersion, id.minorVersion],
                       ["MBA71", "88Z", "F000", "B00"])
        XCTAssertEqual(id.buildDate, "2019-06-14 09:21")
    }

    func testAStringOfAnotherShapeKeepsOnlyItsText() throws {
        let id = try XCTUnwrap(BIOSIdentifier.read(Array("$IBIOSI$".utf8) + utf16("SOMETHING ELSE")))

        XCTAssertEqual(id.text, "SOMETHING ELSE")
        XCTAssertNil(id.board)
        XCTAssertNil(BIOSIdentifier.read(utf16("MBA71.88Z.F000.B00.1906140921")))
    }

    func testTheROMInformationIsAListOfKeysAndValues() throws {
        let text = "Apple ROM Version\n  BIOS ID:      MBP141.88Z.0167.B00.1708080034\n  Date:         Tue Aug  8 00:34:33 2017\n  UUID:         A\n  UUID:         B\n\n"
        let info = try XCTUnwrap(AppleROMInformation.read([0xFF, 0xFF] + Array(text.utf8) + [0, 0xFF]))

        XCTAssertEqual(info.entries.map(\.key), ["BIOS ID", "Date", "UUID", "UUID"])
        XCTAssertEqual(info.entries[1].value, "Tue Aug  8 00:34:33 2017")
        XCTAssertNil(AppleROMInformation.read(Array("nothing here".utf8)))
    }
}
