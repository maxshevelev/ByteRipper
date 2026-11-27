import AgentKit
import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A review's records (`ghidra_set_record`, `ghidra_records`) on an EC module:
/// the host puts the profile's schema into each write, the owner checks every
/// row against it before writing any, keeps rows in key order, and the
/// harvest carries the records only once one is set. Run with
/// `GHIDRA_EC_MODULE` naming an ITE EC image; skipped otherwise.
final class GhidraOwnerRecordsTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func open() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerRecordsTests-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerRecordsTests"), writer: store)
        module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        try await host.take(module)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @discardableResult
    private func set(_ body: [String: Any]) async throws -> [String: Any] {
        try object(try await host.write(module, "/v1/set/record",
                                        body: try JSONSerialization.data(withJSONObject: body)))
    }

    private func read(_ record: String? = nil) async throws -> [String: Any] {
        try object(try await host.read(module, "/v1/records" + (record.map { "?record=\($0)" } ?? ""),
                                       holder: "a reader"))
    }

    /// The one record of an answer.
    private func record(_ answer: [String: Any], _ id: String) throws -> [String: Any] {
        try XCTUnwrap((answer["records"] as? [[String: Any]])?.first { $0["id"] as? String == id }, id)
    }

    private func refused(_ body: [String: Any], saying words: String, file: StaticString = #filePath,
                         line: UInt = #line) async {
        do {
            _ = try await set(body)
            XCTFail("not refused: \(body)", file: file, line: line)
        } catch let error as GhidraHostError {
            XCTAssertTrue(error.message.contains(words), "\(error.message) — wanted \(words)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    /// Two function entries: code addresses a row may name.
    private func entries() async throws -> (String, String) {
        let data = try await host.read(module, "/v1/functions?limit=2", holder: "a reader")
        let functions = try XCTUnwrap(try object(data)["functions"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(functions.count, 2)
        return (try XCTUnwrap(functions[0]["entry"] as? String), try XCTUnwrap(functions[1]["entry"] as? String))
    }

    private func irq(_ number: Any, _ handler: String, purpose: String = "Ticks the timer.") -> [String: Any] {
        ["irq": number, "handler": handler, "source": "Timer 1", "source_status": "firmware",
         "enabled_by_firmware": true, "purpose": purpose, "confidence": "established"]
    }

    // MARK: - The schema

    /// The host puts the record's key, columns, parameters and the key
    /// columns of every record it refers to into the body.
    func testTheHostPutsTheSchemaIntoTheWrite() async throws {
        try await open()
        let body = try JSONSerialization.data(withJSONObject: ["record": "host_commands", "status": "partial"])
        let sent = try object(try await host.recordWriteBody(module, body: body))
        let schema = try XCTUnwrap(sent["schema"] as? [String: Any])
        XCTAssertEqual(schema["key"] as? [String], ["ports", "cmd", "sub", "mode"])
        XCTAssertEqual((schema["columns"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.prefix(2),
                       ["label", "ports"])
        let refKeys = try XCTUnwrap(schema["ref_keys"] as? [String: Any])
        XCTAssertEqual((refKeys["ec_ram"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["offset"])

        let ram = try object(try await host.recordWriteBody(
            module, body: try JSONSerialization.data(withJSONObject: ["record": "ec_ram"])))
        XCTAssertEqual(((ram["schema"] as? [String: Any])?["parameters"] as? [String: String])?["ec_ram_base"], "0x80400")
        let flash = try object(try await host.recordWriteBody(
            module, body: try JSONSerialization.data(withJSONObject: ["record": "eflash_area"])))
        XCTAssertEqual(((flash["schema"] as? [String: Any])?["ref_keys"] as? [String: Any])?.keys.sorted(), ["host_commands"])
    }

    /// Profile 3's `label` (every record) and GPIO's `group`: a column the
    /// schema names is taken, a label past 40 characters is refused.
    func testALabelAndAGroupAreTaken() async throws {
        try await open()
        let (code, _) = try await entries()
        var row = irq(4, code)
        row["label"] = "1 ms tick"
        try await set(["record": "irq_map", "status": "partial", "note": "others not read", "upsert": [row]])
        let answer = try await read("irq_map")
        let rows = try XCTUnwrap(try record(answer, "irq_map")["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["label"] as? String, "1 ms tick")
        row["label"] = String(repeating: "x", count: 41)
        await refused(["record": "irq_map", "upsert": [row]], saying: "label")
        try await set(["record": "gpio", "status": "partial", "note": "others not read", "upsert": [[
            "pin": "GPA3", "direction": "out", "function": "Power LED.", "group": "indicator", "confidence": "established"]]])
        await refused(["record": "gpio", "upsert": [[
            "pin": "GPA4", "direction": "out", "function": "x", "group": "lights", "confidence": "established"]]],
                      saying: "group")
    }

    /// A branch of a grouped list takes a note of its own, merged by branch;
    /// a record with no branches, or a branch that is not one, is refused.
    func testABranchTakesANoteOfItsOwn() async throws {
        try await open()
        try await set(["record": "host_commands", "status": "partial", "note": "shared helpers: PMC1 stage",
                       "branch_notes": ["60/64": "0x59 sub-commands: only 0x50", "62/66": "0x45/0x47 not reviewed"]])
        try await set(["record": "host_commands", "branch_notes": ["62/66": NSNull(), "68/6C": "flash bytes left out"]])
        let answer = try await read("host_commands")
        let notes = try XCTUnwrap(try record(answer, "host_commands")["branch_notes"] as? [String: String])
        XCTAssertEqual(notes, ["60/64": "0x59 sub-commands: only 0x50", "68/6C": "flash bytes left out"])
        await refused(["record": "host_commands", "branch_notes": ["70/74": "x"]], saying: "branch_notes.70/74")
        await refused(["record": "ec_ram", "branch_notes": ["a": "x"]], saying: "has no branches")
    }

    /// `not_checked` stands beside `note`, and a partial record takes it in
    /// place of a note; null clears it.
    func testWhatIsNotCheckedIsAFieldOfItsOwn() async throws {
        try await open()
        let (code, _) = try await entries()
        var answer = try await set(["record": "irq_map", "status": "partial", "not_checked": "IRQ 107",
                                    "upsert": [irq(4, code)]])
        var irqs = try record(answer, "irq_map")
        XCTAssertEqual(irqs["not_checked"] as? String, "IRQ 107")
        XCTAssertNil(irqs["note"])
        answer = try await set(["record": "irq_map", "note": "All rows of the table."])
        irqs = try record(answer, "irq_map")
        XCTAssertEqual(irqs["note"] as? String, "All rows of the table.")
        XCTAssertEqual(irqs["not_checked"] as? String, "IRQ 107", "kept")
        answer = try await set(["record": "irq_map", "not_checked": NSNull()])
        XCTAssertNil(try record(answer, "irq_map")["not_checked"])
    }

    /// `patch` changes only the columns it gives; the rest of the row stays.
    func testAPatchChangesOnlyTheColumnsGiven() async throws {
        try await open()
        let (code, second) = try await entries()
        try await set(["record": "irq_map", "status": "partial", "note": "others not read",
                       "rows": [irq(4, code), irq(9, second)]])
        let answer = try await set(["record": "irq_map", "patch": [["irq": 4, "label": "1 ms tick"]]])
        let rows = try XCTUnwrap(try record(answer, "irq_map")["rows"] as? [[String: Any]])
        let four = try XCTUnwrap(rows.first { $0["irq"] as? Int == 4 })
        XCTAssertEqual(four["label"] as? String, "1 ms tick")
        XCTAssertEqual(four["purpose"] as? String, irq(4, code)["purpose"] as? String, "the rest kept")
        XCTAssertEqual(rows.count, 2)
        await refused(["record": "irq_map", "patch": [["irq": 5, "label": "x"]]], saying: "no row has the key")
        await refused(["record": "irq_map", "patch": [["irq": 4, "source": NSNull()]]], saying: "source")
    }

    // MARK: - Refusals

    func testEveryKindOfWrongValueIsRefused() async throws {
        try await open()
        let (code, _) = try await entries()
        await refused(["record": "nope", "status": "none", "note": "x"], saying: "is not a record of ec-ite-nds32@3")
        await refused(["record": "irq_map", "rows": [irq(4, code).merging(["colour": "red"]) { $1 }]],
                      saying: "irq_map[row 0].colour: expected one of the record's columns")
        var missing = irq(4, code)
        missing["purpose"] = nil
        await refused(["record": "irq_map", "rows": [missing]], saying: "irq_map[row 0].purpose: expected a value")
        var unsure = irq(4, code)
        unsure["confidence"] = nil
        await refused(["record": "irq_map", "rows": [unsure]], saying: "irq_map[row 0].confidence: expected established")
        await refused(["record": "irq_map", "rows": [irq("four", code)]], saying: "irq_map[row 0].irq: expected an integer")
        await refused(["record": "irq_map", "rows": [irq(240, code)]], saying: "irq_map[row 0].irq: expected an integer 0…239")
        await refused(["record": "irq_map", "rows": [irq(4, code).merging(["source_status": "maybe"]) { $1 }]],
                      saying: "irq_map[row 0].source_status: expected one of firmware, unverified")
        await refused(["record": "irq_map", "rows": [irq(4, code).merging(["enabled_by_firmware": "yes"]) { $1 }]],
                      saying: "enabled_by_firmware: expected true or false")
        await refused(["record": "gpio", "rows": [["pin": "GPA9", "direction": "out", "function": "LED",
                                                   "confidence": "inference"]]],
                      saying: "gpio[row 0].pin: expected text matching")
        await refused(["record": "irq_map", "rows": [irq(4, "0x8D")]],
                      saying: "irq_map[row 0].handler: expected a code address inside a function")
        await refused(["record": "eflash_area", "rows": [["address": "0xFFFFFFF0", "size": 4, "format": "bytes",
                                                          "writers": [code], "meaning": "state",
                                                          "confidence": "established"]]],
                      saying: "eflash_area[row 0].address: expected a data address")
        await refused(["record": "ec_ram", "rows": [["offset": 16, "width": 1, "name": "STATE", "writer": "EC",
                                                     "meaning": "state", "address": "0x80410",
                                                     "confidence": "established"]]],
                      saying: "ec_ram[row 0].address: expected nothing — it is computed")
        await refused(["record": "irq_map", "rows": [irq(4, code), irq("0x4", code)]],
                      saying: "irq_map[row 1]: expected a key of its own; row 0 has the key")
        await refused(["record": "irq_map", "status": "partial"], saying: "irq_map.note: expected a note with status partial")
        await refused(["record": "irq_map", "status": "none", "note": "no interrupts", "rows": [irq(4, code)]],
                      saying: "irq_map.status: none takes no rows")
        await refused(["record": "irq_map", "status": "complete", "rows": []],
                      saying: "complete with no rows — use none with the reason")
        await refused(["record": "smbus_peers", "rows": [["channel": "A", "address": "runtime", "device": "battery",
                                                          "commands": [["cmd": 0x0D, "access": "R", "size": "word",
                                                                        "meaning": "charge"]],
                                                          "confidence": "inference"]]],
                      saying: "smbus_peers[row 0].note: expected a note")
        await refused(["record": "irq_map", "rows": [irq(4, code)], "upsert": [irq(5, code)]],
                      saying: "not both")
        // Nothing was written by any of them.
        let answer = try await read()
        XCTAssertEqual(answer["unanswered"] as? [String],
                       ["irq_map", "host_commands", "ec_ram", "smbus_peers", "gpio", "eflash_area"])
    }

    /// One wrong row refuses the call; the good rows beside it are not written.
    func testAWriteIsAllOrNothing() async throws {
        try await open()
        let (code, _) = try await entries()
        await refused(["record": "irq_map", "rows": [irq(4, code), irq(9, "0x8D")]], saying: "irq_map[row 1].handler")
        let irqs = try record(try await read("irq_map"), "irq_map")
        XCTAssertEqual(irqs["status"] as? String, "unanswered")
        XCTAssertEqual((irqs["rows"] as? [Any])?.count, 0)
    }

    // MARK: - Rows and status

    func testRowsAreSortedUpsertedAndDeletedByKey() async throws {
        try await open()
        let (first, second) = try await entries()
        var answer = try await set(["record": "irq_map", "rows": [irq(9, first), irq("0x4", second)]])
        var irqs = try record(answer, "irq_map")
        XCTAssertEqual((irqs["rows"] as? [[String: Any]])?.compactMap { $0["irq"] as? Int }, [4, 9])
        // Rows written to an unanswered record make it partial.
        XCTAssertEqual(irqs["status"] as? String, "partial")
        XCTAssertEqual(irqs["note"] as? String, "review continues")
        XCTAssertNotNil(irqs["columns"], "a write answers the record with its columns")

        answer = try await set(["record": "irq_map", "upsert": [irq(4, second, purpose: "Polls the keyboard."),
                                                                irq(16, first)]])
        irqs = try record(answer, "irq_map")
        let rows = try XCTUnwrap(irqs["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["irq"] as? Int }, [4, 9, 16])
        XCTAssertEqual(rows.first?["purpose"] as? String, "Polls the keyboard.")
        XCTAssertEqual(rows.first?["confidence"] as? String, "established")

        answer = try await set(["record": "irq_map", "delete": [["irq": 9]]])
        XCTAssertEqual((try record(answer, "irq_map")["rows"] as? [[String: Any]])?.compactMap { $0["irq"] as? Int },
                       [4, 16])
        await refused(["record": "irq_map", "delete": [["irq": 9]]], saying: "no row has the key")

        // Composite keys sort column by column; a missing optional part first.
        answer = try await set(["record": "host_commands", "rows": [
            ["ports": "62/66", "mode": "normal", "cmd": 0x80, "handler": first, "effect": "Read EC RAM",
             "confidence": "established"],
            ["ports": "62/66", "mode": "normal", "cmd": 0x80, "sub": 1, "handler": first, "effect": "Read, sub 1",
             "confidence": "inference"],
            ["ports": "60/64", "mode": "normal", "cmd": "0xAA", "handler": second, "effect": "Self test",
             "confidence": "established"]
        ]])
        let commands = try XCTUnwrap(try record(answer, "host_commands")["rows"] as? [[String: Any]])
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["0xAA", "0x80", "0x80"])
        XCTAssertNil(commands[1]["sub"])
        XCTAssertEqual(commands[2]["sub"] as? String, "0x01")
    }

    func testTheStatusRules() async throws {
        try await open()
        let (code, _) = try await entries()
        try await set(["record": "gpio", "status": "none", "note": "the firmware drives no GPIO itself"])
        try await set(["record": "irq_map", "status": "complete", "note": "all other IRQs: empty stub",
                       "rows": [irq(4, code)]])
        var answer = try await read()
        XCTAssertEqual(answer["unanswered"] as? [String], ["host_commands", "ec_ram", "smbus_peers", "eflash_area"])
        XCTAssertEqual(try record(answer, "gpio")["status"] as? String, "none")
        XCTAssertEqual(try record(answer, "irq_map")["note"] as? String, "all other IRQs: empty stub")
        XCTAssertNil(try record(answer, "irq_map")["rows"], "all records: no rows, only their count")
        XCTAssertEqual(try record(answer, "irq_map")["row_count"] as? Int, 1)
        // A status written alone keeps the rows; going back to partial needs a note.
        await refused(["record": "irq_map", "status": "partial", "note": NSNull()], saying: "expected a note")
        // Deleting the last row of a complete record is refused.
        await refused(["record": "irq_map", "delete": [["irq": 4]]], saying: "complete with no rows")
        // A null status takes the record back, empty.
        answer = try await set(["record": "irq_map", "status": NSNull()])
        let irqs = try record(answer, "irq_map")
        XCTAssertEqual(irqs["status"] as? String, "unanswered")
        XCTAssertEqual((irqs["rows"] as? [Any])?.count, 0)
        XCTAssertNil(irqs["note"])
        XCTAssertEqual(answer["unanswered"] as? [String],
                       ["irq_map", "host_commands", "ec_ram", "smbus_peers", "eflash_area"])
    }

    /// Computed columns, refs that name no row (a warning, not a refusal),
    /// and a runtime address with its note.
    func testComputedColumnsAndDanglingRefs() async throws {
        try await open()
        let (code, _) = try await entries()
        var answer = try await set(["record": "host_commands", "rows": [
            ["ports": "62/66", "mode": "normal", "cmd": 0x80, "handler": code, "effect": "Read EC RAM",
             "ec_ram": ["0x10"], "raises": ["SCI", "query 0x51"], "confidence": "established"]]])
        let warnings = try XCTUnwrap(answer["warnings"] as? [String])
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings.first?.contains("names no row of ec_ram") == true, "\(warnings)")

        answer = try await set(["record": "ec_ram", "upsert": [
            ["offset": 16, "width": 1, "name": "STATE", "writer": "EC", "meaning": "Power state.",
             "accessed_by": [code], "confidence": "established"]]])
        XCTAssertEqual(answer["warnings"] as? [String], [])
        let ram = try XCTUnwrap((try record(answer, "ec_ram")["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(ram["offset"] as? String, "0x10")
        XCTAssertEqual(ram["address"] as? String, "0x80410")

        answer = try await set(["record": "smbus_peers", "rows": [
            ["channel": "A", "address": 0x0B, "device": "Smart battery", "pec": false,
             "commands": [["cmd": 0x0D, "access": "R", "size": "word", "meaning": "Relative charge"]],
             "confidence": "established"],
            ["channel": "B", "address": "runtime", "device": "not identified", "note": "read from EC RAM 0x40",
             "commands": [["cmd": 0, "access": "W", "size": "byte", "meaning": "unknown"]],
             "confidence": "inference"]]])
        let peers = try XCTUnwrap(try record(answer, "smbus_peers")["rows"] as? [[String: Any]])
        XCTAssertEqual(peers[0]["address_8bit"] as? String, "0x16")
        XCTAssertEqual(peers[1]["address"] as? String, "runtime")
        XCTAssertNil(peers[1]["address_8bit"])
        XCTAssertEqual((peers[0]["commands"] as? [[String: Any]])?.first?["cmd"] as? String, "0x0D")

        // A composite-key ref: the flash area names a host command by its key.
        answer = try await set(["record": "eflash_area", "rows": [
            ["address": "0x8D", "size": 1, "format": "byte", "writers": [code], "meaning": "Boot flag.",
             "in_image": true, "host_commands": [["ports": "62/66", "mode": "normal", "cmd": "0x80"],
                                                  ["ports": "68/6C", "mode": "flash", "cmd": 1]],
             "confidence": "inference"]]])
        let flashWarnings = try XCTUnwrap(answer["warnings"] as? [String])
        XCTAssertEqual(flashWarnings.count, 1, "\(flashWarnings)")
        XCTAssertTrue(flashWarnings.first?.contains("68/6C") == true, "\(flashWarnings)")
    }

    /// `commands` is required, but a row whose address is mailbox or runtime
    /// may leave it empty or out (`optional_when`); a numeric address may not.
    func testCommandsAreOptionalOnlyForAMailboxOrRuntimeAddress() async throws {
        try await open()
        await refused(["record": "smbus_peers", "rows": [["channel": "A", "address": 0x0B, "device": "battery",
                                                          "confidence": "inference"]]],
                      saying: "smbus_peers[row 0].commands: expected a value (required)")
        await refused(["record": "smbus_peers", "rows": [["channel": "A", "address": 0x0B, "device": "battery",
                                                          "commands": [], "confidence": "inference"]]],
                      saying: "smbus_peers[row 0].commands: expected at least one row (required)")
        let answer = try await set(["record": "smbus_peers", "rows": [
            ["channel": "C", "address": "mailbox", "device": "not identified", "commands": [],
             "note": "the host sets the command byte through the mailbox", "confidence": "established"],
            ["channel": "E", "address": "runtime", "device": "not identified",
             "note": "address and command from the host mailbox", "confidence": "inference"]]])
        let peers = try XCTUnwrap(try record(answer, "smbus_peers")["rows"] as? [[String: Any]])
        XCTAssertEqual(peers.map { $0["channel"] as? String }, ["C", "E"])
    }

    /// `ghidra_type_definition` without `verbose` carries the program's
    /// definition with its fields: the owner's answer names the type
    /// `program`, the same key as the identity the compact answer drops.
    func testTheCompactTypeDefinitionKeepsTheProgramsFields() async throws {
        try await open()
        _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["c": """
            typedef struct _EC_RAM_PROBE {
                UINT8 State; /* power state */
                UINT8 Pad;
                UINT16 Fan;
            } EC_RAM_PROBE;
            """]))
        let owner = try JSONValue.parse(try await host.read(module, "/v1/type?name=EC_RAM_PROBE", holder: "a reader"))
        let compact = GhidraTools.compact(owner, tool: "ghidra_type_definition", arguments: [:])
        let object = try XCTUnwrap(compact.objectValue)
        XCTAssertNil(object["project"])
        XCTAssertNil(object["module"])
        XCTAssertEqual(object["found"], .bool(true))
        let program = try XCTUnwrap(object["program"]?.objectValue, "\(compact)")
        XCTAssertEqual(program["size"], .int(4))
        XCTAssertNil(program["c"])
        let fields = try XCTUnwrap(program["fields"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(fields.compactMap { $0["name"]?.stringValue }, ["State", "Pad", "Fan"])
        XCTAssertEqual(fields.compactMap { $0["offset"]?.stringValue }, ["0x0", "0x1", "0x2"])
        XCTAssertEqual(fields.last?["type"]?.stringValue, "UINT16")
        XCTAssertNil(fields.first?["comment"])
        // The owner's own answer, which verbose passes through, keeps the C and the comment.
        let full = try XCTUnwrap(owner.objectValue?["program"]?.objectValue)
        XCTAssertNotNil(full["c"])
        XCTAssertEqual(full["fields"]?.arrayValue?.first?.objectValue?["comment"]?.stringValue, "power state")
    }

    // MARK: - The harvest

    /// The review document a publish would store: a dry run harvests it, and
    /// `review` reads what it harvested.
    private func harvest() async throws -> Data {
        _ = try await host.preview(module, "/v1/publish?dry_run=1", body: Data("{}".utf8))
        return try await host.read(module, "/v1/review", holder: "a reader")
    }

    /// A review without records harvests to the same bytes as before; one
    /// with a record carries it, rows in key order.
    func testTheHarvestCarriesRecordsOnlyWhenSet() async throws {
        try await open()
        let (code, _) = try await entries()
        let before = try await harvest()
        XCTAssertNil(try object(before)["records"])

        try await set(["record": "irq_map", "rows": [irq(9, code), irq(4, code)]])
        let with = try object(try await harvest())
        let records = try XCTUnwrap(with["records"] as? [String: Any])
        let irqs = try XCTUnwrap(records["irq_map"] as? [String: Any])
        XCTAssertEqual(irqs["status"] as? String, "partial")
        XCTAssertEqual((irqs["rows"] as? [[String: Any]])?.compactMap { $0["irq"] as? Int }, [4, 9])

        try await set(["record": "irq_map", "status": NSNull()])
        let after = try await harvest()
        XCTAssertEqual(String(decoding: after, as: UTF8.self), String(decoding: before, as: UTF8.self),
                       "a review whose records were taken back harvests as one that never had any")
    }

    // MARK: - The publish

    /// A publish copies each record's status into the revision's reading
    /// and reports the `records_answered` gate — never refusing on it.
    func testAPublishKeepsTheStatusesAndReportsTheGate() async throws {
        try await open()
        let (code, _) = try await entries()
        try await set(["record": "irq_map", "status": "complete", "rows": [irq(4, code)]])
        try await set(["record": "gpio", "status": "none", "note": "the firmware drives no GPIO"])
        try await set(["record": "ec_ram", "status": "partial", "note": "review continues",
                       "rows": [["offset": 16, "width": 1, "name": "STATE", "writer": "EC", "meaning": "state",
                                 "confidence": "inference"]]])
        let publication = try await host.publish(module, by: "GhidraOwnerRecordsTests")
        let reading = try XCTUnwrap(publication.manifest.reading)
        XCTAssertEqual(reading.records, ["irq_map": "complete", "gpio": "none", "ec_ram": "partial"])
        XCTAssertEqual(reading.profile, "ec-ite-nds32@3")
        XCTAssertNotEqual(publication.manifest.reviewProgress, .complete)

        let answer = try object(try JSONEncoder().encode(PublishAnswer(publication)))
        let gate = try XCTUnwrap((answer["gates"] as? [String: Any])?["records_answered"] as? [String: Any])
        XCTAssertEqual(gate["passed"] as? Bool, false)
        XCTAssertEqual(gate["partial"] as? [String], ["ec_ram"])
        XCTAssertEqual(gate["unanswered"] as? [String], ["host_commands", "smbus_peers", "eflash_area"])
    }
}
