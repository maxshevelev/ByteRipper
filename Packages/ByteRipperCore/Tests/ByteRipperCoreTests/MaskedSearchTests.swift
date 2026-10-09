import XCTest
@testable import ByteRipperCore

/// Search with holes in the pattern and matches that overlap — what an agent's
/// `find_bytes` asks of the find bar's engine (`SearchEngine.matches`).
final class MaskedSearchTests: XCTestCase {
    private func starts(_ patterns: [MaskedPattern], in bytes: [UInt8], range: Range<UInt64>? = nil,
                        overlapping: Bool = false, chunk: Int = 1 << 20) throws -> [UInt64] {
        var found: [UInt64] = []
        try SearchEngine.matches(of: patterns, in: ArrayStorage(bytes), range: range, overlapping: overlapping,
                                 chunkSize: chunk) { match, _ in
            found.append(match.lowerBound)
            return true
        }
        return found
    }

    private func ascii(_ text: String, ignoreCase: Bool = false) -> MaskedPattern {
        MaskedPattern(bytes: Array(text.utf8), folding: ignoreCase ? .asciiBytes : .exact)
    }

    func testHolesMatchAnyByte() throws {
        let pattern = try MaskedPattern.hex("24 ?? 4D 49")
        XCTAssertEqual(pattern.isWild, [false, true, false, false])
        let bytes: [UInt8] = [0, 0x24, 0x44, 0x4D, 0x49, 0, 0x24, 0x99, 0x4D, 0x49, 0x24, 0x44, 0x4D]
        XCTAssertEqual(try starts([pattern], in: bytes), [1, 6], "the last one runs off the end")
        XCTAssertEqual(try MaskedPattern.hex("24??4D").isWild, [false, true, false])
        XCTAssertThrowsError(try MaskedPattern.hex("?? ??"), "holes alone match everywhere")
        XCTAssertThrowsError(try MaskedPattern.hex("ABC"))
        XCTAssertThrowsError(try MaskedPattern.hex("4G"))
    }

    func testOverlappingMatchesAreCountedOnlyWhenAskedFor() throws {
        let bytes = [UInt8](repeating: 0xFF, count: 6)
        let pattern = try MaskedPattern.hex("FF FF")
        XCTAssertEqual(try starts([pattern], in: bytes), [0, 2, 4])
        XCTAssertEqual(try starts([pattern], in: bytes, overlapping: true), [0, 1, 2, 3, 4])
    }

    /// A match across the boundary between two reads is found once, from
    /// whichever side; none is lost and none is counted twice.
    func testAMatchAcrossTheChunkBoundaryIsFoundOnce() throws {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(14..<18, with: Array("ABCD".utf8))   // across 16
        bytes.replaceSubrange(30..<34, with: Array("ABCD".utf8))   // across 32
        bytes.replaceSubrange(48..<52, with: Array("ABCD".utf8))   // at the start of a chunk
        for chunk in [4, 7, 16, 1 << 20] {
            XCTAssertEqual(try starts([ascii("ABCD")], in: bytes, chunk: chunk), [14, 30, 48], "chunk \(chunk)")
            XCTAssertEqual(try starts([ascii("ABCD")], in: bytes, overlapping: true, chunk: chunk), [14, 30, 48])
        }
        let runs = [UInt8](repeating: 0xAA, count: 40)
        XCTAssertEqual(try starts([MaskedPattern(bytes: [0xAA, 0xAA, 0xAA])], in: runs, overlapping: true, chunk: 5).count, 38)
    }

    func testNothingFoundIsAnEmptyListAndARangeNarrowsTheSearch() throws {
        let bytes = Array("one two one two".utf8)
        XCTAssertEqual(try starts([ascii("three")], in: bytes), [])
        XCTAssertEqual(try starts([ascii("one")], in: bytes, range: 1..<15), [8])
        XCTAssertEqual(try starts([ascii("one")], in: bytes, range: 8..<10), [], "a match must fit the range")
        XCTAssertEqual(try starts([ascii("a much longer pattern than the file")], in: bytes), [])
    }

    func testCaseIsFoldedOnlyWhereTheEncodingHasLetters() throws {
        let bytes = Array("Acer ACER acer".utf8)
        XCTAssertEqual(try starts([ascii("acer")], in: bytes), [10])
        XCTAssertEqual(try starts([ascii("acer", ignoreCase: true)], in: bytes), [0, 5, 10])
        XCTAssertEqual(try starts([try MaskedPattern.hex("61 63")], in: bytes), [10], "hex is bytes, never folded")
    }

    /// UTF-16 found wherever it sits, odd addresses included, and folded only
    /// where a unit is an ASCII letter: `U+4100` is not `a`.
    func testUTF16IsFoundAtOddAddressesAndFoldedByUnits() throws {
        let text: [UInt8] = [0x41, 0, 0x63, 0, 0x65, 0, 0x72, 0]          // "Acer"
        let bytes: [UInt8] = [0x99] + text + [0x61, 0x41, 0x63, 0]        // odd start; then "a䅁c"
        let pattern = MaskedPattern(bytes: [0x61, 0, 0x63, 0, 0x65, 0, 0x72, 0], folding: .utf16(littleEndian: true))
        XCTAssertEqual(try starts([pattern], in: bytes), [1])
        let short = MaskedPattern(bytes: [0x61, 0, 0x63, 0], folding: .utf16(littleEndian: true))
        XCTAssertEqual(try starts([short], in: bytes), [1], "0x61 0x41 is not a letter unit")
    }

    /// Two encodings of one text are two patterns; both are reported, in
    /// order, the first pattern first where they start together.
    func testSeveralPatternsComeBackInOrderOfWhereTheyStart() throws {
        let bytes: [UInt8] = Array("xAcer".utf8) + [0x41, 0, 0x63, 0, 0x65, 0, 0x72, 0]
        var found: [(UInt64, Int)] = []
        try SearchEngine.matches(of: [ascii("Acer"), MaskedPattern(bytes: [0x41, 0, 0x63, 0, 0x65, 0, 0x72, 0])],
                                 in: ArrayStorage(bytes), chunkSize: 3) { match, pattern in
            found.append((match.lowerBound, pattern))
            return true
        }
        XCTAssertEqual(found.map(\.0), [1, 5])
        XCTAssertEqual(found.map(\.1), [0, 1])
    }

    func testVisitStopsTheScan() throws {
        var seen = 0
        try SearchEngine.matches(of: [MaskedPattern(bytes: [0])], in: ArrayStorage([UInt8](repeating: 0, count: 100))) { _, _ in
            seen += 1
            return seen < 3
        }
        XCTAssertEqual(seen, 3)
    }

    func testAWholeDumpIsSearchedInWellUnderASecond() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 16 << 20)
        bytes.replaceSubrange(0x6CF000..<0x6CF004, with: [0x24, 0x44, 0x4D, 0x49])
        let clock = ContinuousClock()
        var found: [UInt64] = []
        let took = try clock.measure {
            found = try starts([try MaskedPattern.hex("24 44 4D 49")], in: bytes)
        }
        XCTAssertEqual(found, [0x6CF000])
        XCTAssertLessThan(took, .seconds(1))
    }
}

extension MaskedSearchTests {
    /// A pattern that matches everywhere: every match counted.
    func testAPatternThatMatchesEverywhereIsStillCountedQuickly() throws {
        // 4 MiB: a debug build pays for every one of the matches' calls; a
        // release build counts 16 MiB of them in about a tenth of a second.
        let bytes = [UInt8](repeating: 0xFF, count: 4 << 20)
        var count = 0
        let clock = ContinuousClock()
        let took = try clock.measure {
            try SearchEngine.matches(of: [try MaskedPattern.hex("FF FF")], in: ArrayStorage(bytes)) { _, _ in
                count += 1
                return true
            }
        }
        XCTAssertEqual(count, 2 << 20)
        XCTAssertLessThan(took, .seconds(5))
    }
}
