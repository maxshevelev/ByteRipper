import Foundation
import XCTest
@testable import CodeAnalysis

/// The artifact's indices: what the Code panel and an agent look up on every
/// click must agree with what a walk of the artifact would find.
final class CodeModelTests: XCTestCase {
    private func artifact() throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":3,"program":{"image_base":"0x0","language":"x86:LE:32:default"},
         "strings":[{"address":"0x240","type":"unicode","value":"AB"}],
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","signature":"void FUN_00000220(void)",
           "instructions":[
            {"address":"0x220","bytes":"74 01","mnemonic":"JZ","text":"JZ 0x00000223",
             "references":[{"to":"0x223","type":"CONDITIONAL_JUMP"}]},
            {"address":"0x222","bytes":"90","mnemonic":"NOP","text":"NOP"},
            {"address":"0x223","bytes":"E8 00 00 00 00","mnemonic":"CALL","text":"CALL 0x00000230",
             "references":[{"to":"0x230","type":"UNCONDITIONAL_CALL"}]}]},
          {"entry":"0x230","name":"entry","instructions":[
            {"address":"0x230","bytes":"B8 40 02 00 00","mnemonic":"MOV","text":"MOV EAX,0x240",
             "references":[{"to":"0x240","type":"DATA"}]},
            {"address":"0x238","bytes":"C3","mnemonic":"RET","text":"RET"}]}
         ]}
        """.utf8))
    }

    private func model() throws -> CodeModel {
        CodeModel(artifact: try artifact(), moduleBytes: Self.teModule())
    }

    func testFunctionsAreFoundByEntryAndByName() throws {
        let model = try model()
        XCTAssertEqual(model.function(at: CodeAddress(0x230)), 1)
        XCTAssertNil(model.function(at: CodeAddress(0x231)))
        XCTAssertEqual(model.function(named: "entry"), 1)
        XCTAssertEqual(model.function(named: "0x220"), 0)
        XCTAssertEqual(model.lines(ofFunction: 1).map(\.global), [3, 4])
        XCTAssertEqual(model.name(for: CodeAddress(0x230)), "entry")
    }

    func testSearchMatchesNamesSignaturesAndInstructions() throws {
        let model = try model()
        XCTAssertEqual(model.functions(matching: ""), [0, 1])
        XCTAssertEqual(model.functions(matching: "nop"), [0])
        XCTAssertEqual(model.functions(matching: "VOID"), [0])
        XCTAssertEqual(model.functions(matching: "ret"), [1])
        XCTAssertEqual(model.functions(matching: "nothing"), [])
    }

    /// The TE header strips 0x1B8 bytes and keeps 40, so RVA 0x220 is module
    /// offset 0x68.
    func testALineIsFoundByTheBytesItCovers() throws {
        let model = try model()
        XCTAssertEqual(model.moduleRange(ofLine: 0), 0x68..<0x6A)
        XCTAssertEqual(model.line(forModuleRange: 0x68..<0x68), 0)
        XCTAssertEqual(model.line(forModuleRange: 0x69..<0x69), 0, "inside the JZ")
        XCTAssertEqual(model.line(forModuleRange: 0x6A..<0x6B), 1)
        XCTAssertEqual(model.line(forModuleRange: 0x6C..<0x70), 2)
        XCTAssertEqual(model.line(forModuleRange: 0x7A..<0x7A), 3, "inside the MOV")
        XCTAssertEqual(model.line(forModuleRange: 0x7E..<0x7E), 3,
                       "in the gap after it, the nearest one before")
        XCTAssertEqual(model.line(forModuleRange: 0x7E..<0x82), 4,
                       "a range from the gap reaches the RET")
        XCTAssertEqual(model.line(forModuleRange: 0x90..<0x90), 4)
        XCTAssertNil(model.line(forModuleRange: 0x10..<0x10), "before the code")
        XCTAssertEqual(model.moduleRange(ofFunction: 0), 0x68..<0x70)
    }

    /// A jump's target is written as the module offset the listing's first
    /// column shows; an immediate that is not a reference stays as it was.
    func testTargetsAreWrittenAsModuleOffsets() throws {
        let model = try model()
        let lines = model.lines
        XCTAssertEqual(model.displayText(of: lines[0].instruction), "JZ 0x6B")
        XCTAssertEqual(model.displayText(of: lines[2].instruction), "CALL 0x78")
        XCTAssertEqual(model.displayText(of: lines[1].instruction), "NOP")
        XCTAssertEqual(model.displayAddress(CodeAddress(0x220)), "0x68")
        XCTAssertEqual(model.displayAddress(CodeAddress(0x9000)), "0x9000",
                       "an address with no bytes keeps Ghidra's spelling")

        let unmapped = CodeModel(artifact: try artifact(), moduleBytes: nil)
        XCTAssertEqual(unmapped.displayText(of: lines[0].instruction), "JZ 0x00000223")
    }

    func testUsesNameTheInstructionsThatReferToAnAddress() throws {
        let model = try model()
        XCTAssertEqual(model.uses(of: CodeAddress(0x230)).map(\.from), [CodeAddress(0x223)])
        XCTAssertEqual(model.uses(of: CodeAddress(0x240)).map(\.function), [1])
        XCTAssertEqual(model.uses(of: CodeAddress(0x240)).first?.type, "DATA")
        XCTAssertTrue(model.uses(of: CodeAddress(0x222)).isEmpty)
    }

    func testAWideStringCoversTwoBytesACharacter() throws {
        let model = try model()
        let entry = try XCTUnwrap(model.artifact.strings.first)
        XCTAssertTrue(entry.isWide)
        XCTAssertEqual(model.moduleRange(of: entry), 0x88..<0x8E, "two characters and the terminator")
    }

    /// A TE image whose .text is at RVA 0x220 and file offset 0x68.
    static func teModule() -> Data {
        var data = Data(repeating: 0, count: 0x100)
        data[0] = 0x56
        data[1] = 0x5A
        write(&data, 2, 0x14C, 2)
        data[4] = 1
        data[5] = 0x0B
        write(&data, 6, 0x200, 2)
        write(&data, 8, 0x220, 4)
        write(&data, 12, 0x220, 4)
        let section = 40
        for (index, byte) in Array(".text".utf8).enumerated() {
            data[section + index] = byte
        }
        write(&data, section + 8, 0x40, 4)
        write(&data, section + 12, 0x220, 4)
        write(&data, section + 16, 0x40, 4)
        write(&data, section + 20, 0x240, 4)
        write(&data, section + 36, 0x6000_0020, 4)
        return data
    }

    private static func write(_ data: inout Data, _ offset: Int, _ value: UInt64, _ count: Int) {
        for index in 0..<count {
            data[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF)
        }
    }
}

/// A place in code as an annotation and `open_code` name it.
final class CodeLocationTests: XCTestCase {
    func testALocationIsFoundAsAFunctionAndAnInstruction() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":4,"functions":[
          {"entry":"0x10","name":"a","instructions":[{"address":"0x10","text":"NOP"},{"address":"0x11","text":"RET"}]},
          {"entry":"0x20","name":"b","instructions":[{"address":"0x20","text":"RET"}]}]}
        """.utf8))
        XCTAssertEqual(artifact.indices(of: CodeLocation(function: CodeAddress(0x20))).function, 1)
        XCTAssertNil(artifact.indices(of: CodeLocation(function: CodeAddress(0x20))).line)
        let instruction = artifact.indices(of: CodeLocation(address: CodeAddress(0x11)))
        XCTAssertEqual(instruction.function, 0, "the function holding the instruction")
        XCTAssertEqual(instruction.line, 1)
        XCTAssertEqual(artifact.indices(of: CodeLocation(function: CodeAddress(0x20), address: CodeAddress(0x20))).line, 2)
        XCTAssertNil(artifact.indices(of: CodeLocation(address: CodeAddress(0x99))).function)
        XCTAssertEqual(artifact.function(named: "b")?.entry, CodeAddress(0x20))
        XCTAssertEqual(artifact.function(named: "0x10")?.name, "a")
        XCTAssertEqual(artifact.function(containing: CodeAddress(0x11))?.name, "a")
    }
}
