import ByteRipperCore
import XCTest
@testable import ByteRipper

/// The panes' status-bar reading of a comparison (§14.4): the share of it that
/// differs, out of the comparison's extent, one decimal place, rounded up —
/// and nothing at all when the two files do not differ.
@MainActor
final class ComparisonSummaryTests: XCTestCase {
    private func summary(left: UInt64, right: UInt64, _ blocks: [DiffBlock]) -> ComparisonSummary {
        ComparisonSummary(index: DiffBlockIndex(leftSize: left, rightSize: right, blocks: blocks))
    }

    /// The layout §10.3's navigation tests use: two 4800-byte files differing by
    /// one byte at 1600 and one at 4000.
    private func twoDifferencesIn4800() -> ComparisonSummary {
        summary(left: 4800, right: 4800, [
            DiffBlock(kind: .same, range: 0..<1600),
            DiffBlock(kind: .different, range: 1600..<1601),
            DiffBlock(kind: .same, range: 1601..<4000),
            DiffBlock(kind: .different, range: 4000..<4001),
            DiffBlock(kind: .same, range: 4001..<4800),
        ])
    }

    func testIdenticalFilesSayNothing() {
        let identical = summary(left: 4800, right: 4800, [DiffBlock(kind: .same, range: 0..<4800)])
        XCTAssertEqual(identical.differingBytes, 0)
        XCTAssertEqual(identical.text, "", "a comparison with no differences must leave the bar silent")
    }

    func testAnEmptyComparisonSaysNothing() {
        // No bytes to compare at all: there is no extent to take a share of.
        XCTAssertEqual(summary(left: 0, right: 0, []).text, "")
    }

    /// The rounding is up, so a difference too small to round to a tenth is
    /// still reported: two bytes out of 4800 is 0.0416…%, which reads 0.1%.
    /// Rounding to nearest would print 0.0% over a real difference.
    func testASmallDifferenceRoundsUpRatherThanAway() {
        XCTAssertEqual(twoDifferencesIn4800().text, "differing 0.1%")
    }

    /// And it rounds *up*, not to nearest: 1 differing byte out of 3 is
    /// 33.333…%, which nearest would call 33.3%.
    func testTheThirdOfAFileReadsAsTheTenthAboveIt() {
        XCTAssertEqual(summary(left: 3, right: 3, [
            DiffBlock(kind: .different, range: 0..<1),
            DiffBlock(kind: .same, range: 1..<3),
        ]).text, "differing 33.4%")
    }

    /// A share that lands exactly on a tenth stays on it: 1000 of 4000 is
    /// exactly 25%, and the readout must not creep to 25.1%.
    func testAnExactShareDoesNotCreepUp() {
        XCTAssertEqual(summary(left: 4000, right: 4000, [
            DiffBlock(kind: .different, range: 0..<1000),
            DiffBlock(kind: .same, range: 1000..<4000),
        ]).text, "differing 25.0%")
    }

    /// The decimal place is always shown, whole values included, so the readout
    /// never changes width as edits land.
    func testAWholeHundredKeepsItsDecimal() {
        XCTAssertEqual(summary(left: 100, right: 100,
                               [DiffBlock(kind: .different, range: 0..<100)]).text,
                       "differing 100.0%")
    }

    /// The share is out of the longer file (§8.1), which is also what both panes
    /// scroll over (§9) — an EOF-only tail is a difference, not extra extent.
    func testTheShareIsTakenOutOfTheLongerFile() {
        let tailOnly = summary(left: 100, right: 200, [
            DiffBlock(kind: .same, range: 0..<100),
            DiffBlock(kind: .different, range: 100..<200),
        ])
        XCTAssertEqual(tailOnly.extent, 200)
        XCTAssertEqual(tailOnly.differingBytes, 100)
        XCTAssertEqual(tailOnly.text, "differing 50.0%")
    }

    /// A share that could round away entirely is still reported: 1000 bytes of
    /// 16 MB is 0.006%, and the readout says so instead of 0.0%.
    func testOneKilobyteInSixteenMegabytesStillReads() {
        let size: UInt64 = 16 * 1024 * 1024
        let tiny = summary(left: size, right: size, [
            DiffBlock(kind: .different, range: 0..<1000),
            DiffBlock(kind: .same, range: 1000..<size),
        ])
        XCTAssertEqual(tiny.text, "differing 0.1%")
    }
}
