import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A reference Ghidra derives from a register's value is nothing the body
/// names. SecureFlashDxe's ReadPTLen fills `Sd->mPTTable` with `REP STOSW`
/// through RDI, loaded from `[RSI + 0x323C]`; at image base 0 Ghidra puts
/// DATA references to 0x323C and 0x323E on the STOSW, and they fall inside
/// BasePrintLibSPrintMarker, so the dependencies read them as code ReadPTLen
/// calls and the registry refused it (issue 458a6f76). Needs Ghidra and
/// `GHIDRA_SECUREFLASH_MODULE`, the SecureFlashDxe image of the Legion 5 dump.
final class GhidraOwnerRegisterReferenceTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_SECUREFLASH_MODULE"] else {
            throw XCTSkip("GHIDRA_SECUREFLASH_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerRegisterReference-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerRegisterReferenceTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "SecureFlashDxe")
    }

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func read(_ path: String) async throws -> [String: Any] {
        let data = try await host.read(module, path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAReferenceFromARegistersValueIsNoCallee() async throws {
        let instructions = try await read("/v1/disassembly/0x1EF8?limit=400")["instructions"] as? [[String: Any]] ?? []
        let fill = try XCTUnwrap(instructions.first { ($0["address"] as? String)?.uppercased() == "0X1F71" },
                                 "\(instructions.prefix(4))")
        XCTAssertTrue((fill["text"] as? String ?? "").uppercased().contains("STOS"), "\(fill)")

        try await host.take(module)
        _ = try await host.write(module, "/v1/library/candidate", body: try JSONSerialization.data(
            withJSONObject: ["items": [["address": "0x1EF8", "kind": "edk2"]]]))
        let library = try await read("/v1/library")
        let entries = (library["entries"] as? [[String: Any]] ?? []) + (library["below_bar"] as? [[String: Any]] ?? [])
        let entry = try XCTUnwrap(entries.first { ($0["address"] as? String)?.uppercased() == "0X1EF8" },
                                  "\(entries.compactMap { $0["address"] })")
        let callees = (entry["callees"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertFalse(callees.contains { $0.hasPrefix("code at") }, "\(fill) \(callees)")
        XCTAssertEqual(entry["data_references"] as? [String], [], "\(entry)")
    }

    /// The analysis carries a constant on through registers and gives the
    /// register operands a reference to it as well: in IhisiServicesSmm
    /// `MOV RAX,RBX` and `MOV ECX,EAX` kept DATA and PARAM references to the
    /// status 0x802B after its immediates were named, so the address kept
    /// its label and the C still printed `&LAB_0000802b` (issue 7d8fd720).
    /// Here 0x1960 holds 0x1200, and `SHR R8,0xc` at 0x1B24 has a PARAM
    /// reference to it. Naming the value in the function lets those go.
    func testAValueNamedInAFunctionIsNoAddressInItsRegisters() async throws {
        func carried() async throws -> [[String: Any]] {
            let rows = try await read("/v1/disassembly/0x1960?from=0x1B24&limit=1")["instructions"] as? [[String: Any]] ?? []
            let row = try XCTUnwrap(rows.first { ($0["address"] as? String)?.uppercased() == "0X1B24" }, "\(rows)")
            return (row["references"] as? [[String: Any]] ?? []).filter { ($0["to"] as? String)?.uppercased() == "0X1200" }
        }
        let before = try await carried()
        XCTAssertFalse(before.isEmpty, "the premise: SHR R8 carries a reference to 0x1200")

        try await host.take(module)
        let data = try await host.write(module, "/v1/set/equate", body: try JSONSerialization.data(withJSONObject: [
            "name": "TEST_SIZE_1200", "value": "0x1200", "functions": ["0x1960"]]))
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse((answer["applied"] as? [[String: Any]] ?? []).isEmpty, "the premise: 0x1960 holds 0x1200 \(answer)")
        XCTAssertNotNil(answer["address_references_dropped"], "\(answer)")
        let after = try await carried()
        XCTAssertTrue(after.isEmpty, "\(after)")
    }
}

/// A constant in an image based at 0 is no address, though Ghidra may make a
/// reference of it. BootScriptExecutorDxe's GetApicId tests the x2APIC
/// enable bit with `MOV R8D,0x400`, and Ghidra puts a PARAM reference to 0x400
/// on it — where AsmReadCr2 starts. Counted as a callee, it made GetApicId's
/// callees differ from its registry entry's, so the entry no longer took the
/// body and its own name refused every publish (issue 787b26b6). Needs Ghidra
/// and `GHIDRA_BOOTSCRIPT_MODULE`, the BootScriptExecutorDxe image of the
/// Legion 5 dump.
final class GhidraOwnerImmediateReferenceTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_BOOTSCRIPT_MODULE"] else {
            throw XCTSkip("GHIDRA_BOOTSCRIPT_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerImmediateReference-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerImmediateReferenceTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "BootScriptExecutorDxe")
    }

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func read(_ path: String) async throws -> [String: Any] {
        let data = try await host.read(module, path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAConstantInAnImageAtZeroIsNoCallee() async throws {
        let instructions = try await read("/v1/disassembly/0x6004?limit=80")["instructions"] as? [[String: Any]] ?? []
        let mask = try XCTUnwrap(instructions.first { ($0["address"] as? String)?.uppercased() == "0X601C" },
                                 "\(instructions.prefix(8))")
        // The live project has a function there (AsmReadCr2); a fresh one
        // may have only its instructions, which read as "code at 0x400".
        try await host.take(module)
        _ = try await host.write(module, "/v1/create/function", body: try JSONSerialization.data(
            withJSONObject: ["address": "0x400"]))
        let atMask = try await read("/v1/function/0x400")
        let maskName = try XCTUnwrap(atMask["name"] as? String, "\(atMask.keys)")

        try await host.take(module)
        _ = try await host.write(module, "/v1/library/candidate", body: try JSONSerialization.data(
            withJSONObject: ["items": [["address": "0x6004", "kind": "edk2"]]]))
        let library = try await read("/v1/library")
        let entries = (library["entries"] as? [[String: Any]] ?? []) + (library["below_bar"] as? [[String: Any]] ?? [])
        let entry = try XCTUnwrap(entries.first { ($0["address"] as? String)?.uppercased() == "0X6004" },
                                  "\(entries.compactMap { $0["address"] })")
        let callees = (entry["callees"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertFalse(callees.contains(maskName) || callees.contains("code at 0x400"), "\(mask) \(maskName) \(callees)")
        XCTAssertFalse(callees.isEmpty, "its calls stay: \(entry)")
        XCTAssertEqual(entry["data_references"] as? [String], [], "\(entry)")
    }

    /// In an image based at zero a constant can equal a code address, and
    /// the analysis gives the operand a reference there, so the C prints
    /// `&LAB_…` for a status code (issue 7d8fd720). A review naming the value
    /// names that operand too: it is an immediate, and the false reference
    /// goes. 0x601C holds the mask 0x400, which the analysis took for code.
    func testAConstantTakenForAnAddressTakesAnEquate() async throws {
        let before = try await read("/v1/disassembly/0x6004?limit=80")["instructions"] as? [[String: Any]] ?? []
        let mask = try XCTUnwrap(before.first { ($0["address"] as? String)?.uppercased() == "0X601C" })
        XCTAssertFalse((mask["references"] as? [[String: Any]] ?? []).isEmpty, "the premise: a reference to 0x400 \(mask)")

        try await host.take(module)
        let data = try await host.write(module, "/v1/set/equate", body: try JSONSerialization.data(withJSONObject: [
            "name": "TEST_MASK_0400", "value": "0x400", "functions": ["0x6004"]]))
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let applied = (answer["applied"] as? [[String: Any]] ?? []).compactMap { ($0["address"] as? String)?.uppercased() }
        XCTAssertTrue(applied.contains("0X601C"), "named as an immediate: \(answer)")
        let refused = (answer["not_immediate"] as? [[String: Any]] ?? []).compactMap { ($0["address"] as? String)?.uppercased() }
        XCTAssertFalse(refused.contains("0X601C"), "\(answer)")

        let after = try await read("/v1/disassembly/0x6004?limit=80")["instructions"] as? [[String: Any]] ?? []
        let named = try XCTUnwrap(after.first { ($0["address"] as? String)?.uppercased() == "0X601C" })
        XCTAssertTrue((named["references"] as? [[String: Any]] ?? []).isEmpty, "the false reference went: \(named)")
        XCTAssertNotNil(answer["address_references_dropped"], "\(answer)")
        let c = try await read("/v1/function/0x6004")["c"] as? String ?? ""
        XCTAssertTrue(c.contains("TEST_MASK_0400"), "the C prints the name: \(c)")
        XCTAssertFalse(c.contains("LAB_00000400") || c.contains("FUN_00000400"), "not an address: \(c)")
    }
}
