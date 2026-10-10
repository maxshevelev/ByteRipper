import XCTest
@testable import AgentKit

final class AgentArgumentsTests: XCTestCase {
    private func message(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as AgentToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    func testAnOffsetIsTakenAsAnIntegerOrAsHexOrDecimalText() throws {
        let arguments = AgentArguments(["a": 4096, "b": "0x7F3000", "c": "0X10", "d": "1234", "e": "0x7F_3000"])
        XCTAssertEqual(try arguments.offset("a"), 4096)
        XCTAssertEqual(try arguments.offset("b"), 0x7F3000)
        XCTAssertEqual(try arguments.offset("c"), 16)
        XCTAssertEqual(try arguments.offset("d"), 1234)
        XCTAssertEqual(try arguments.offset("e"), 0x7F3000)
    }

    func testABadOffsetSaysWhatWasExpected() {
        let arguments = AgentArguments(["neg": -1, "word": "lots", "flag": true])
        XCTAssertEqual(message { _ = try arguments.offset("neg") }, "Argument `neg`: must not be negative.")
        XCTAssertEqual(message { _ = try arguments.offset("word") },
                       #"Argument `word`: expected an integer, or a string such as "0x7F3000"."#)
        XCTAssertNotNil(message { _ = try arguments.offset("flag") })
        XCTAssertEqual(message { _ = try arguments.offset("none") }, "Argument `none` is required.")
    }

    /// A null is how some clients write an argument they did not mean to give.
    func testANullArgumentIsAnAbsentOne() throws {
        let arguments = AgentArguments(["path": nil])
        XCTAssertFalse(arguments.has("path"))
        XCTAssertNil(try arguments.optionalString("path"))
    }

    func testTheLimitIsClampedAndDefaults() throws {
        XCTAssertEqual(try AgentArguments([:]).limit(default: 50, maximum: 200), 50)
        XCTAssertEqual(try AgentArguments(["limit": 1000]).limit(default: 50, maximum: 200), 200)
        XCTAssertEqual(try AgentArguments(["limit": 0]).limit(default: 50, maximum: 200), 1)
        XCTAssertEqual(try AgentArguments(["limit": 7]).limit(default: 50, maximum: 200), 7)
    }

    func testAChoiceOutsideTheSetIsRefusedByName() {
        let arguments = AgentArguments(["format": "octal"])
        XCTAssertEqual(message { _ = try arguments.choice("format", from: ["hex", "ascii"]) },
                       #"Argument `format`: expected one of hex, ascii, got "octal"."#)
        XCTAssertEqual(try AgentArguments([:]).choice("format", from: ["hex", "ascii"], default: "hex"), "hex")
    }

    func testAListOfStringsIsReadOrRefusedByName() throws {
        XCTAssertEqual(try AgentArguments(["ids": ["m1", "m2"]]).strings("ids"), ["m1", "m2"])
        XCTAssertEqual(try AgentArguments([:]).strings("ids"), [])
        XCTAssertEqual(message { _ = try AgentArguments(["ids": [1]]).strings("ids") },
                       "Argument `ids`: expected a list of strings.")
    }

    func testABooleanDefaultsWhenAbsent() throws {
        XCTAssertTrue(try AgentArguments([:]).bool("select", default: true))
        XCTAssertFalse(try AgentArguments(["select": false]).bool("select", default: true))
        XCTAssertNotNil(message { _ = try AgentArguments(["select": "no"]).bool("select", default: true) })
    }

    func testTheSchemaOfAnObjectAllowsNothingElse() {
        let schema = AgentSchema.object(["path": AgentSchema.string("A file.")], required: ["path"])
        XCTAssertEqual(schema["additionalProperties"], false)
        XCTAssertEqual(schema["required"], ["path"])
        XCTAssertEqual(schema["properties"]?["path"]?["type"], "string")
    }

    // MARK: Arguments a tool does not take

    private let openPart = AgentTool(
        name: "open_part",
        description: "Opens a part.",
        inputSchema: AgentSchema.object([
            "node": AgentSchema.string("A node."),
            "offset": AgentSchema.offset("Where."),
            "part": AgentSchema.choice(["all", "body", "decoded"], "Which bytes.")
        ])
    ) { _ in .text("opened") }

    private func refusal(_ tool: AgentTool, _ arguments: [String: JSONValue]) async -> String? {
        do {
            _ = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(arguments)))
            return nil
        } catch let error as AgentToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// The case that opened a LENV block still encoded: `decoded` is a value
    /// of `part`, and the refusal says so.
    func testAnArgumentThatIsAValueOfAnotherIsRefusedWithWhatWasMeant() async {
        let message = await refusal(openPart, ["node": "0.3.4.1.2", "decoded": true])
        XCTAssertEqual(message, "`open_part` takes no argument `decoded`. Perhaps `part: \"decoded\"`. "
            + "It takes: node, offset, part.")
    }

    func testAMisspeltArgumentIsRefusedWithTheNearestName() async {
        let message = await refusal(openPart, ["ofset": "0x10"])
        XCTAssertEqual(message, "`open_part` takes no argument `ofset`. Perhaps `offset`. It takes: node, offset, part.")
        let unrelated = await refusal(openPart, ["colour": "red"])
        XCTAssertEqual(unrelated, "`open_part` takes no argument `colour`. It takes: node, offset, part.")
    }

    func testTheArgumentsAToolTakesAreLetThrough() async {
        let answered = await refusal(openPart, ["node": "0.1", "part": "decoded"])
        XCTAssertNil(answered)
        let bare = AgentTool(name: "documents", description: "Lists.") { _ in .text("none") }
        let message = await refusal(bare, ["limit": 5])
        XCTAssertEqual(message, "`documents` takes no argument `limit`. It takes no arguments.")
    }
}
