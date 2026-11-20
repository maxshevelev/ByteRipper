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
}
