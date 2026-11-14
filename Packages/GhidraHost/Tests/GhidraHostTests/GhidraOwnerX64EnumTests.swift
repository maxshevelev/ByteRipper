import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Enums in an X64 module: a 64-bit status code with the top bit set gets an
/// eight-byte enum (issue fee4157c, where `0xA000000000000002` read as a
/// negative long made a four-byte enum and Ghidra threw), and a four-byte
/// enum written `0xC0010063` keeps that value instead of -1073676189
/// (issue d8b45e1d). Needs Ghidra and `GHIDRA_X64_MODULE`, the DxeCore image
/// of the Legion 5 dump.
final class GhidraOwnerX64EnumTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_X64_MODULE"] else {
            throw XCTSkip("GHIDRA_X64_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerX64Enum-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerX64EnumTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "DxeCore")
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

    func testASixtyFourBitStatusCodeGetsAnEightByteEnum() async throws {
        // CoreEfiNotAvailableYet: MOV RAX, 0xA000000000000002, which the
        // listing prints signed.
        let instructions = try await read("/v1/disassembly/0xDB4")["instructions"] as? [[String: Any]] ?? []
        let holder = try XCTUnwrap(instructions.first {
            ($0["text"] as? String ?? "").lowercased().contains("rax,-0x5ffffffffffffffe")
        }, "\(instructions.prefix(8))")
        let at = try XCTUnwrap(holder["address"] as? String)

        let named = try await post("/v1/set/equate", [
            "address": at, "value": "0xA000000000000002", "name": "EFI_NOT_AVAILABLE_YET",
            "enum": "PI_DXE_STATUS", "comment": "DXE_ERROR (2)"])
        XCTAssertEqual(named["enum"] as? String, "PI_DXE_STATUS", "\(named)")
        XCTAssertEqual(named["value"] as? String, "0xA000000000000002", "\(named)")
        let type = try await read("/v1/type?name=PI_DXE_STATUS")
        let program = try XCTUnwrap(type["program"] as? [String: Any] ?? type, "\(type)")
        XCTAssertEqual(program["size"] as? Int, 8, "\(type)")

        // A four-byte enum is refused plainly, not with Ghidra's exception.
        try await post("/v1/type", ["c": "typedef enum _SMALL_STATUS { SMALL_ONE = 1 } SMALL_STATUS;"])
        do {
            try await post("/v1/set/equate", [
                "address": at, "value": "0xA000000000000002", "name": "SMALL_TOO_BIG", "enum": "SMALL_STATUS"])
            XCTFail("a 64-bit value does not go into a four-byte enum")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
            XCTAssertTrue("\(error)".contains("does not fit"), "\(error)")
        }
    }

    func testAFourByteEnumKeepsTheValueAsWritten() async throws {
        let defined = try await post("/v1/type", ["c": """
            typedef enum _AMD_PSTATE_MSR {
                MSR_PSTATE_STATUS = 0xC0010063,
                MSR_PSTATE_DEF_0 = 0xC0010064
            } AMD_PSTATE_MSR;
            """])
        XCTAssertEqual(defined["size"] as? Int, 4, "\(defined)")
        let c = try XCTUnwrap(defined["c"] as? String)
        XCTAssertTrue(c.contains("MSR_PSTATE_STATUS = 0xC0010063"), c)
        XCTAssertTrue(c.contains("MSR_PSTATE_DEF_0 = 0xC0010064"), c)
        XCTAssertFalse(c.contains("0xFFFFFFFFC001"), c)
        let read = try await read("/v1/type?name=AMD_PSTATE_MSR")
        XCTAssertFalse("\(read)".contains("-1073676189"), "\(read)")
    }

    /// The listing's rows of the first functions, for a search.
    private func rows(functions limit: Int) async throws -> [(entry: String, rows: [[String: Any]])] {
        var found: [(entry: String, rows: [[String: Any]])] = []
        for function in (try await read("/v1/functions")["functions"] as? [[String: Any]] ?? []).prefix(limit) {
            guard let entry = function["entry"] as? String else { continue }
            found.append((entry, try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []))
        }
        return found
    }

    /// X64's `MOV RCX,-2` holds a sign-extended 64-bit immediate: a four-byte
    /// enum names it with its 32-bit value, stored unsigned, and the value
    /// given in 32 bits finds the operand.
    func testASignExtendedImmediateIsAFourByteMember() async throws {
        var hit: (at: String, value: Int64)?
        search: for function in try await rows(functions: 300) {
            for row in function.rows {
                let text = (row["text"] as? String ?? "")
                guard text.hasPrefix("MOV R") || text.hasPrefix("CMP R"),
                      let range = text.range(of: #",-0x[0-9a-f]{1,7}$"#, options: .regularExpression),
                      let magnitude = Int64(text[range].dropFirst(4), radix: 16) else { continue }
                hit = (try XCTUnwrap(row["address"] as? String), -magnitude)
                break search
            }
        }
        let (at, value) = try XCTUnwrap(hit, "no sign-extended negative immediate in the first functions")
        let narrow = UInt32(truncatingIfNeeded: value)
        let given = String(format: "0x%X", narrow)
        try await post("/v1/type", ["c": "typedef enum _PROBE_SMALL { PROBE_ONE = 1 } PROBE_SMALL;"])
        let named = try await post("/v1/set/equate", [
            "address": at, "value": given, "name": "PROBE_NEGATIVE", "enum": "PROBE_SMALL"])
        XCTAssertEqual((named["enum"] as? String)?.hasSuffix("PROBE_SMALL"), true, "\(named)")
        let type = try await read("/v1/type?name=PROBE_SMALL")
        let program = try XCTUnwrap(type["program"] as? [String: Any], "\(type)")
        let values = try XCTUnwrap(program["values"] as? [String: String], "\(program)")
        XCTAssertEqual(values["PROBE_NEGATIVE"], given, "\(values)")
        XCTAssertEqual(values["PROBE_ONE"], "0x1", "\(values)")
        // Named again with the same value: the member is found, not refused.
        let again = try await post("/v1/set/equate", [
            "address": at, "value": given, "name": "PROBE_NEGATIVE", "enum": "PROBE_SMALL"])
        XCTAssertEqual((again["enum"] as? String)?.hasSuffix("PROBE_SMALL"), true, "\(again)")
    }

    /// 32-bit code in an X64 module is decoded out of long mode — `0x48` is
    /// `DEC EAX`, not a REX prefix — and 64 reads it as long mode again.
    func testCodeModeLeavesAndReentersLongMode() async throws {
        var found: (entry: String, next: String)?
        for function in try await rows(functions: 300) {
            guard function.rows.count > 3,
                  (function.rows[0]["bytes"] as? String ?? "").lowercased().hasPrefix("48"),
                  let next = function.rows[3]["address"] as? String else { continue }
            found = (function.entry, next)
            break
        }
        let (entry, end) = try XCTUnwrap(found, "no function starts with a REX.W prefix")
        let thirtyTwo = try await post("/v1/set/code-mode", ["start": entry, "end": end, "bits": 32])
        XCTAssertEqual(thirtyTwo["bits"] as? Int, 32, "\(thirtyTwo)")
        var listed = try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
        XCTAssertEqual(listed.first?["text"] as? String, "DEC EAX", "\(listed.prefix(3))")
        XCTAssertEqual(listed.first?["bits"] as? Int, 32, "\(listed.prefix(3))")

        try await post("/v1/set/code-mode", ["start": entry, "end": end, "bits": 64])
        listed = try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
        XCTAssertNotEqual(listed.first?["text"] as? String, "DEC EAX", "\(listed.prefix(3))")
        XCTAssertNil(listed.first?["bits"], "\(listed.prefix(3))")
    }

    /// An eight-byte enum's values read as hex, not as negative longs.
    func testTypeDefinitionGivesEnumValuesInHex() async throws {
        let type = try await read("/v1/type?name=EFI_STATUS")
        let edk2 = try XCTUnwrap((type["program"] ?? type["edk2"]) as? [String: Any], "\(type)")
        let values = try XCTUnwrap(edk2["values"] as? [String: String], "\(edk2)")
        XCTAssertEqual(values["EFI_NOT_FOUND"], "0x800000000000000E", "\(values)")
    }

    /// A field of what a register points at is not module data, though at
    /// image base 0 its displacement is an address of the module: ReadPTLen
    /// reads `[Sd + Index + 0x121C]` (SCRATCH_DATA.mPTLen), and 0x121C is
    /// CoreCleanupGcdMapEntry (issue 42abc327). A body that reads only its
    /// argument's fields depends on nothing of the module.
    func testAFieldOfARegistersPointeeIsNoModuleData() async throws {
        let instructions = try await read("/v1/disassembly/0xE2F4?limit=400")["instructions"] as? [[String: Any]] ?? []
        let field = try XCTUnwrap(instructions.first { ($0["text"] as? String ?? "").lowercased().contains("0x121c]") },
                                  "\(instructions.prefix(40))")
        try await post("/v1/library/candidate", ["items": [["address": "0xE2F4", "kind": "edk2"]]])
        let library = try await read("/v1/library")
        // Unreviewed, it is below the bar: its dependencies are listed there alike.
        let entries = (library["entries"] as? [[String: Any]] ?? []) + (library["below_bar"] as? [[String: Any]] ?? [])
        let entry = try XCTUnwrap(entries.first { ($0["address"] as? String)?.uppercased() == "0XE2F4" },
                                  "\(library.keys) \(entries.compactMap { $0["address"] })")
        XCTAssertEqual(entry["data_references"] as? [String], [], "\(field) \(entry["data_references"] ?? "none")")

        // A global the module holds, read RIP-relative, is still its data.
        let functions = try await read("/v1/functions?limit=200")["functions"] as? [[String: Any]] ?? []
        var reader: String?
        for function in functions where reader == nil {
            guard let at = function["entry"] as? String, at.uppercased() != "0XE2F4" else { continue }
            let rows = try await read("/v1/disassembly/\(at)?limit=60")["instructions"] as? [[String: Any]] ?? []
            if rows.contains(where: { row in
                let text = (row["text"] as? String ?? "").uppercased()
                let references = row["references"] as? [[String: Any]] ?? []
                // RIP-relative prints as the address it reaches: `qword ptr [0x1a3c8]`.
                return (text.contains("[RIP") || text.contains("[0X"))
                    && references.contains { $0["type"] as? String == "READ" }
            }) { reader = at }
        }
        let global = try XCTUnwrap(reader, "no function reads a global RIP-relative")
        try await post("/v1/library/candidate", ["items": [["address": global, "kind": "edk2"]]])
        let after = try await read("/v1/library")
        let rows = (after["entries"] as? [[String: Any]] ?? []) + (after["below_bar"] as? [[String: Any]] ?? [])
        let row = try XCTUnwrap(rows.first { ($0["address"] as? String)?.uppercased() == global.uppercased() })
        XCTAssertFalse((row["data_references"] as? [String] ?? []).isEmpty, "\(global): \(row)")
    }

    /// A jump into bytes nobody decoded leaves a hole in the body: the registry
    /// could keep no code for it, so the function is offered below the bar with
    /// the place named, not as an entry the store then silently fails to link
    /// (issue dc635a83: ReadPTLen's zero-fill loop at 0xE447 was bytes, and
    /// the publish stored 21 links where its dry run said 23).
    func testAJumpIntoUndecodedBytesKeepsAFunctionFromTheRegistry() async throws {
        try await post("/v1/library/candidate", ["items": [["address": "0xE2F4", "kind": "edk2"]]])
        func row() async throws -> [String: Any] {
            let library = try await read("/v1/library")
            let rows = (library["entries"] as? [[String: Any]] ?? []) + (library["below_bar"] as? [[String: Any]] ?? [])
            return try XCTUnwrap(rows.first { ($0["address"] as? String)?.uppercased() == "0XE2F4" })
        }
        let whole = try await row()
        XCTAssertFalse((whole["gaps"] as? [String] ?? []).contains { $0.hasPrefix("undecoded") }, "\(whole)")

        try await post("/v1/set/data", ["address": "0xE447", "type": "byte[21]", "clear_code": true])
        let holed = try await row()
        XCTAssertTrue((holed["gaps"] as? [String] ?? []).contains("undecoded 0xE447"), "\(holed)")
        XCTAssertNil(holed["entry"], "below the bar, not an entry: \(holed)")
        let refusal = try XCTUnwrap(GhidraHost.offerRefusal(
            [GhidraHost.LibraryShortfall(address: "0xE2F4", name: "ReadPTLen", kind: "edk2", gaps: holed["gaps"] as? [String] ?? [])], would: nil))
        XCTAssertTrue(refusal.contains("not decoded (0xE447)") && refusal.contains("ghidra_redecode"), refusal)
    }

    /// The displacement of `[RAX + RDI*0x1 + 0x121c]` is named by `operand`
    /// alone: the operand's objects hold the scale 0x1 first, and a name is
    /// never the scale's (issue b2de98c2: SCRATCH_DATA.mPTLen in ReadPTLen).
    func testANamedOperandIsItsDisplacementNotItsScale() async throws {
        let rows = try await read("/v1/disassembly/0xE2F4?limit=300")["instructions"] as? [[String: Any]] ?? []
        let store = try XCTUnwrap(rows.first { ($0["text"] as? String ?? "").lowercased().contains("*0x1 + 0x121c]") },
                                  "\(rows.map { $0["text"] ?? "" })")
        let at = try XCTUnwrap(store["address"] as? String)
        let named = try await post("/v1/set/equate", ["address": at, "operand": 0, "name": "SCRATCH_DATA_mPTLen_OFFSET",
                                                       "enum": "SCRATCH_DATA_OFFSET"])
        XCTAssertEqual(named["value"] as? String, "0x121C", "\(named)")
        XCTAssertEqual(named["operand"] as? Int, 0)
    }
}
