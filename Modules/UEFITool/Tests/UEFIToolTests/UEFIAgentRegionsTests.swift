import XCTest
@testable import UEFITool

/// How `region_scan` judges a nameless area by its bytes, and which areas it
/// keeps quiet about.
final class UEFIAgentRegionsTests: XCTestCase {
    func testAnAreaOfFillIsEmptyAndSaysWhereItsOtherBytesAre() {
        var bytes = [UInt8](repeating: 0xFF, count: 0x1000)
        bytes.replaceSubrange(0..<4, with: Array("$DMI".utf8))
        let judged = UEFIAgentRegions.judge(bytes, at: 0x6CF000)
        XCTAssertEqual(judged.kind, .empty)
        XCTAssertEqual(judged.firstNonFill, 0x6CF000)
        XCTAssertEqual(judged.lastNonFill, 0x6CF003)
        XCTAssertEqual(judged.strings.map(\.text), ["$DMI"])
        XCTAssertEqual(UEFIAgentRegions.judge([UInt8](repeating: 0, count: 64), at: 0).firstNonFill, nil)
    }

    func testStringsAmongZerosAreText() {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes.replaceSubrange(0x10..<0x1A, with: Array("Board Name".utf8))
        bytes.replaceSubrange(0x40..<0x50, with: Array("Model 1234".utf16).flatMap { [UInt8($0), 0] }.prefix(16))
        bytes[0x80] = 0x12
        let judged = UEFIAgentRegions.judge(bytes, at: 0x1000)
        XCTAssertEqual(judged.kind, .text)
        XCTAssertEqual(judged.strings.map(\.text), ["Board Name", "Model 12"])
        XCTAssertEqual(judged.strings.map(\.utf16), [false, true])
        XCTAssertEqual(judged.strings.first?.offset, 0x1010)
    }

    func testCompiledX86IsCodeAndNoiseIsData() {
        // Moves, a stack adjustment and calls, as a compiler lays them out.
        let block: [UInt8] = [0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0xD9,
                              0xE8, 0x10, 0x20, 0x00, 0x00, 0x48, 0x8B, 0xC3, 0x48, 0x83, 0xC4, 0x20, 0x5B, 0xC3]
        let code = Array((0..<64).map { _ in block }.joined())
        XCTAssertEqual(UEFIAgentRegions.judge(code, at: 0).kind, .code)
        XCTAssertEqual(UEFIAgentRegions.judge(Array("MZ".utf8) + [UInt8](repeating: 0x11, count: 0x200), at: 0).kind, .code,
                       "a PE image")
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<0x2000).map { _ in UInt8.random(in: 1...0xFE, using: &generator) }
        XCTAssertEqual(UEFIAgentRegions.judge(noise, at: 0).kind, .data)
    }

    func testAreasNamedForASecretAreKnownByAWordOfTheirName() {
        for name in ["MSDM Table", "Password", "OEM Key", "keys"] {
            XCTAssertTrue(UEFIAgentRegions.isSecretName(name), name)
        }
        for name in ["Keyboard Layout", "Unused", "SMBIOS Update", "Passwordless"] {
            XCTAssertFalse(UEFIAgentRegions.isSecretName(name), name)
        }
    }
}
