import XCTest
@testable import UEFIImage

/// The dependency-expression bytecode: what it reads as, and what it says when
/// it does not read.
final class DependencyExpressionTests: XCTestCase {
    private let a = EFIGUID("11111111-1111-1111-1111-111111111111")!
    private let b = EFIGUID("22222222-2222-2222-2222-222222222222")!
    private let c = EFIGUID("33333333-3333-3333-3333-333333333333")!

    private let push: UInt8 = 0x02
    private let and: UInt8 = 0x03
    private let or: UInt8 = 0x04
    private let not: UInt8 = 0x05
    private let always: UInt8 = 0x06
    private let never: UInt8 = 0x07
    private let end: UInt8 = 0x08

    private func bytes(_ values: [[UInt8]]) -> [UInt8] {
        values.flatMap { $0 }
    }

    private func pushed(_ guid: EFIGUID) -> [UInt8] {
        [push] + guid.bytes
    }

    // MARK: - Reading

    func testAnAndChainReadsAsAnd() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([pushed(a), pushed(b), [and], [end]]))
        XCTAssertEqual(expression.text(), "\(a) AND \(b)")
        XCTAssertTrue(expression.problems.isEmpty)
        XCTAssertFalse(expression.isMalformed)
        XCTAssertFalse(expression.isAlways)
        XCTAssertFalse(expression.isNever)
    }

    func testOrNeedsParenthesesUnderAnd() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([pushed(a), pushed(b), [or], pushed(c), [and], [end]]))
        XCTAssertEqual(expression.text(), "(\(a) OR \(b)) AND \(c)")
    }

    func testNotBindsTighterThanAnd() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([pushed(a), [not], pushed(b), [and], [end]]))
        XCTAssertEqual(expression.text(), "NOT \(a) AND \(b)")
    }

    func testTrueAndFalseAreStatements() {
        XCTAssertEqual(DependencyExpression(kind: .pei, bytes: [always, end]).text(), "TRUE")
        XCTAssertTrue(DependencyExpression(kind: .pei, bytes: [always, end]).isAlways)
        XCTAssertEqual(DependencyExpression(kind: .pei, bytes: [never, end]).text(), "FALSE")
        XCTAssertTrue(DependencyExpression(kind: .pei, bytes: [never, end]).isNever)
    }

    func testAnEmptyBodyIsAlways() {
        let expression = DependencyExpression(kind: .pei, bytes: [])
        XCTAssertEqual(expression.text(), "TRUE")
        XCTAssertTrue(expression.isAlways)
        XCTAssertTrue(expression.problems.isEmpty)
    }

    func testNamesStandInForGUIDs() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([pushed(a), pushed(b), [and], [end]]))
        let text = expression.text { $0 == self.a ? "Memory discovered" : nil }
        XCTAssertEqual(text, "Memory discovered AND \(b)")
    }

    func testPushedGUIDsKeepFirstSightOrder() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([pushed(b), pushed(a), [and], pushed(b), [or], [end]]))
        XCTAssertEqual(expression.pushedGUIDs, [b, a])
    }

    // MARK: - Problems

    func testAnUnknownOpcodeIsKeptAndStopsTheRead() {
        let expression = DependencyExpression(kind: .pei, bytes: [0x0A])
        XCTAssertEqual(expression.tokens.map(\.operation.name), ["0x0A"])
        XCTAssertEqual(expression.problems, [.unknownOperation(0x0A, at: 0)])
        XCTAssertTrue(expression.isMalformed)
        XCTAssertNil(expression.text())
    }

    func testATruncatedGUIDIsReported() {
        let expression = DependencyExpression(kind: .pei, bytes: [push, 0x01, 0x02, 0x03])
        XCTAssertEqual(expression.problems, [.truncatedGUID(at: 0)])
        XCTAssertTrue(expression.tokens.isEmpty)
        XCTAssertTrue(expression.isMalformed)
    }

    func testAnOperatorWithTooFewOperandsIsReported() {
        let expression = DependencyExpression(kind: .pei, bytes: [and, end])
        XCTAssertEqual(expression.problems, [.missingOperands(at: 0)])
        XCTAssertTrue(expression.isMalformed)
    }

    func testTwoValuesAtEndAreLeftOver() {
        let expression = DependencyExpression(kind: .pei, bytes: bytes([pushed(a), pushed(b), [end]]))
        XCTAssertEqual(expression.problems, [.leftoverValues(2)])
        XCTAssertNil(expression.text())
    }

    func testAMissingEndIsReported() {
        let expression = DependencyExpression(kind: .pei, bytes: pushed(a))
        XCTAssertEqual(expression.problems, [.missingEnd])
        XCTAssertEqual(expression.text(), "\(a)")
        XCTAssertTrue(expression.isMalformed)
    }

    func testZeroPaddingAfterEndIsNotAProblem() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([pushed(a), [end], [0, 0, 0]]))
        XCTAssertTrue(expression.problems.isEmpty)
    }

    func testBytesAfterEndAreAWarning() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([pushed(a), [end], [0xAA, 0x00]]))
        XCTAssertEqual(expression.problems, [.bytesAfterEnd(1)])
        XCTAssertFalse(expression.isMalformed)
        XCTAssertEqual(expression.text(), "\(a)")
    }

    func testAPrefixIsPartOfTheTextInDXE() {
        let expression = DependencyExpression(
            kind: .dxe, bytes: bytes([[0x00], pushed(a), [end]]))
        XCTAssertEqual(expression.text(), "BEFORE \(a)")
        XCTAssertTrue(expression.problems.isEmpty)
    }

    func testAPrefixIsNotAllowedInPEI() {
        let expression = DependencyExpression(
            kind: .pei, bytes: bytes([[0x00], pushed(a), [end]]))
        XCTAssertEqual(expression.problems, [.prefixNotAllowed(.before, at: 0)])
        XCTAssertTrue(expression.isMalformed)
    }

    func testAPrefixAfterAValueIsMisplaced() {
        let expression = DependencyExpression(
            kind: .dxe, bytes: bytes([pushed(a), [0x01], [end]]))
        XCTAssertEqual(expression.problems, [.prefixNotAtStart(.after, at: 17)])
    }

    func testSectionTypesChooseTheKind() {
        XCTAssertEqual(DependencyExpression.Kind(sectionType: 0x1B), .pei)
        XCTAssertEqual(DependencyExpression.Kind(sectionType: 0x13), .dxe)
        XCTAssertEqual(DependencyExpression.Kind(sectionType: 0x1C), .mm)
        XCTAssertNil(DependencyExpression.Kind(sectionType: 0x10))
    }

    /// The six-PPI expression CpuPei carries in `CSME 15.bin`, as the parser
    /// read it: six pushes, five ANDs, END.
    func testTheCpuPeiExpression() {
        let bytes: [UInt8] = [
            0x02, 0x3D, 0x64, 0x94, 0xF8, 0x49, 0xC4, 0xD1, 0x42, 0x8E, 0xA8, 0x85, 0xBD, 0xD8, 0xC6, 0x5B, 0xDE,
            0x02, 0x48, 0xD7, 0x08, 0x74, 0x8C, 0xFC, 0xE6, 0x4E, 0x92, 0x88, 0xC4, 0xBE, 0xC0, 0x92, 0xA4, 0x10,
            0x02, 0x7B, 0x1F, 0xAF, 0xE6, 0x3F, 0xFC, 0xDA, 0x46, 0xA8, 0x28, 0xA3, 0xB4, 0x57, 0xA4, 0x42, 0x82,
            0x02, 0x9A, 0x44, 0x7A, 0x05, 0xDC, 0x1F, 0x06, 0x4C, 0xBF, 0xC9, 0xF5, 0x3F, 0x6A, 0x99, 0xBB, 0x92,
            0x02, 0xF5, 0x6E, 0xB8, 0x2A, 0xB5, 0xEC, 0x34, 0x41, 0xB5, 0x56, 0x38, 0x54, 0xCA, 0x1F, 0xE1, 0xB4,
            0x02, 0x25, 0x4D, 0xF3, 0x01, 0xE2, 0x4D, 0xAD, 0x23, 0x3F, 0xF3, 0x36, 0x35, 0x3F, 0xF3, 0x23, 0xF1,
            0x03, 0x03, 0x03, 0x03, 0x03, 0x08,
        ]
        let expression = DependencyExpression(kind: .pei, bytes: bytes)
        XCTAssertTrue(expression.problems.isEmpty)
        XCTAssertEqual(expression.tokens.count, 12)
        XCTAssertEqual(expression.pushedGUIDs.count, 6)
        XCTAssertEqual(expression.pushedGUIDs.first,
                       EFIGUID("F894643D-C449-42D1-8EA8-85BDD8C65BDE"))
        XCTAssertEqual(expression.pushedGUIDs.last,
                       EFIGUID("01F34D25-4DE2-23AD-3FF3-36353FF323F1"))
        XCTAssertEqual(expression.tokens.filter { $0.operation == .and }.count, 5)
        XCTAssertEqual(expression.text()?.components(separatedBy: " AND ").count, 6)
    }
}
