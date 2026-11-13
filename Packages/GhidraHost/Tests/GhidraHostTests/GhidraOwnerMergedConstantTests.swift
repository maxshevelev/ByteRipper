import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A constant the decompiler merged from two operands — PiSmmCommunicationPei
/// compares a UINT64 signature as two 32-bit halves, and the C prints one
/// 64-bit number — is named on the C's constant itself, by its hash, as an
/// equate on either half never shows. Needs Ghidra and
/// `GHIDRA_MERGED_CONSTANT_MODULE`, the PiSmmCommunicationPei image.
final class GhidraOwnerMergedConstantTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_MERGED_CONSTANT_MODULE"] else {
            throw XCTSkip("GHIDRA_MERGED_CONSTANT_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerMergedConstant-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerMergedConstantTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "PiSmmCommunicationPei")
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

    private func c(_ entry: String) async throws -> String {
        try await read("/v1/function/\(entry)")["c"] as? String ?? ""
    }

    func testAMergedConstantIsNamedInTheC() async throws {
        // The function holding the low half, 'SMMS', as an immediate.
        var found: (entry: String, low: String)?
        for function in try await read("/v1/functions")["functions"] as? [[String: Any]] ?? [] {
            guard let entry = function["entry"] as? String else { continue }
            let instructions = try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
            if let low = instructions.first(where: { ($0["text"] as? String ?? "").lowercased().contains("0x534d4d53") }) {
                found = (entry, try XCTUnwrap(low["address"] as? String))
                break
            }
        }
        let (entry, low) = try XCTUnwrap(found, "no instruction holds 0x534D4D53")
        // As the review typed it: Smst in ECX, the signature a UINT64 on the stack.
        try await post("/v1/set/signature", ["address": entry,
                                              "signature": "void * Lookup(void * Smst, UINT64 Signature)",
                                              "storage": ["ECX:4", "Stack[0x4]:8"], "return_storage": "EAX:4"])
        let merged = try await c(entry)
        guard merged.lowercased().contains("0x34365f33534d4d53") else {
            throw XCTSkip("the decompiler did not merge the halves here:\n\(merged)")
        }

        let named = try await post("/v1/set/equate", [
            "address": low, "value": "0x34365F33534D4D53", "name": "SMM_S3_RESUME_SMM_64",
            "enum": "SMM_S3_RESUME_SIGNATURE", "comment": "SIGNATURE_64('S','M','M','S','3','_','6','4')"])
        XCTAssertEqual(named["in_c_only"] as? Bool, true, "\(named)")
        XCTAssertEqual(named["in_c"] as? Bool, true, "\(named)")
        let shown = try await c(entry)
        XCTAssertTrue(shown.contains("SMM_S3_RESUME_SMM_64"), shown)
        XCTAssertFalse(shown.lowercased().contains("0x34365f33534d4d53"), shown)

        // A redecode of the instruction the name stands on keeps it.
        let at = try XCTUnwrap(named["address"] as? String)
        let listed = try await read("/v1/disassembly/\(entry)")["instructions"] as? [[String: Any]] ?? []
        let index = try XCTUnwrap(listed.firstIndex { ($0["address"] as? String)?.lowercased() == at.lowercased() }, at)
        let next = try XCTUnwrap(listed[index + 1]["address"] as? String)
        let redecoded = try await post("/v1/redecode", ["start": at, "end": next])
        XCTAssertNil(redecoded["marks_lost"], "\(redecoded)")
        let kept = try await c(entry)
        XCTAssertTrue(kept.contains("SMM_S3_RESUME_SMM_64"), kept)

        // An empty name takes it off again.
        let removed = try await post("/v1/set/equate", ["address": low, "value": "0x34365F33534D4D53", "name": ""])
        XCTAssertEqual(removed["removed"] as? Bool, true, "\(removed)")
        let bare = try await c(entry)
        XCTAssertTrue(bare.lowercased().contains("0x34365f33534d4d53"), bare)

        // A value the C does not hold is refused as before.
        do {
            try await post("/v1/set/equate", ["address": low, "value": "0x1122334455667788", "name": "NOT_HERE"])
            XCTFail("a value nowhere in the C is refused")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
        }
    }
}
