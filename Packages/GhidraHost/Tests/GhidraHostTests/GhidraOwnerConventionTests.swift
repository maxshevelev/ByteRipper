import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A signature on a function analysis left at `unknown` settles a convention
/// that takes off the stack what the function's own RET does — on IA32
/// `__cdecl` for a plain RET, as EFIAPI is there — and a target's body is not
/// merged into its own thunk. Needs Ghidra and `GHIDRA_TYPE_MODULE`, the
/// PeiVariable image.
final class GhidraOwnerConventionTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerConvention-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerConventionTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "PeiVariable")
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

    /// A function made where only a table points starts at `unknown`; signed,
    /// it is `__cdecl` with nothing purged when it ends in a plain RET — not the
    /// windows spec's `__stdcall`, which would purge its arguments.
    func testASignedFunctionWithAPlainRetIsCdecl() async throws {
        let gaps = try await read("/v1/gaps")["gaps"] as? [[String: Any]] ?? []
        let body = try XCTUnwrap(gaps.first { $0["verdict"] as? String == "body" }?["body_at"] as? String,
                                 "no gap holds a body: \(gaps)")
        try await post("/v1/create/function", ["address": body])
        let listed = try await read("/v1/disassembly/\(body)")["instructions"] as? [[String: Any]] ?? []
        let returns = listed.compactMap { $0["text"] as? String }.filter { $0.hasPrefix("RET") }
        guard !returns.isEmpty, returns.allSatisfy({ $0 == "RET" }) else {
            throw XCTSkip("the body at \(body) does not end in a plain RET: \(returns)")
        }

        let signed = try await post("/v1/set/signature", [
            "address": body, "signature": "EFI_STATUS Probe(EFI_PEI_SERVICES **PeiServices, VOID *Ppi)"])
        XCTAssertEqual(signed["calling_convention"] as? String, "__cdecl", "\(signed)")
        XCTAssertNil(signed["convention_stays_unknown"], "\(signed)")
        let function = try await read("/v1/function/\(body)")
        XCTAssertNil(function["stack_purge"], "a plain RET purges nothing: \(function)")
        XCTAssertFalse((function["c"] as? String ?? "").contains("Unknown calling convention"), "\(function)")
    }

    /// Ghidra removes a thunk with its target, so the target's body cannot move
    /// into the thunk: the refusal says so, and both stay.
    func testATargetIsNotMergedIntoItsOwnThunk() async throws {
        var found: (thunk: String, target: String)?
        for function in try await read("/v1/functions")["functions"] as? [[String: Any]] ?? [] {
            guard let entry = function["entry"] as? String else { continue }
            let read = try await self.read("/v1/function/\(entry)")
            if let target = (read["thunk_of"] as? [String: Any])?["entry"] as? String {
                found = (entry, target)
                break
            }
        }
        let (thunk, target) = try XCTUnwrap(found, "no function is a thunk")
        do {
            try await post("/v1/merge/functions", ["into": thunk, "from": target])
            XCTFail("a target merged into its thunk is refused")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
            XCTAssertTrue("\(error)".contains("is a thunk of"), "\(error)")
        }
        let entries = (try await read("/v1/functions")["functions"] as? [[String: Any]] ?? [])
            .compactMap { ($0["entry"] as? String)?.lowercased() }
        XCTAssertTrue(entries.contains(thunk.lowercased()) && entries.contains(target.lowercased()), "\(entries)")
    }
}
