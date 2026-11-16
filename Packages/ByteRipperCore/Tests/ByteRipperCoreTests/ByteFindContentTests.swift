import XCTest
@testable import ByteRipperCore

/// The dump's search (#33): holes in a hex pattern, and matches that always
/// overlap — counted, stepped forward and back, and indexed the same way.
final class ByteFindContentTests: XCTestCase {
    private func query(_ hex: String) throws -> ByteQuery {
        ByteQuery(pattern: try SearchEngine.parsePattern(hex, encoding: .hex, allowingHoles: true),
                  folding: .exact)
    }

    private func starts(_ query: ByteQuery, in bytes: [UInt8], chunk: Int = 4) async throws -> [UInt64] {
        let content = ByteFindContent(storage: ArrayStorage(bytes), chunkSize: chunk)
        var found: [UInt64] = []
        var covered: UInt64 = 0
        for try await batch in content.matchStarts(of: query, shouldCancel: { false }, progress: { _ in }) {
            XCTAssertGreaterThanOrEqual(batch.scannedUpTo, covered, "what is known only grows")
            XCTAssertTrue(batch.starts.allSatisfy { $0 < batch.scannedUpTo },
                          "a batch holds only starts below what it says is known")
            covered = batch.scannedUpTo
            found += batch.starts
        }
        XCTAssertEqual(covered, UInt64(bytes.count), "the scan says it reached the end")
        return found
    }

    private func step(_ query: ByteQuery, in bytes: [UInt8], from anchor: UInt64,
                      _ direction: SearchDirection, chunk: Int = 4) throws -> UInt64? {
        try ByteFindContent(storage: ArrayStorage(bytes), chunkSize: chunk)
            .firstMatch(of: query, from: anchor, direction: direction,
                        shouldCancel: { false }, progress: { _ in })?.lowerBound
    }

    // MARK: - Overlapping, always

    func testARunOfFFHoldsOneMatchOfFFFFLessThanItsLength() async throws {
        let bytes = [0x00] + [UInt8](repeating: 0xFF, count: 9) + [0x00]
        let found = try await starts(try query("FF FF"), in: bytes)
        XCTAssertEqual(found, Array(1...8),
                       "nine 0xFF are eight matches of FF FF, across the edges of windows too")
    }

    func testFindNextAndPreviousWalkARunOneByteAtATime() throws {
        let bytes = [0x00] + [UInt8](repeating: 0xFF, count: 5) + [0x00]
        let pattern = try query("FF FF")
        XCTAssertEqual(try step(pattern, in: bytes, from: 2, .forward), 2,
                       "Find Next lands on a match starting at the anchor")
        XCTAssertEqual(try step(pattern, in: bytes, from: 3, .forward), 3,
                       "one byte on from the match at 2 is the match at 3, not the one at 4")
        XCTAssertEqual(try step(pattern, in: bytes, from: 3, .backward), 2,
                       "Find Previous is the last match starting before the anchor")
        XCTAssertNil(try step(pattern, in: bytes, from: 5, .forward), "a run of five has its last match at 4")
        XCTAssertNil(try step(pattern, in: bytes, from: 1, .backward))
    }

    func testAPatternThatDoesNotOverlapItselfFindsWhatItAlwaysFound() async throws {
        var bytes = [UInt8](repeating: 0, count: 40)
        for at in [3, 17, 30] { bytes.replaceSubrange(at..<at + 4, with: Array("$DMI".utf8)) }
        let pattern = ByteQuery(pattern: try SearchEngine.parsePattern("$DMI", encoding: .ascii), folding: .exact)
        let found = try await starts(pattern, in: bytes)
        XCTAssertEqual(found, [3, 17, 30])
        XCTAssertEqual(try step(pattern, in: bytes, from: 4, .forward), 17)
        XCTAssertEqual(try step(pattern, in: bytes, from: 17, .backward), 3)
    }

    // MARK: - Holes

    func testAHoleMatchesAnyByte() async throws {
        let bytes: [UInt8] = [0, 0x24, 0x44, 0x4D, 0x49, 0, 0x24, 0x00, 0x4D, 0x49, 0x24, 0x44, 0x4E, 0x49]
        let pattern = try query("24 ?? 4D 49")
        let found = try await starts(pattern, in: bytes)
        XCTAssertEqual(found, [1, 6])
        XCTAssertEqual(try step(pattern, in: bytes, from: 2, .forward), 6)
        XCTAssertEqual(try step(pattern, in: bytes, from: 14, .backward), 6)
    }

    func testAMaskThatOverlapsItselfCountsEveryPlace() async throws {
        let bytes: [UInt8] = [0x24, 0x24, 0x24, 0x24]
        let found = try await starts(try query("24 ?? 24"), in: bytes)
        XCTAssertEqual(found, [0, 1])
    }

    // MARK: - Reading the field

    func testAHoleIsKeptOnlyWhereTheCallerSearchesWithOne() throws {
        let masked = try SearchEngine.parsePattern("24 ?? 4D", encoding: .hex, allowingHoles: true)
        XCTAssertEqual(masked.isWild, [false, true, false])
        XCTAssertEqual(masked.hexText, "24 ?? 4D", "the form a search shows back")
        XCTAssertThrowsError(try SearchEngine.parsePattern("24 ?? 4D", encoding: .hex),
                             "a fill has to write every byte it names") {
            XCTAssertEqual($0 as? SearchError, .invalidHexPattern)
        }
        XCTAssertFalse(try SearchEngine.parsePattern("24 4D", encoding: .hex).hasHoles)
        XCTAssertThrowsError(try SearchEngine.parsePattern("24 2? 4D", encoding: .hex, allowingHoles: true)) {
            XCTAssertEqual($0 as? SearchError, .partialByteMask, "half a byte cannot be masked")
        }
    }

    func testSmartSearchReadsAHexPatternWithHolesAsBytesFirst() throws {
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("24 ?? 4D 49"))
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("24??4D49"))
        XCTAssertTrue(SmartSearch.looksLikeHexBytes("BE ??"), "a pair of its own is a byte")
        for text in ["be??", "FACE??", "??4D", "24 ?", "2?4D", "24?? 4D49"] {
            XCTAssertFalse(SmartSearch.looksLikeHexBytes(text), "\(text) is text: ?? at a run's edge or not a pair")
        }
        let attempts = SmartSearch.attempts(for: "24 ?? 4D 49", caseSensitive: false)
        XCTAssertEqual(attempts.first?.encoding, .hex)
        XCTAssertEqual(attempts.first?.pattern.isWild, [false, true, false, false])
        XCTAssertTrue(attempts.dropFirst().allSatisfy { !$0.pattern.hasHoles },
                      "as text, `??` is two question marks")
    }
}
