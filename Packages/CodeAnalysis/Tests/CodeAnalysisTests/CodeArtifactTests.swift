import Foundation
import XCTest
@testable import CodeAnalysis

/// The typed artifact reader: what `ExportCode.java` writes is read as
/// functions, instructions and addresses; what it does not write is defaulted
/// rather than guessed at, and an unknown exporter version is refused.
final class CodeArtifactTests: XCTestCase {
    private func decoded(_ json: String) throws -> CodeArtifact {
        try JSONDecoder().decode(CodeArtifact.self, from: Data(json.utf8))
    }

    // MARK: - The Python-side fixture

    /// The artifact in the bundle was written by the Python side. It is
    /// deliberately sparse — no program, no instruction bytes — and still has
    /// to read as a v2 artifact.
    func testThePythonFixtureDecodes() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "bundle", withExtension: "zip", subdirectory: "Fixtures"))
        let entries = try BundleArchive.read(from: url)
        let key = try XCTUnwrap(entries.keys.first { $0.hasPrefix("objects/") })
        let object = try XCTUnwrap(entries[key])
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: object)

        XCTAssertEqual(artifact.scriptVersion, 2)
        XCTAssertEqual(artifact.ghidra, "12.1.2")
        XCTAssertNil(artifact.program)
        XCTAssertTrue(artifact.blocks.isEmpty)
        XCTAssertEqual(artifact.functions.count, 2)
        XCTAssertEqual(artifact.functions.map(\.instructions.count), [2, 1])
        XCTAssertEqual(artifact.strings.count, 1)
        XCTAssertEqual(artifact.postCodes.count, 1)
        XCTAssertEqual(artifact.statusCodeCalls.count, 1)
        XCTAssertEqual(artifact.functions[0].instructions[0].bytes, [])
    }

    // MARK: - The full shape

    func testAFullArtifactKeepsItsProgramBytesAndReferences() throws {
        let artifact = try decoded(Self.fullArtifact)

        XCTAssertEqual(artifact.scriptVersion, 2)
        XCTAssertEqual(artifact.ghidra, "12.1.2")
        let program = try XCTUnwrap(artifact.program)
        XCTAssertEqual(program.name, "CpuPei")
        XCTAssertEqual(program.language, "x86:LE:32:default")
        XCTAssertEqual(program.imageBase, CodeAddress(0x1000_0000))
        XCTAssertEqual(program.sha256, String(repeating: "a", count: 64))

        let block = try XCTUnwrap(artifact.blocks.first)
        XCTAssertEqual(block.name, ".text")
        XCTAssertEqual(block.start, CodeAddress(0x1000_1000))
        XCTAssertEqual(block.end, CodeAddress(0x1000_100F))
        XCTAssertTrue(block.executable)
        XCTAssertTrue(block.initialized)

        let function = try XCTUnwrap(artifact.functions.first)
        XCTAssertEqual(function.entry, CodeAddress(0x1000_1000))
        XCTAssertEqual(function.name, "FUN_10001000")
        XCTAssertEqual(function.size, 8)
        XCTAssertEqual(function.signature, "undefined4 FUN_10001000(void)")
        XCTAssertFalse(function.external)
        XCTAssertFalse(function.thunk)
        XCTAssertEqual(function.callers, [CodeAddress(0x1000_2000)])
        XCTAssertEqual(function.callees, [CodeAddress(0x1000_3000)])
        XCTAssertEqual(function.c, "return 0;")

        let instruction = try XCTUnwrap(function.instructions.first)
        XCTAssertEqual(instruction.address, CodeAddress(0x1000_1000))
        XCTAssertEqual(instruction.bytes, [0x55, 0x8B, 0xEC])
        XCTAssertEqual(instruction.mnemonic, "PUSH")
        XCTAssertEqual(instruction.text, "PUSH EBP")
        XCTAssertEqual(instruction.flow, "FALL_THROUGH")
        XCTAssertEqual(instruction.references.first?.to, CodeAddress(0x1000_1001))
        XCTAssertEqual(instruction.references.first?.type, "FLOW")

        let postCode = try XCTUnwrap(artifact.postCodes.first)
        XCTAssertEqual(postCode.address, CodeAddress(0x1000_1002))
        XCTAssertEqual(postCode.function, CodeAddress(0x1000_1000))
        XCTAssertEqual(postCode.port, "0x80")

        let status = try XCTUnwrap(artifact.statusCodeCalls.first)
        XCTAssertEqual(status.address, CodeAddress(0x1000_1003))
        XCTAssertEqual(status.context, ["PUSH 0x11004"])
    }

    func testUnknownFieldsAreIgnored() throws {
        let artifact = try decoded(Self.fullArtifact)
        XCTAssertEqual(artifact.functions.count, 1)
        XCTAssertEqual(artifact.functions[0].name, "FUN_10001000")
    }

    // MARK: - Refusals

    func testAnUnknownScriptVersionIsRefused() {
        let json = #"{"script_version": 5, "ghidra": "12.1.2", "functions": []}"#
        XCTAssertThrowsError(try decoded(json)) { error in
            XCTAssertEqual(error as? CodeArtifactError, .unsupportedVersion(5))
        }
    }

    // MARK: - Status-code candidates

    /// `[reg + 0x58]` is ReportStatusCode only in the 32-bit PEI services
    /// table. A v2 artifact of a 64-bit image listed SetTimer and SetVariable
    /// calls under that name; the reader drops them. v3 does not write them.
    func testAV2SixtyFourBitImageHasNoStatusCodeCandidates() throws {
        func artifact(version: Int, language: String) throws -> CodeArtifact {
            try decoded("""
            {"script_version":\(version),"program":{"language":"\(language)"},
             "status_code_calls":[{"address":"0x10A5","text":"CALL qword ptr [RAX + 0x58]"}]}
            """)
        }
        XCTAssertTrue(try artifact(version: 2, language: "x86:LE:64:default").statusCodeCalls.isEmpty)
        XCTAssertEqual(try artifact(version: 2, language: "x86:LE:32:default").statusCodeCalls.count, 1)
        XCTAssertEqual(try artifact(version: 3, language: "x86:LE:64:default").statusCodeCalls.count, 1,
                       "a v3 exporter's list is its own decision")
    }

    func testAMalformedAddressIsRefused() {
        let json = """
        {"script_version":2,"functions":[
          {"entry":"0x10","name":"F","instructions":[
            {"address":"not-an-address","text":"RET"}]}]}
        """
        XCTAssertThrowsError(try decoded(json))
    }

    func testAMalformedInstructionByteStringIsRefused() {
        let json = """
        {"script_version":2,"functions":[
          {"entry":"0x10","name":"F","instructions":[
            {"address":"0x10","bytes":"55 ZZ EC","text":"PUSH EBP"}]}]}
        """
        XCTAssertThrowsError(try decoded(json))
    }

    // MARK: - CodeAddress

    func testAnAddressIsSpelledTheWayGhidraSpellsIt() {
        XCTAssertEqual(CodeAddress(hex: "0x4bf"), CodeAddress(0x4BF))
        XCTAssertEqual(CodeAddress(hex: "4BF"), CodeAddress(0x4BF))
        XCTAssertEqual(CodeAddress(hex: "0x4BF")?.description, "0x4BF")
        XCTAssertNil(CodeAddress(hex: ""))
        XCTAssertNil(CodeAddress(hex: "0x"))
        XCTAssertNil(CodeAddress(hex: "0xGG"))
        XCTAssertNil(CodeAddress(hex: "0x1_0000_0000_0000_0000"))
    }

    // MARK: - Fixture

    private static let fullArtifact = """
    {
      "script_version": 2,
      "ghidra": "12.1.2",
      "program": {
        "name": "CpuPei",
        "language": "x86:LE:32:default",
        "image_base": "0x10000000",
        "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      "blocks": [
        {"name": ".text", "start": "0x10001000", "end": "0x1000100F",
         "executable": true, "initialized": true}
      ],
      "strings": [
        {"address": "0x10002000", "type": "string", "value": "fixture"}
      ],
      "functions": [
        {
          "entry": "0x10001000",
          "name": "FUN_10001000",
          "size": 8,
          "signature": "undefined4 FUN_10001000(void)",
          "external": false,
          "thunk": false,
          "callers": ["0x10002000"],
          "callees": ["0x10003000"],
          "c": "return 0;",
          "instructions": [
            {"address": "0x10001000", "bytes": "55 8B EC",
             "mnemonic": "PUSH", "text": "PUSH EBP", "flow": "FALL_THROUGH",
             "references": [{"to": "0x10001001", "type": "FLOW"}]},
            {"address": "0x10001001", "bytes": "8B EC",
             "mnemonic": "MOV", "text": "MOV EBP,ESP", "flow": "FALL_THROUGH",
             "references": []}
          ]
        }
      ],
      "post_codes": [
        {"address": "0x10001002", "function": "0x10001000",
         "port": "0x80", "text": "OUT 0x80,AL"}
      ],
      "status_code_calls": [
        {"address": "0x10001003", "function": "0x10001000",
         "text": "CALL dword ptr [ECX + 0x58]", "context": ["PUSH 0x11004"]}
      ],
      "future_field": {"ignored": true}
    }
    """
}
