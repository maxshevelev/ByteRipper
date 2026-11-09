import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A write that changes more than it was asked to says so, or is refused:
/// a redecode keeps the equates on the instructions it decodes again; an
/// enum member does not take over a plain equate of another value; set_data
/// neither renames a function nor clears data without a word; a type still
/// used is not deleted. Each test makes its own project from
/// `GHIDRA_TYPE_MODULE`, a 32-bit PEI module, in a temporary folder.
final class GhidraOwnerSilentWritesTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerSilentWrites-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerSilentWritesTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
    }

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func read(_ path: String) async throws -> [String: Any] {
        let data = try await host.read(module, path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @discardableResult
    private func post(_ path: String, _ object: [String: Any]) async throws -> [String: Any] {
        try await host.take(module)
        let data = try await host.write(module, path, body: try JSONSerialization.data(withJSONObject: object))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func refused(_ path: String, _ object: [String: Any], saying words: String,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let answer = try await post(path, object)
            XCTFail("not refused: \(answer)", file: file, line: line)
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)", file: file, line: line)
            XCTAssertTrue("\(error)".contains(words), "\(error)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    private func entries() async throws -> [String] {
        (try await read("/v1/functions")["functions"] as? [[String: Any]] ?? []).compactMap { $0["entry"] as? String }
    }

    private func instructions(_ entry: String) async throws -> [[String: Any]] {
        try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
    }

    /// The equate names on the instruction at `address`.
    private func equates(at address: String) async throws -> [String] {
        let code = try await instructions(address)
        let instruction = code.first { ($0["address"] as? String)?.lowercased() == address.lowercased() }
        return (instruction?["equates"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// `MOV reg,imm` instructions with the address of the one after each, and the immediate.
    private func immediates(_ count: Int) async throws -> [(at: String, next: String, value: String)] {
        var found: [(String, String, String)] = []
        var values = Set<String>()
        for entry in try await entries() {
            let code = try await instructions(entry)
            for (index, instruction) in code.enumerated() where index + 1 < code.count {
                let text = instruction["text"] as? String ?? ""
                guard text.hasPrefix("MOV"),
                      let range = text.range(of: #"0x[0-9a-f]{3,}$"#, options: .regularExpression),
                      !values.contains(String(text[range])),
                      let at = instruction["address"] as? String,
                      let next = code[index + 1]["address"] as? String else { continue }
                values.insert(String(text[range]))
                found.append((at, next, String(text[range])))
                if found.count == count { return found }
            }
        }
        throw XCTSkip("too few MOV immediates")
    }

    func testARedecodeKeepsTheEquatesOnTheInstructionsItDecodesAgain() async throws {
        let place = try await immediates(1)[0]
        _ = try await post("/v1/set/equate", ["address": place.at, "operand": 1, "name": "SILENT_KEPT"])
        let set = try await equates(at: place.at)
        XCTAssertEqual(set, ["SILENT_KEPT"], "the equate is there before")
        let answer = try await post("/v1/redecode", ["start": place.at, "end": place.next])
        XCTAssertNil(answer["marks_lost"], "\(answer)")
        let names = try await equates(at: place.at)
        XCTAssertEqual(names, ["SILENT_KEPT"])
    }

    func testAnEnumMemberDoesNotTakeOverAPlainEquateOfAnotherValue() async throws {
        let places = try await immediates(2)
        _ = try await post("/v1/set/equate", ["address": places[0].at, "operand": 1, "name": "SILENT_PLAIN"])
        await refused("/v1/set/equate", ["address": places[1].at, "operand": 1, "name": "SILENT_PLAIN",
                                         "enum": "SILENT_ENUM"],
                      saying: "already stands for")
        let names = try await equates(at: places[0].at)
        XCTAssertEqual(names, ["SILENT_PLAIN"], "the plain equate stays where it was")
    }

    func testSetDataRefusesAFunctionsEntryAndSaysWhatItClears() async throws {
        let all = try await entries()
        let entry = try XCTUnwrap(all.first)
        let before = try await read("/v1/function/\(entry)")["name"] as? String
        await refused("/v1/set/data", ["address": entry, "name": "SilentLabel"], saying: "ghidra_rename")
        let after = try await read("/v1/function/\(entry)")["name"] as? String
        XCTAssertEqual(after, before, "the function keeps its name")

        let data = try await read("/v1/data")
        let rows = data["data"] as? [[String: Any]] ?? data["items"] as? [[String: Any]] ?? []
        for row in rows {
            guard let text = row["address"] as? String, let at = UInt64(text.dropFirst(2), radix: 16),
                  (try? await post("/v1/set/data", ["address": text, "type": "UINT8[8]"])) != nil else { continue }
            let inner = try await post("/v1/set/data", ["address": String(format: "0x%llX", at + 2), "type": "UINT16"])
            let cleared = inner["data_cleared"] as? [[String: Any]] ?? []
            XCTAssertEqual(cleared.first?["address"] as? String, text, "\(inner)")
            XCTAssertEqual(cleared.first?["type"] as? String, "UINT8[8]", "\(inner)")
            return
        }
        throw XCTSkip("no datum takes a UINT8[8]")
    }

    /// Issue 0718ba54: an enum defined again keeps its category, and a
    /// comment written beside a member in the C is that member's comment.
    func testATypeDefinedAgainKeepsItsCategoryAndTheCommentsInItsC() async throws {
        let place = try await immediates(1)[0]
        let value = try XCTUnwrap(UInt64(place.value.dropFirst(2), radix: 16))
        _ = try await post("/v1/set/equate", ["address": place.at, "operand": 1, "name": "SILENT_FIRST",
                                              "enum": "SILENT_KIND", "comment": "kept from before"])
        let c = """
            typedef enum _SILENT_KIND {
                SILENT_FIRST = \(value),
                SILENT_NEXT = \(value + 1), /* added beside the member */
                // on the line before
                SILENT_LAST = \(value + 2)
            } SILENT_KIND;
            """
        let answer = try await post("/v1/type", ["c": c])
        XCTAssertEqual(answer["path"] as? String, "/ByteRipper/SILENT_KIND", "\(answer)")
        XCTAssertEqual(answer["comments_from_c"] as? Int, 2, "\(answer)")
        XCTAssertNil(answer["comments_not_placed"], "\(answer)")
        let text = answer["c"] as? String ?? ""
        XCTAssertTrue(text.contains("added beside the member") && text.contains("on the line before")
                      && text.contains("kept from before"), text)
    }

    /// Issue 2e20705f: the C `ghidra_type_definition` prints marks each
    /// member with its offset, `/* 0x04 */`. Sent back as it is, that mark is
    /// not taken for the member's comment, and the comments stay as they were.
    func testTheCATypeIsPrintedAsIsSentBackUnchanged() async throws {
        let c = """
            typedef struct _SILENT_RECORD {
                UINT32 Signature; /* the record's tag */
                UINT32 Size;
                // what follows the header
                UINT16 Count;
            } SILENT_RECORD;
            """
        _ = try await post("/v1/type", ["c": c])
        func fields() async throws -> [[String: Any]] {
            let program = try await read("/v1/type?name=SILENT_RECORD")["program"] as? [String: Any]
            return try XCTUnwrap(program?["fields"] as? [[String: Any]])
        }
        let before = try await fields()
        XCTAssertEqual(before.map { $0["comment"] as? String },
                       ["the record's tag", nil, "what follows the header"])
        let shown = try await read("/v1/type?name=SILENT_RECORD")
        let printed = try XCTUnwrap((shown["program"] as? [String: Any])?["c"] as? String)
        XCTAssertTrue(printed.contains("/* 0x04 */"), printed)
        let answer = try await post("/v1/type", ["c": printed])
        XCTAssertNil(answer["comments_not_placed"], "\(answer)")
        let after = try await fields()
        XCTAssertEqual(after.map { $0["comment"] as? String }, before.map { $0["comment"] as? String },
                       printed)
    }

    func testATypeStillUsedIsNotDeleted() async throws {
        _ = try await post("/v1/type", ["c": "typedef struct _SILENT_INNER { unsigned int A; } SILENT_INNER;"])
        _ = try await post("/v1/type", ["c": "typedef struct _SILENT_OUTER { SILENT_INNER Inner; unsigned int B; } SILENT_OUTER;"])
        await refused("/v1/type", ["delete": true, "name": "SILENT_INNER"], saying: "SILENT_OUTER")
        let deleted = try await post("/v1/type", ["delete": true, "name": "SILENT_OUTER"])
        XCTAssertNotNil(deleted, "a type nothing uses goes")
    }
}
