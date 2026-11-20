import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A named constant is a value even where a label sits at the same address.
///
/// In IhisiServicesSmm the jump target 0x802B, once named CommandLookupDone,
/// made some 40 handlers print `(UINTN)&CommandLookupDone` for the status
/// 0x802B they had named, with no reference to the address left: the
/// decompiler's constant-pointer rule takes any symbol at a constant's value,
/// and never looks at the equate (issues 7d8fd720, 7a68b7e1). The decompiler
/// patch equates-1 lets a constant with an equate be.
///
/// IdeBusPei is based at zero, and its entry 0x272 loads `MOV EBX,0x1d30`,
/// which a name at 0x1D30 turns into a pointer on a stock decompiler. Needs
/// `GHIDRA_BYVALUE_MODULE` and a Ghidra made by Scripts/make-patched-ghidra.sh;
/// `GHIDRA_STOCK_DECOMPILER=check` runs it on another, to see it fail there.
final class GhidraOwnerEquateNotPointerTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_BYVALUE_MODULE"] else {
            throw XCTSkip("GHIDRA_BYVALUE_MODULE is not set")
        }
        let install = try GhidraInstall.find()
        guard install.decompilerPatch?.contains("equates-1") == true
            || ProcessInfo.processInfo.environment["GHIDRA_STOCK_DECOMPILER"] == "check" else {
            throw XCTSkip("\(install.home.path) has no equates-1 decompiler patch (Scripts/make-patched-ghidra.sh)")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerEquateNotPointer-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "GhidraOwnerEquateNotPointerTests"),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "IdeBusPei")
    }

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func c(_ function: String) async throws -> String {
        let data = try await host.read(module, "/v1/function/\(function)")
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return answer["c"] as? String ?? ""
    }

    func testANamedConstantIsNoPointerToALabelAtItsValue() async throws {
        try await host.take(module)
        _ = try await host.write(module, "/v1/set/data", body: try JSONSerialization.data(withJSONObject: [
            "address": "0x1D30", "name": "TestLabelAt1D30"]))
        let before = try await c("0x272")
        XCTAssertTrue(before.contains("TestLabelAt1D30"), "the premise: the constant reads as the label \(before)")

        _ = try await host.write(module, "/v1/set/equate", body: try JSONSerialization.data(withJSONObject: [
            "name": "TEST_VALUE_1D30", "value": "0x1D30", "address": "0x32A"]))
        let after = try await c("0x272")
        XCTAssertTrue(after.contains("TEST_VALUE_1D30"), "\(after)")
        XCTAssertFalse(after.contains("TestLabelAt1D30"), "\(after)")
    }
}
