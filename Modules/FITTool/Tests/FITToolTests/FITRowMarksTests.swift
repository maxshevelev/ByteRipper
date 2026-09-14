import XCTest
@testable import FITTool
import ToolModuleKit
import UEFIImage

/// What a FIT row wears, in the shared catalogue's icons (`ROW_MARKS.md` §5.2).
final class FITRowMarksTests: XCTestCase {
    private let microcode: UInt64 = 0x2000

    private func display(_ rows: [TestFIT.Row], microcodeBytes: [UInt8]? = nil) -> FITDisplay {
        let bytes = TestFIT.image(
            rows: rows,
            contents: [microcode: microcodeBytes ?? TestFIT.microcode(totalSize: 0x180)]
        )
        let parsed = UEFIImage(size: 0x1_0000, roots: [], addressDiff: 0xFFFF_0000)
        return FITPresenter.display(FITReader.read(ImageReader(bytes), image: parsed))
    }

    private func marks(_ shown: FITDisplay, row: Int) -> ToolRowMarks {
        FITRowMarks.marks(for: shown.rows[row], problems: shown.problems)
    }

    func testAGoodMicrocodeRowHasNoProblem() {
        let shown = display([TestFIT.Row(FIT.microcodeType, target: microcode)])
        XCTAssertNil(marks(shown, row: 1).problem)
        XCTAssertNil(marks(shown, row: 0).problem)
    }

    /// A microcode image that does not sum to zero is an error on its row,
    /// saying what the checksum is and what it should be.
    func testAMicrocodeWithAWrongImageChecksumIsAnError() throws {
        var broken = TestFIT.microcode(totalSize: 0x180)
        broken[0x60] ^= 0x01
        let shown = display([TestFIT.Row(FIT.microcodeType, target: microcode)],
                            microcodeBytes: broken)

        let problem = try XCTUnwrap(marks(shown, row: 1).problem)
        XCTAssertTrue(problem.isError)
        XCTAssertEqual(problem.lines.count, 1)
        XCTAssertTrue(problem.lines[0].hasPrefix("Invalid microcode image checksum: 0x"), problem.lines[0])
        XCTAssertTrue(problem.lines[0].contains("should be 0x"), problem.lines[0])
        XCTAssertNil(marks(shown, row: 0).problem, "the header is fine")
    }

    /// The validator's error on a row is an error; its warning a caution.
    func testTheValidatorsFindingsKeepTheirSeverity() throws {
        let unaligned = display([TestFIT.Row(FIT.microcodeType, target: microcode + 4)])
        XCTAssertEqual(try XCTUnwrap(marks(unaligned, row: 1).problem).isError, true)

        var row = TestFIT.Row(FIT.microcodeType, target: microcode)
        row.reserved = 1
        let reserved = display([row])
        let caution = try XCTUnwrap(marks(reserved, row: 1).problem)
        XCTAssertFalse(caution.isError, "a reserved byte that is not zero is a caution")
        XCTAssertEqual(caution.lines, ["The reserved byte is 0x1, and should be zero"])
    }

    /// The Key Manifest and Boot Policy rows hold what the IBB is checked
    /// against, and wear the badge that says so; no other row does.
    func testTheBootGuardManifestRowsHoldChecks() {
        let shown = display([
            TestFIT.Row(FIT.microcodeType, target: microcode),
            TestFIT.Row(FIT.keyManifestType, target: 0x3000),
            TestFIT.Row(FIT.bootPolicyType, target: 0x4000)
        ])

        XCTAssertEqual(marks(shown, row: 0).roles, [])
        XCTAssertEqual(marks(shown, row: 1).roles, [])
        guard case .holdsChecks(let key)? = marks(shown, row: 2).roles.first,
              case .holdsChecks(let policy)? = marks(shown, row: 3).roles.first
        else { return XCTFail("the manifest rows wear the badge") }
        XCTAssertTrue(key.contains("Key Manifest"), key)
        XCTAssertTrue(policy.contains("Boot Policy"), policy)
        XCTAssertTrue(FITRowMarks.legendMarks.contains(.holdsChecks))
    }

    /// Each "latest" state is a verdict of the shared catalogue; no state, no
    /// verdict.
    func testTheLatestStatesAreTheCataloguesVerdicts() {
        XCTAssertEqual(FITRowMarks.verdict(of: .latest)?.mark, .newest)
        XCTAssertEqual(FITRowMarks.verdict(of: .outdated(newestRevision: 0xF0))?.mark, .newerListed)
        XCTAssertEqual(FITRowMarks.verdict(of: .outdated(newestRevision: 0xF0))?.toolTip,
                       "Catalogue lists a newer revision (r.F0)")
        XCTAssertEqual(FITRowMarks.verdict(of: .undecided(newestRevision: 0xF0))?.mark, .newerMaybe)
        XCTAssertNil(FITRowMarks.verdict(of: .notRated))
        XCTAssertTrue(FITRowMarks.legendMarks.allSatisfy { [.verdict, .problem, .role].contains($0.channel) },
                      "no paint: the table has nothing for Show Markings to hide")
    }
}
