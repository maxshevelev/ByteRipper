import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A signature with storage of its own on an X64 function — Type in ECX, four
/// bytes, as the Status Code Router's ReportDispatcher takes it — is stored as
/// the live function shows it: the same signature, the same C. In issue
/// 6d64f49d the stored artifact lost parameter 0 and printed in_ECX: a rename
/// of the local RCX:8 at the entry had made Ghidra delete the parameter.
/// Needs Ghidra and `GHIDRA_X64_MODULE`, the DxeCore image.
final class GhidraOwnerCustomStorageExportTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var store: ContentStore!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_X64_MODULE"] else {
            throw XCTSkip("GHIDRA_X64_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerCustomStorageExport-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerCustomStorageExportTests"),
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

    private func storedRow(_ entry: String) throws -> [String: Any]? {
        let manifest = try XCTUnwrap(try store.analysis(module: module))
        let artifact = try XCTUnwrap(JSONSerialization.jsonObject(with: try store.object(manifest.artifact.sha256))
                                     as? [String: Any])
        return (artifact["functions"] as? [[String: Any]] ?? []).first { $0["entry"] as? String == entry }
    }

    func testACustomStorageSignatureIsStoredAsLive() async throws {
        let listed = try await read("/v1/functions")["functions"] as? [[String: Any]] ?? []
        let function = try XCTUnwrap(listed.first {
            ($0["size"] as? Int ?? 0) > 80 && ($0["thunk"] as? Bool) != true && ($0["external"] as? Bool) != true
        })
        let entry = try XCTUnwrap(function["entry"] as? String)
        try await post("/v1/set/signature", [
            "address": entry,
            "signature": "EFI_STATUS Dispatch(UINT32 Type, UINT32 Value, UINT32 Instance, EFI_GUID * CallerId, void * Data)",
            "storage": ["ECX:4", "EDX:4", "R8D:4", "R9:8", "Stack[0x28]:8"], "return_storage": "RAX:8"])
        // As the review did: RCX as a whole, from the entry, named and typed.
        // Ghidra would settle the overlap with ECX:4 by deleting Type, so the
        // rename is refused and nothing changes.
        do {
            try await post("/v1/rename/variable", ["function": entry, "first_use": entry, "storage": "RCX:8",
                                                    "name": "TypeOrAlignPad", "type": "UINT64"])
            XCTFail("a local over a parameter's register from the entry is refused")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
            XCTAssertTrue("\(error)".contains("would delete the parameter Type (ECX:4)"), "\(error)")
        }
        let live = try await read("/v1/function/\(entry)")
        let liveSignature = try XCTUnwrap(live["signature"] as? String)
        XCTAssertTrue(liveSignature.contains("UINT32 Type"), liveSignature)

        _ = try await host.publish(module, by: "agent")
        let row = try XCTUnwrap(try storedRow(entry))
        XCTAssertEqual(row["signature"] as? String, liveSignature, "\(row["signature"] ?? "")")
        XCTAssertEqual(row["custom_storage"] as? Bool, true)

        let after = try await read("/v1/function/\(entry)")
        XCTAssertEqual(after["signature"] as? String, liveSignature, "the publish leaves the live function as it was")
        let storage = (after["parameters"] as? [[String: Any]] ?? []).map { $0["storage"] as? String ?? "" }
        XCTAssertEqual(storage, ["ECX:4", "EDX:4", "R8D:4", "R9:8", "Stack[0x28]:8"])
        let storedC = row["c"] as? String ?? ""
        XCTAssertFalse(storedC.contains("in_ECX"), storedC)
    }
}
