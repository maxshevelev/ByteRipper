import XCTest
@testable import FITTool
import ToolModuleKit
import UEFIImage

/// Edits to the table checked against the image's protected ranges
/// (`Design/UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §9.4).
final class FITProtectionTests: XCTestCase {
    private let microcode: UInt64 = 0x2000

    /// One microcode at `0x2000` and erased space after it: an addition lands
    /// at `0x2100..<0x2200`.
    private func image() -> [UInt8] {
        TestFIT.image(
            rows: [TestFIT.Row(FIT.microcodeType, target: microcode)],
            contents: [microcode: TestFIT.microcode(totalSize: 0x100)]
        )
    }

    private func add(
        to bytes: [UInt8], protected: ProtectedRanges?
    ) throws -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        FITEditor.addOrReplaceMicrocode(
            TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x100),
            in: try XCTUnwrap(FITReader.read(ImageReader(bytes), image: nil).table),
            image: nil,
            reader: ImageReader(bytes),
            addressDiff: TestFIT.addressDiff(of: UInt64(bytes.count)),
            protected: protected
        )
    }

    private func ranges(_ kind: ProtectedRange.Kind, _ range: Range<UInt64>) -> ProtectedRanges {
        ProtectedRanges(ranges: [ProtectedRange(kind: kind, range: range, source: 0..<0)])
    }

    private func outcome(
        _ result: Result<(ToolTransaction, FITEditOutcome), FITEditProblem>
    ) throws -> FITEditOutcome {
        switch result {
        case .success(let (_, outcome)): return outcome
        case .failure(let problem): throw problem
        }
    }

    func testAComponentThatWouldLandInTheIBBIsRefused() throws {
        let result = try add(to: image(), protected: ranges(.ibb, 0x2180..<0x2400))

        guard case .failure(let problem) = result else { return XCTFail("written into the IBB") }
        XCTAssertEqual(problem, .insideProtectedRange(name: ProtectedRange.Kind.ibb.name, at: 0x2180))
        XCTAssertTrue(problem.message.contains("Nothing was changed"), problem.message)
    }

    /// A range the firmware checks is the firmware's call: the edit is made,
    /// and what it breaks is said.
    func testAComponentInAVendorRangeIsWrittenAndSaid() throws {
        let found = try outcome(add(to: image(), protected: ranges(.amiV2, 0x2100..<0x2200)))

        XCTAssertEqual(found.range, 0x2100..<0x2200)
        XCTAssertEqual(found.protectionWarnings?.count, 1)
        XCTAssertTrue(found.protectionWarnings?.first?.contains("AMI") ?? false, "\(found.protectionWarnings ?? [])")
    }

    func testRangesTheEditDoesNotTouchSayNothing() throws {
        let found = try outcome(add(to: image(), protected: ranges(.ibb, 0x8000..<0x9000)))

        XCTAssertEqual(found.protectionWarnings, [])
    }

    func testWithoutRangesTheOutcomeSaysTheyWereNotChecked() throws {
        let found = try outcome(add(to: image(), protected: nil))

        XCTAssertNil(found.protectionWarnings)
    }

    /// A removal moves the microcode behind it up — here into the IBB.
    func testARemovalThatMovesMicrocodeIntoTheIBBIsRefused() throws {
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: 0x2000),
                TestFIT.Row(FIT.microcodeType, target: 0x2100)
            ],
            contents: [
                0x2000: TestFIT.microcode(totalSize: 0x100),
                0x2100: TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100)
            ]
        )

        let result = FITEditor.removeMicrocode(
            1,
            from: try XCTUnwrap(FITReader.read(ImageReader(bytes), image: nil).table),
            image: nil,
            in: ImageReader(bytes),
            addressDiff: TestFIT.addressDiff(of: UInt64(bytes.count)),
            protected: ranges(.ibb, 0x2000..<0x2100)
        )

        guard case .failure(.insideProtectedRange) = result else {
            return XCTFail("moved microcode into the IBB: \(result)")
        }
    }
}
