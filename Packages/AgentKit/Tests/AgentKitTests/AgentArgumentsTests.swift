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
}
