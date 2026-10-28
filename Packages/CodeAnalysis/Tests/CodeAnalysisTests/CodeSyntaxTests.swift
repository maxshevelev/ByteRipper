import Foundation
import XCTest
@testable import CodeAnalysis

/// The tokens a line of code is coloured and followed by: a call is a link to
/// its function whether the artifact says so (v4 spans) or the lexer finds it
/// by name (v2, v3).
final class CodeSyntaxTests: XCTestCase {
    private func model(version: Int, spans: String = "") throws -> CodeModel {
        let c = #"void FUN_00000220(void)\n{\n  /* note */\n  gBS = 0;\n  entry(\"x\", DAT_00000240);\n}\n"#
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":\(version),"program":{"image_base":"0x0"},
         "symbols":[{"address":"0x240","name":"gBS","type":"EFI_BOOT_SERVICES *","source":"ANALYSIS",
                     "reason":"written from a EFI_BOOT_SERVICES* value"}],
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","name_source":"DEFAULT","c":"\(c)"\(spans),
           "instructions":[
            {"address":"0x220","bytes":"E8 00 00 00 00","mnemonic":"CALL","text":"CALL 0x00000230",
             "references":[{"to":"0x230","type":"UNCONDITIONAL_CALL"}]},
            {"address":"0x225","bytes":"74 01","mnemonic":"JZ","text":"JZ 0x00000220",
             "references":[{"to":"0x220","type":"CONDITIONAL_JUMP"}]},
            {"address":"0x227","bytes":"8B 05 00 00 00 00","mnemonic":"MOV","text":"MOV EAX,dword ptr [0x00000240]",
             "references":[{"to":"0x240","type":"READ"}]}]},
          {"entry":"0x230","name":"entry","name_source":"ANALYSIS","name_reason":"the entry point",
           "c":"void entry(void)\\n{\\n  return;\\n}\\n",
           "instructions":[{"address":"0x230","bytes":"C3","mnemonic":"RET","text":"RET"}]}]}
        """.utf8))
        return CodeModel(artifact: artifact, moduleBytes: CodeModelTests.teModule())
    }

    private func text(_ model: CodeModel, _ token: CodeToken) -> String {
        let c = model.functions[0].c ?? ""
        let units = Array(c.utf16)[token.start..<token.start + token.length]
        return String(decoding: units, as: UTF16.self)
    }

    func testTheLexerLinksCallsAndGhidraAddresses() throws {
        let model = try model(version: 3)
        let tokens = model.cTokens(ofFunction: 0)
        func token(_ word: String) -> CodeToken? { tokens.first { text(model, $0) == word } }
        XCTAssertEqual(token("void")?.kind, .type)
        XCTAssertEqual(token("/* note */")?.kind, .comment)
        XCTAssertEqual(token("\"x\"")?.kind, .string)
        XCTAssertEqual(token("0")?.kind, .constant)
        XCTAssertEqual(token("entry")?.link, .function(1), "a call by name leads to its function")
        XCTAssertEqual(token("FUN_00000220")?.link, .function(0))
        XCTAssertEqual(token("DAT_00000240")?.link, .bytes(CodeAddress(0x240)),
                       "Ghidra's address spelling leads to the bytes")
    }

    /// A v4 artifact's spans say what each token is; the lexer is not asked.
    func testSpansDecideWhenTheArtifactHasThem() throws {
        // "gBS" starts at 41: the signature (23) and "\n{\n" (3), then
        // "  /* note */\n" (13) and two spaces.
        let model = try model(version: 4, spans: #","c_spans":[[41,3,"global","0x240"],[52,5,"function","0x230"],[0,4,"type"],[9,99,"local"]]"#)
        let tokens = model.cTokens(ofFunction: 0)
        XCTAssertEqual(tokens.map(\.kind), [.global, .function, .type],
                       "a span past the end of the text is dropped")
        XCTAssertEqual(text(model, tokens[0]), "gBS")
        XCTAssertEqual(tokens[0].link, .bytes(CodeAddress(0x240)))
        XCTAssertEqual(tokens[1].link, .function(1))
        XCTAssertEqual(model.artifact.symbols.first?.name, "gBS")
        XCTAssertTrue(model.functions[0].hasPlaceholderName)
        XCTAssertEqual(model.functions[1].nameReason, "the entry point")
        XCTAssertFalse(model.functions[1].hasPlaceholderName)
    }

    /// A listing row's targets are links: a call to its function, a jump to
    /// its instruction, a read to its bytes.
    func testAListingRowLinksItsTargets() throws {
        let model = try model(version: 3)
        func targets(_ line: Int) -> [(String, CodeLink?)] {
            let row = model.listingRow(ofLine: line)
            let units = Array(row.text.utf16)
            return row.tokens.filter { $0.link != nil }.map {
                (String(decoding: units[$0.start..<$0.start + $0.length], as: UTF16.self), $0.link)
            }
        }
        XCTAssertEqual(targets(0).map(\.0), ["0x78"])
        XCTAssertEqual(targets(0).first?.1, .function(1))
        XCTAssertEqual(targets(1).first?.1, .function(0), "a jump to an entry leads to the function")
        XCTAssertEqual(targets(2).first?.1, .bytes(CodeAddress(0x240)))
        let row = model.listingRow(ofLine: 0)
        XCTAssertTrue(row.text.hasPrefix("0x68"))
        XCTAssertEqual(row.tokens.first { $0.kind == .mnemonic }.map {
            String(decoding: Array(row.text.utf16)[$0.start..<$0.start + $0.length], as: UTF16.self)
        }, "CALL")
    }

    func testAJumpInsideAFunctionLeadsToTheInstruction() throws {
        let model = try model(version: 3)
        XCTAssertEqual(model.link(to: CodeAddress(0x225)), .line(1))
        XCTAssertEqual(model.link(to: CodeAddress(0x230)), .function(1))
        XCTAssertNil(model.link(to: CodeAddress(0x9000)), "outside the module")
    }

    /// A `goto` leads to its label, whatever the label is called: Ghidra's
    /// `LAB_` spelling or a name the review gave it. The decompiler marks no
    /// label, so they are read off the text; one in a comment is not one,
    /// and `default:` is a keyword.
    func testAGotoLeadsToItsLabelByName() throws {
        let c = "void F(int x)\n{\n  /* goto Skip; */\n  if (x) goto LAB_00000225;\n  goto Done;\n"
            + "  switch (x) {\n  default:\n    break;\n  }\nLAB_00000225:\n  x = 1;\nDone:\n  return;\n}\n"
        let text = c as NSString
        let comment = text.range(of: "/* goto Skip; */")
        let json: [String: Any] = [
            "script_version": 5, "program": ["image_base": "0x0"],
            "functions": [["entry": "0x220", "name": "F", "c": c,
                           "c_spans": [[comment.location, comment.length, "comment"]],
                           "instructions": [["address": "0x220", "bytes": "90", "mnemonic": "NOP", "text": "NOP"]]]]
        ]
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        let model = CodeModel(artifact: artifact, moduleBytes: nil)
        let labels = model.cTokens(ofFunction: 0).filter { $0.kind == .label }
        let shown = labels.map { (text.substring(with: NSRange(location: $0.start, length: $0.length)), $0.link) }
        XCTAssertEqual(shown.map(\.0), ["LAB_00000225", "Done", "LAB_00000225", "Done"],
                       "two gotos and two definitions, in reading order")
        XCTAssertEqual(shown.map(\.1), [.label("LAB_00000225"), .label("Done"), nil, nil],
                       "a goto links to its label; the definition links nowhere")
    }
}
