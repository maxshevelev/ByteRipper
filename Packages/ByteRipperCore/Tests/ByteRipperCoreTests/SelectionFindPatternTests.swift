import XCTest
@testable import ByteRipperCore

/// §11 Use Selection for Find: what a selection becomes when it is put into the
/// Find bar's pattern — bytes from the hex column, text from the decoded-text
/// column, and bytes again where the "text" is not text.
final class SelectionFindPatternTests: XCTestCase {
    // MARK: - The hex column

    /// Bytes come back in the form a dump prints: uppercase pairs, one space
    /// between them — the same text a search writes back into the field, so a
    /// pattern taken from the dump reads exactly like a typed one.
    func testHexRegionTakesTheBytesAsADumpPrintsThem() {
        let pattern = SelectionFindPattern.forBytes([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(pattern.text, "DE AD BE EF")
        XCTAssertEqual(pattern.encoding, .hex)
    }

    /// A single byte is a pattern too, and keeps its leading zero: `0F`, not `F`.
    func testHexRegionPadsASingleByte() {
        XCTAssertEqual(SelectionFindPattern.forBytes([0x0F]).text, "0F")
    }

    /// Bytes that happen to be readable text are still bytes when they were
    /// selected as bytes: the column the selection was made in is the question
    /// being answered, not what the bytes could also be read as.
    func testHexRegionDoesNotBecomeTextEvenWhenItCould() {
        let pattern = SelectionFindPattern.forBytes(Array("AB".utf8))
        XCTAssertEqual(pattern.text, "41 42")
        XCTAssertEqual(pattern.encoding, .hex)
    }

    // MARK: - The decoded-text column

    func testTextRegionTakesASCIIAsUTF8Text() {
        let pattern = SelectionFindPattern.forText(Array("$IBIOSI$".utf8))
        XCTAssertEqual(pattern.text, "$IBIOSI$")
        XCTAssertEqual(pattern.encoding, .utf8)
    }

    /// Multi-byte UTF-8 survives whole: the bytes are decoded, not taken one at
    /// a time the way the column draws them.
    func testTextRegionDecodesMultiByteUTF8() {
        let pattern = SelectionFindPattern.forText(Array("Größe".utf8))
        XCTAssertEqual(pattern.text, "Größe")
        XCTAssertEqual(pattern.encoding, .utf8)
    }

    /// Fill, code, anything that is not UTF-8: the pattern is the bytes. A
    /// pattern of replacement characters would find nothing that is in the
    /// file.
    func testTextRegionFallsBackToBytesWhenTheyAreNotUTF8() {
        let pattern = SelectionFindPattern.forText([0xFF, 0xFE, 0x80])
        XCTAssertEqual(pattern.text, "FF FE 80")
        XCTAssertEqual(pattern.encoding, .hex)
    }

    /// A selection that starts or ends mid-character does not decode, so it
    /// falls back to its bytes rather than to a shortened string.
    func testTextRegionFallsBackOnAPartialCharacter() {
        // `Größe` is 47 72 C3 B6 C3 9F 65; three bytes of it cut the `ö` in
        // half, which is exactly what a selection ending mid-character is.
        let full = Array("Größe".utf8)
        let pattern = SelectionFindPattern.forText(Array(full.prefix(3)))
        XCTAssertEqual(pattern.encoding, .hex,
                       "a truncated multi-byte character is not UTF-8 text")
        XCTAssertEqual(pattern.text, "47 72 C3")
    }

    /// Decodable but not readable: a pattern carrying a NUL or a newline cannot
    /// be read back off the field or corrected there, so those bytes are
    /// searched for as bytes.
    func testTextRegionFallsBackOnControlCharacters() {
        XCTAssertEqual(SelectionFindPattern.forText(Array("AB\0".utf8)).encoding, .hex)
        XCTAssertEqual(SelectionFindPattern.forText(Array("AB\n".utf8)).encoding, .hex)
        XCTAssertEqual(SelectionFindPattern.forText([0x7F]).encoding, .hex, "DEL")
        XCTAssertEqual(SelectionFindPattern.forText(Array("A\u{0085}".utf8)).encoding, .hex,
                       "a C1 control decodes and is still not readable")
    }

    /// A space is text — it is in every string a dump reader looks for — and so
    /// is punctuation.
    func testTextRegionKeepsSpacesAndPunctuation() {
        let pattern = SelectionFindPattern.forText(Array("AMI BIOS (C)".utf8))
        XCTAssertEqual(pattern.text, "AMI BIOS (C)")
        XCTAssertEqual(pattern.encoding, .utf8)
    }

    /// Nothing selected is nothing to search for: `readableUTF8` says so, and
    /// the empty hex text says it too. The command itself never asks — an empty
    /// selection greys the menu item out (§11).
    func testEmptyBytesAreNoPattern() {
        XCTAssertNil(SelectionFindPattern.readableUTF8([]))
        XCTAssertEqual(SelectionFindPattern.forBytes([]).text, "")
    }
}
