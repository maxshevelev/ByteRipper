import XCTest
@testable import BytePattern

/// The scan over bytes the caller reads: holes, case, and a match across the
/// edge of a window.
final class PatternScanTests: XCTestCase {
    private func starts(_ patterns: [MaskedPattern], in bytes: [UInt8], chunk: Int = 4,
                        overlapping: Bool = false) throws -> [UInt64] {
        var found: [UInt64] = []
        try PatternScan.matches(of: patterns, size: UInt64(bytes.count), overlapping: overlapping, chunkSize: chunk,
                                read: { Array(bytes[Int($0)..<min(bytes.count, Int($0) + $1)]) }) { range, _ in
            found.append(range.lowerBound)
            return true
        }
        return found
    }

    func testAHoleMatchesAnyByteAndAMatchAcrossAWindowIsFoundOnce() throws {
        let bytes: [UInt8] = [0, 0, 0x24, 0x99, 0x4D, 0x49, 0, 0x24, 0x00, 0x4D, 0x49]
        XCTAssertEqual(try starts([try MaskedPattern.hex("24 ?? 4D 49")], in: bytes), [2, 7])
    }

    func testTextIsFoundInEitherCaseInASCIIAndInUTF16() throws {
        let bytes = Array("xx Setup ".utf8) + [0x53, 0, 0x45, 0, 0x54, 0, 0x55, 0, 0x50, 0]
        XCTAssertEqual(try starts([try MaskedPattern.ascii("SETUP", ignoringCase: true)], in: bytes), [3])
        XCTAssertEqual(try starts([try MaskedPattern.utf16LE("setup", ignoringCase: true)], in: bytes), [9])
        XCTAssertEqual(try starts([try MaskedPattern.ascii("SETUP", ignoringCase: false)], in: bytes), [])
    }

    func testOverlappingMatchesAreCountedOnlyWhenAsked() throws {
        let bytes = [UInt8](repeating: 0x41, count: 4)
        let pattern = try MaskedPattern.ascii("AA", ignoringCase: false)
        XCTAssertEqual(try starts([pattern], in: bytes), [0, 2])
        XCTAssertEqual(try starts([pattern], in: bytes, overlapping: true), [0, 1, 2])
    }

    func testAPatternThatIsNotOneIsRefused() {
        XCTAssertThrowsError(try MaskedPattern.hex("?? ??"))
        XCTAssertThrowsError(try MaskedPattern.hex("4G"))
        XCTAssertThrowsError(try MaskedPattern.ascii("Привет", ignoringCase: false))
        XCTAssertThrowsError(try MaskedPattern.ascii("", ignoringCase: false))
    }

    // MARK: - Reading hex

    func testHexIsReadInPairsAcrossTheWholeText() throws {
        for text in ["DEADBEEF", "DE AD BE EF", "0xDE 0xAD 0xBE 0xEF", "D EADBEEF", "de ad be ef"] {
            let pattern = try MaskedPattern.hex(text)
            XCTAssertEqual(pattern.bytes, [0xDE, 0xAD, 0xBE, 0xEF], text)
            XCTAssertFalse(pattern.hasHoles, text)
        }
    }

    func testAHoleIsAWholeByteWhereverItIsWritten() throws {
        for text in ["24 ?? 4D", "24??4D", "0x24 ?? 0x4D", "2 4?? 4D"] {
            let pattern = try MaskedPattern.hex(text)
            XCTAssertEqual(pattern.isWild, [false, true, false], text)
            XCTAssertEqual(pattern.hexText, "24 ?? 4D", text)
        }
    }

    func testHalfAByteCannotBeMasked() {
        for text in ["2?", "?4", "24 ?", "24 ? 4D", "24 2? 4D"] {
            XCTAssertThrowsError(try MaskedPattern.hex(text), text) {
                XCTAssertEqual($0 as? SearchError, .partialByteMask, text)
            }
        }
    }

    func testHolesAloneAndNonsenseAreRefusedAsSuch() {
        XCTAssertThrowsError(try MaskedPattern.hex("?? ??")) { XCTAssertEqual($0 as? SearchError, .holesOnly) }
        XCTAssertThrowsError(try MaskedPattern.hex("4G")) { XCTAssertEqual($0 as? SearchError, .invalidHexPattern) }
        XCTAssertThrowsError(try MaskedPattern.hex("ABC")) { XCTAssertEqual($0 as? SearchError, .invalidHexPattern) }
        XCTAssertThrowsError(try MaskedPattern.hex("0x")) { XCTAssertEqual($0 as? SearchError, .invalidHexPattern) }
        XCTAssertThrowsError(try MaskedPattern.hex("   ")) { XCTAssertEqual($0 as? SearchError, .invalidHexPattern) }
    }

    // MARK: - How far a scan has got

    func testEachWindowSaysHowFarTheScanHasGot() throws {
        let bytes = [UInt8](repeating: 0, count: 10)
        var marks: [UInt64] = []
        var fractions: [Double] = []
        try PatternScan.matches(of: [try MaskedPattern.hex("01")], size: 10, chunkSize: 4,
                                read: { Array(bytes[Int($0)..<min(bytes.count, Int($0) + $1)]) },
                                progress: { fractions.append($0) },
                                windowFinished: { marks.append($0) }) { _, _ in true }
        XCTAssertEqual(marks, [4, 8, 10])
        XCTAssertEqual(fractions, [0.4, 0.8, 1.0])
    }

    // MARK: - Find Previous

    private func last(_ pattern: MaskedPattern, in bytes: [UInt8], before anchor: UInt64,
                      chunk: Int = 4) throws -> UInt64? {
        try PatternScan.lastMatch(of: pattern, size: UInt64(bytes.count), before: anchor, chunkSize: chunk,
                                  read: { Array(bytes[Int($0)..<min(bytes.count, Int($0) + $1)]) })?.lowerBound
    }

    func testFindPreviousIsTheLastMatchStartingBeforeTheAnchor() throws {
        let bytes: [UInt8] = [0, 0x24, 0x11, 0x4D, 0, 0, 0, 0, 0, 0x24, 0x22, 0x4D, 0]
        let pattern = try MaskedPattern.hex("24 ?? 4D")
        XCTAssertEqual(try last(pattern, in: bytes, before: 13), 9)
        XCTAssertEqual(try last(pattern, in: bytes, before: 9), 1, "a match starting at the anchor is not before it")
        XCTAssertEqual(try last(pattern, in: bytes, before: 10), 9, "one starting before it and running past it is")
        XCTAssertNil(try last(pattern, in: bytes, before: 1))
    }

    func testFindPreviousStepsBackThroughARunOneByteAtATime() throws {
        let bytes = [UInt8](repeating: 0xFF, count: 9)
        let pattern = try MaskedPattern.hex("FF FF")
        var anchor: UInt64 = 9
        var found: [UInt64] = []
        while let start = try last(pattern, in: bytes, before: anchor, chunk: 3) {
            found.append(start)
            anchor = start
        }
        XCTAssertEqual(found, [7, 6, 5, 4, 3, 2, 1, 0], "every overlapping match, none skipped across a window")
    }

    func testFindPreviousFindsAMatchAcrossTheEdgeOfTwoWindows() throws {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[7] = 0x24; bytes[8] = 0x44; bytes[9] = 0x4D; bytes[10] = 0x49
        XCTAssertEqual(try last(try MaskedPattern.hex("24 44 4D 49"), in: bytes, before: 20, chunk: 4), 7)
        XCTAssertEqual(try last(try MaskedPattern.hex("24 44 4D 49"), in: bytes, before: 8, chunk: 4), 7)
    }

    /// Looking through a window from its end back finds what every forward
    /// match up to the anchor would have ended on — for holes, letters in
    /// either case, and a match across windows alike.
    func testFindPreviousAgreesWithTheLastOfTheForwardMatches() throws {
        var random = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = [0x00, 0xFF, 0x41, 0x61, 0x42]
        let patterns = [
            try MaskedPattern.hex("FF FF"), try MaskedPattern.hex("41 ?? 41"),
            try MaskedPattern.ascii("aB", ignoringCase: true), try MaskedPattern.hex("00 ?? ?? FF")
        ]
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 0...40, using: &random)).map { _ in alphabet.randomElement(using: &random)! }
            let chunk = Int.random(in: 1...9, using: &random)
            let anchor = UInt64.random(in: 0...UInt64(bytes.count), using: &random)
            for pattern in patterns {
                let forward = try starts([pattern], in: bytes, chunk: chunk, overlapping: true)
                XCTAssertEqual(try last(pattern, in: bytes, before: anchor, chunk: chunk),
                               forward.last(where: { $0 < anchor }),
                               "\(pattern.hexText) in \(bytes) before \(anchor), windows of \(chunk)")
            }
        }
    }
}
