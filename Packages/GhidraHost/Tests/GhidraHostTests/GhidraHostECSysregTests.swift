import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// System registers of an ITE EC image (`GHIDRA_EC_MODULE`, NDS32).
///
/// NDS32's SLEIGH puts the system registers in a space of their own,
/// `csreg`, addressed in 4-byte words: `mtsr a0,0x0138` (DLMB) at 0x3866
/// refers to csreg:0x138, byte offset 0x4E0. That is no reference into the
/// flash or the RAM: the Isr_Lvl stubs at 0x4AA–0x532 have no reference from
/// an `mtsr`/`mfsr` (issue 3b4b2af9).
///
/// The DLMB value 0x80001 built by `sethi`/`ori`/`ori` (0x385A–0x3862) and
/// written by that `mtsr` prints as `TaskEventPending + 1` once RAM 0x80000
/// is a UINT8[32]: the decompiler lets a constant point into the middle of an
/// array of characters, and UINT8 is one. The equate is placed on the
/// constant of the C decompiled without pointer inference, and the patched
/// decompiler (equates-1) keeps it a value (issue a79c591d).
final class GhidraHostECSysregTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testSystemRegistersAreNoMemoryAndTheirValueTakesAnEquate() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard let install = try? GhidraInstall.find() else { throw XCTSkip("no Ghidra on this machine") }
        guard install.decompilerPatch?.contains("equates-1") == true else {
            throw XCTSkip("\(install.home.path) has no equates-1 decompiler patch (Scripts/make-patched-ghidra.sh)")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECSysregTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostECSysregTests"), writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }

        func json(_ data: Data) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func read(_ call: String) async throws -> [String: Any] { try json(try await host.read(module, call)) }
        func post(_ call: String, _ body: [String: Any]) async throws -> [String: Any] {
            try json(try await host.write(module, call, body: try JSONSerialization.data(withJSONObject: body)))
        }
        func references(_ answer: [String: Any]) -> [[String: Any]] { answer["references"] as? [[String: Any]] ?? [] }

        // 3b4b2af9: no mtsr/mfsr refers into the stubs' flash.
        var sysregs = Set<String>()
        var next: String? = "0x400"
        while let at = next, Int(at.dropFirst(2), radix: 16)! < 0x540 {
            let page = try await read("/v1/disassembly/\(at)?limit=64")
            for row in page["instructions"] as? [[String: Any]] ?? [] {
                let text = row["text"] as? String ?? ""
                if text.hasPrefix("mtsr") || text.hasPrefix("mfsr") { sysregs.insert(row["address"] as? String ?? "") }
            }
            next = page["next"] as? String
        }
        sysregs.insert("0x3866")
        for stub in stride(from: 0x4AA, to: 0x534, by: 2) {
            let to = try await read("/v1/xrefs?to=0x\(String(stub, radix: 16, uppercase: true))")
            for reference in references(to) {
                XCTAssertFalse(sysregs.contains(reference["from"] as? String ?? ""), "\(reference)")
            }
        }
        let at4E0 = try await read("/v1/xrefs?to=0x4E0")
        XCTAssertTrue(references(at4E0).isEmpty, "\(at4E0)")

        // a79c591d: the reporter's state, then the equate.
        try await host.take(module)
        _ = try await post("/v1/type", ["c": "typedef unsigned char UINT8;"])
        _ = try await post("/v1/set/data", ["address": "0x80000", "name": "TaskEventPending", "type": "UINT8[32]"])
        let before = "\(try await read("/v1/function/0x3800"))"
        XCTAssertTrue(before.contains("TaskEventPending + 1"), "the state the issue was filed on: \(before)")
        let named = try await post("/v1/set/equate", ["address": "0x3862", "value": "0x80001",
                                                      "name": "DLMB_BASE_80000_ENABLE", "enum": "NDS32_LMB_VALUE"])
        XCTAssertEqual(named["in_c"] as? Bool, true, "\(named)")
        let c = "\(try await read("/v1/function/0x3800"))"
        XCTAssertTrue(c.contains("_dlmb = DLMB_BASE_80000_ENABLE;"), c)
        XCTAssertFalse(c.contains("TaskEventPending + 1"), c)
        XCTAssertTrue(c.contains("= TaskEventPending;"), "the RAM pointer stays a pointer: \(c)")
    }
}
