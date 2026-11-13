import AgentKit
import Foundation
import XCTest
@testable import GhidraHost

/// The tools' compact answers: what an agent has not already got, and
/// `verbose` for the answer as the owner gives it. No Ghidra.
final class GhidraToolsCompactTests: XCTestCase {
    private func value(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    private let identity = #""module":"aa","project":"p","program":"M.efi","language":"x86:LE:64:default","image_base":"0x0""#

    func testTheIdentityGoesExceptWhereTheLanguageIsLearned() throws {
        let answer = try value("{\(identity),\"name\":\"X\"}")
        let compact = GhidraTools.compact(answer, tool: "ghidra_rename", arguments: [:])
        XCTAssertEqual(compact, try value(#"{"name":"X"}"#))
        let open = GhidraTools.compact(answer, tool: "ghidra_open", arguments: [:])
        XCTAssertEqual(open, try value(#"{"name":"X","language":"x86:LE:64:default"}"#))
        // A `module` that is not the owner's identity stays.
        let proposal = try value(#"{"module":"bb","state":"open"}"#)
        XCTAssertEqual(GhidraTools.compact(proposal, tool: "ghidra_rename", arguments: [:]), proposal)
    }

    func testSettledProposalsAreLeftOutOrShort() throws {
        let list = try value("""
            [{"id":"1","state":"open","names":["A"],"reason":"long","votes":[]},
             {"id":"2","state":"applied","names":["B"],"reason":"long","votes":[],"decided":"t","author":"x","origins":[]},
             {"id":"3","state":"agreed","names":["C"],"reason":"long"}]
            """)
        let live = GhidraTools.compact(list, tool: "ghidra_type_proposals", arguments: [:])
        XCTAssertEqual(live.arrayValue?.compactMap { $0["id"]?.stringValue }, ["1", "3"])
        XCTAssertEqual(live.arrayValue?.first?["reason"]?.stringValue, "long")
        let all = GhidraTools.compact(list, tool: "ghidra_type_proposals", arguments: ["state": .string("applied")])
        XCTAssertEqual(all.arrayValue?[1], try value(#"{"id":"2","state":"applied","names":["B"],"decided":"t","author":"x"}"#))
    }

    func testAFunctionsCommentsAreOnlyThoseItsCDoesNotPrint() throws {
        let answer = try value("""
            {"c":"/* The plate.\\n   Second line. */\\nvoid F(void)\\n{\\n  /* Read the header, wrapped by the\\n     decompiler. */\\n  x = 1;\\n}\\n",
             "plate":"The plate.\\nSecond line.",
             "comments":[{"address":"0x10","kind":"plate","text":"The plate.\\nSecond line."},
                         {"address":"0x12","kind":"pre","text":"Read the header, wrapped by the decompiler."},
                         {"address":"0x20","kind":"eol","text":"Not printed anywhere."}]}
            """)
        let compact = GhidraTools.compact(answer, tool: "ghidra_function", arguments: [:])
        XCTAssertEqual(compact["plate"]?.stringValue, "The plate.\nSecond line.")
        XCTAssertEqual(compact["comments"]?.arrayValue?.compactMap { $0["address"]?.stringValue }, ["0x20"])
    }

    func testAnInstructionKeepsOnlyWhatItsRowDoesNotSay() throws {
        let answer = try value("""
            {"entry":"0x2508","instructions":[
              {"address":"0x2508","bytes":"4C 89","text":"MOV","references":[]},
              {"address":"0x2530","bytes":"4C 8B","text":"MOV R9",
               "references":[{"from":"0x2530","function":"0x2508","to":"0x11820","type":"READ"},
                             {"from":"0x2530","function":"0x3000","to":"0x3000","type":"CALL"}]}]}
            """)
        let compact = GhidraTools.compact(answer, tool: "ghidra_disassembly", arguments: [:])
        let rows = try XCTUnwrap(compact["instructions"]?.arrayValue)
        XCTAssertNil(rows[0]["references"])
        XCTAssertEqual(rows[0]["bytes"]?.stringValue, "4C 89")
        XCTAssertEqual(rows[1]["references"], try value(#"[{"to":"0x11820","type":"READ"},{"function":"0x3000","to":"0x3000","type":"CALL"}]"#))
    }

    /// The tool takes `verbose`, passes it on to nobody, and answers in full with it.
    func testVerboseAnswersAsTheOwnerDoes() async throws {
        let full = try value("{\(identity),\"instructions\":[{\"address\":\"0x1\",\"references\":[]}],\"entry\":\"0x1\"}")
        let tool = AgentTool(name: "ghidra_disassembly", description: "Reads.",
                             inputSchema: AgentSchema.object(["address": AgentSchema.string("At.")])) { call in
            XCTAssertNil(call.arguments.values["verbose"])
            return .json(full)
        }
        let compacted = GhidraTools.compacted(tool)
        let verbose = try await compacted.run(AgentCall(tool: tool.name, arguments: AgentArguments(["verbose": .bool(true)])))
        XCTAssertEqual(verbose, .json(full))
        let short = try await compacted.run(AgentCall(tool: tool.name, arguments: AgentArguments([:])))
        XCTAssertEqual(short, .json(try value(#"{"instructions":[{"address":"0x1"}],"entry":"0x1"}"#)))
    }
}
