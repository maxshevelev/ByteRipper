import Foundation
import XCTest
@testable import CodeAnalysis

/// What a name in the code stands for: a constant a review named, a type the
/// C names, a field of a structure — with the review's words for it.
final class CodeExplanationTests: XCTestCase {
    private let c = "void ResetEntry(SEC_SERIAL_DEVICE_INFO *Info)\n{\n  out(PCI_CONFIG_ADDRESS,Info->BaudRate);\n}\n"

    private func model() throws -> CodeModel {
        func at(_ word: String) -> Int { (c as NSString).range(of: word).location }
        let spans = """
        [[\(at("SEC_SERIAL_DEVICE_INFO")), 22, "type"], [\(at("PCI_CONFIG_ADDRESS")), 18, "constant"], \
        [\(at("Info->")), 4, "parameter"]]
        """
        let fields = #"[[\#(at("BaudRate")), 8, "SEC_SERIAL_DEVICE_INFO", 4]]"#
        let structC = "struct SEC_SERIAL_DEVICE_INFO {\n    /* 0x00 */ UINT32 Base; // I/O base of the UART\n"
            + "    /* 0x04 */ UINT32 BaudRate; // bits per second, 115200 on this board\n} /* size 0x8 */;"
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [[
                "entry": "0x100", "name": "ResetEntry", "c": c,
                "c_spans": try JSONSerialization.jsonObject(with: Data(spans.utf8)),
                "c_fields": try JSONSerialization.jsonObject(with: Data(fields.utf8)),
                "instructions": [
                    ["address": "0x100", "bytes": "66 BA F8 0C", "mnemonic": "MOV", "text": "MOV DX,0xcf8"],
                    ["address": "0x104", "bytes": "66 EF", "mnemonic": "OUT", "text": "OUT DX,EAX"],
                    ["address": "0x106", "bytes": "B0 01", "mnemonic": "MOV", "text": "MOV AL,0x1"]
                ]
            ]],
            "equates": [
                ["name": "PCI_CONFIG_ADDRESS", "value": "0xCF8", "enum": "FCH_IO_PORT",
                 "comment": "PCI configuration address port. Source: PCI Local Bus Spec 3.0",
                 "references": [["0x100", 1]]],
                ["name": "LEGACY_IO_EN", "value": "0x1", "enum": NSNull(), "comment": NSNull(),
                 "references": [["0x106", 1]]]
            ],
            "types": [
                ["name": "SEC_SERIAL_DEVICE_INFO", "path": "/ByteRipper/SEC_SERIAL_DEVICE_INFO",
                 "kind": "struct", "size": 8, "description": "The UART SEC reports through.", "c": structC]
            ]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        return CodeModel(artifact: artifact, layout: nil)
    }

    private func token(_ model: CodeModel, _ word: String) throws -> CodeToken {
        let tokens = model.cTokens(ofFunction: 0)
        return try XCTUnwrap(tokens.first { CodeModel.slice(c, $0.start, $0.length) == word })
    }

    func testAConstantANameStandsForExplainsItself() throws {
        let model = try model()
        let explained = try XCTUnwrap(model.explanation(ofC: token(model, "PCI_CONFIG_ADDRESS"), inFunction: 0))
        XCTAssertEqual(explained.subject, .constant(name: "PCI_CONFIG_ADDRESS", value: 0xCF8))
        XCTAssertEqual(explained.enumName, "FCH_IO_PORT")
        XCTAssertEqual(CodeModel.number(0xCF8), "0xCF8 = 3320")
        XCTAssertEqual(CodeModel.number(1), "0x1")
        XCTAssertEqual(explained.text, "PCI configuration address port. Source: PCI Local Bus Spec 3.0")
        XCTAssertEqual(explained.uses.map(\.address), [CodeAddress(0x100)])
        XCTAssertNil(explained.c)
    }

    func testTheListingsNumberIsTheSameName() throws {
        let model = try model()
        XCTAssertEqual(model.explanation(ofConstant: 0xCF8, onLine: 0)?.name, "PCI_CONFIG_ADDRESS")
        XCTAssertNil(model.explanation(ofConstant: 0xCF8, onLine: 1), "the OUT holds no constant")
        let bare = try XCTUnwrap(model.explanation(ofConstant: 1, onLine: 2))
        XCTAssertNil(bare.enumName, "a bare name has its value and no enum")
        XCTAssertNil(bare.text)
    }

    func testATypeShowsItsC() throws {
        let model = try model()
        let explained = try XCTUnwrap(model.explanation(ofC: token(model, "SEC_SERIAL_DEVICE_INFO"), inFunction: 0))
        XCTAssertEqual(explained.kind, "struct")
        XCTAssertEqual(explained.size, 8)
        XCTAssertEqual(explained.text, "The UART SEC reports through.")
        XCTAssertTrue(explained.c?.contains("UINT32 BaudRate;") ?? false)
        XCTAssertNil(model.explanation(ofC: try token(model, "Info"), inFunction: 0), "a parameter is not explained")
    }

    func testAFieldShowsItsLineAndComment() throws {
        let model = try model()
        let at = (c as NSString).range(of: "BaudRate").location
        let field = try XCTUnwrap(model.field(atC: at + 3, inFunction: 0))
        let explained = try XCTUnwrap(model.explanation(ofField: field, inFunction: 0))
        XCTAssertEqual(explained.name, "SEC_SERIAL_DEVICE_INFO.BaudRate")
        XCTAssertEqual(explained.declaration, "UINT32 BaudRate")
        XCTAssertEqual(explained.subject, .field(type: "SEC_SERIAL_DEVICE_INFO", offset: 4))
        XCTAssertEqual(explained.text, "bits per second, 115200 on this board")
        XCTAssertNil(model.field(atC: at - 3, inFunction: 0))
    }

    /// The decompiler's warnings for removed blocks, folded into one line,
    /// open the list of the blocks, each a way to its instructions.
    func testTheRemovedBlocksLineListsTheBlocks() throws {
        let c = "void Entry(void)\n{\n  /* WARNING: Removing 2 unreachable blocks */\n  return;\n}\n"
        let at = (c as NSString).range(of: "/* WARNING: Removing 2 unreachable blocks */")
        let json: [String: Any] = [
            "script_version": 5,
            "functions": [[
                "entry": "0x100", "name": "Entry", "c": c,
                "c_spans": [[at.location, at.length, "comment"]],
                "c_unreachable": [at.location, at.length, ["0x106", "0x102"]],
                "instructions": [
                    ["address": "0x100", "bytes": "90", "mnemonic": "NOP", "text": "NOP"],
                    ["address": "0x102", "bytes": "90", "mnemonic": "NOP", "text": "NOP"],
                    ["address": "0x106", "bytes": "C3", "mnemonic": "RET", "text": "RET"]
                ]
            ]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let model = CodeModel(artifact: artifact, layout: nil)
        let line = try XCTUnwrap(model.cTokens(ofFunction: 0).first { $0.kind == .comment })
        let explained = try XCTUnwrap(model.explanation(ofC: line, inFunction: 0))
        XCTAssertEqual(explained.subject, .unreachable(blocks: 2))
        XCTAssertEqual(explained.uses.map(\.address), [CodeAddress(0x102), CodeAddress(0x106)], "in address order")
        XCTAssertEqual(explained.uses.map(\.line), [1, 2])
        XCTAssertNil(model.explanation(ofC: CodeToken(start: 0, length: 4, kind: .comment), inFunction: 0),
                     "another comment explains nothing")
    }

    func testAnArtifactWithoutThemStillReads() throws {
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data(#"{"script_version":5,"functions":[]}"#.utf8))
        XCTAssertEqual(artifact.equates, [])
        XCTAssertEqual(artifact.types, [])
    }
}
