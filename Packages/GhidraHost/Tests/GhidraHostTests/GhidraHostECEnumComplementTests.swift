import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A value that is no member of an enum of codes prints as a number, not as
/// the complement of another member (issue 54161725).
///
/// The ITE EC image (`GHIDRA_EC_MODULE`, NDS32) dispatches a host command at
/// 0x1E42C and bounds it with `< 0x85`. With the parameter an `EC_HOST_CMD`
/// that holds 0x7A, a stock decompiler prints the bound `~EcCmd_Flags80302_7A`
/// (0x85 is `~0x7A` in a byte). The decompiler patch enum-values-2 keeps the
/// complement, and an OR of members, for an enum of single-bit flags only. Needs a Ghidra made by
/// Scripts/make-patched-ghidra.sh; `GHIDRA_STOCK_DECOMPILER=check` runs it on
/// another, to see it fail there.
final class GhidraHostECEnumComplementTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testANonMemberOfACodeEnumIsANumberAndAFlagComplementStays() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard let install = try? GhidraInstall.find() else { throw XCTSkip("no Ghidra on this machine") }
        guard install.decompilerPatch?.contains("enum-values-2") == true
            || ProcessInfo.processInfo.environment["GHIDRA_STOCK_DECOMPILER"] == "check" else {
            throw XCTSkip("\(install.home.path) has no enum-values-2 decompiler patch (Scripts/make-patched-ghidra.sh)")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECEnumComplementTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostECEnumComplementTests"),
                              writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }
        try await host.take(module)

        func post(_ call: String, _ body: [String: Any]) async throws {
            _ = try await host.write(module, call, body: try JSONSerialization.data(withJSONObject: body))
        }
        func c() async throws -> String {
            let data = try await host.read(module, "/v1/function/0x1E42C")
            let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return answer["c"] as? String ?? ""
        }

        try await post("/v1/type", ["c": """
            typedef enum _EC_HOST_CMD : unsigned char {
                EcCmd_Flags80302_7A = 0x7A, EcCmd_ReadRam_7E = 0x7E, EcCmd_AcpiRdEc_80 = 0x80,
                EcCmd_AcpiWrEc_81 = 0x81, EcCmd_Set803C5Ack_8C = 0x8C
            } EC_HOST_CMD;
            """])
        try await post("/v1/set/signature", ["address": "0x1E42C", "signature": "void HostCommand(EC_HOST_CMD Command)"])
        let codes = try await c()
        XCTAssertTrue(codes.contains("EcCmd_AcpiWrEc_81"), "the premise: the enum prints \(codes)")
        XCTAssertFalse(codes.contains("~EcCmd_"), "\(codes)")
        XCTAssertTrue(codes.contains("Command < 0x85"), "\(codes)")

        // A list of values whose members OR to the bound (0x80 | 0x05): still a number, not
        // two members ORed (issue ed3655a2).
        try await post("/v1/type", ["c": """
            typedef enum _EC_TEST_STATE : unsigned char {
                TestState_05 = 0x05, TestState_80 = 0x80, TestState_7A = 0x7A
            } EC_TEST_STATE;
            """])
        try await post("/v1/set/signature", ["address": "0x1E42C", "signature": "void HostCommand(EC_TEST_STATE Command)"])
        let states = try await c()
        XCTAssertFalse(states.contains("TestState_05|") || states.contains("|TestState_05"), "\(states)")
        XCTAssertTrue(states.contains("Command < 0x85"), "\(states)")

        // Single-bit flags whose OR is 0x7A: the bound still reads as their complement.
        try await post("/v1/type", ["c": """
            typedef enum _EC_TEST_FLAGS : unsigned char {
                TestFlag02 = 0x02, TestFlag08 = 0x08, TestFlag10 = 0x10, TestFlag20 = 0x20, TestFlag40 = 0x40
            } EC_TEST_FLAGS;
            """])
        try await post("/v1/set/signature", ["address": "0x1E42C", "signature": "void HostCommand(EC_TEST_FLAGS Command)"])
        let flags = try await c()
        XCTAssertTrue(flags.contains("Command < ~("), "\(flags)")
        XCTAssertTrue(flags.contains("TestFlag40"), "\(flags)")
    }
}
