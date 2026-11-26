import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Reading and naming an ITE EC image (`GHIDRA_EC_MODULE`) the way NDS32
/// code needs it: the version string ends where its text does, so the code
/// after it decodes (issue e9a5c336); a datum reads as code on request with
/// the program unchanged; a constant built by `sethi`/`ori` takes a name
/// (issue a79c591d). A run without the image or Ghidra skips.
final class GhidraHostECReadTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testVersionStringDisassemblyOverDataAndAChainedConstantEquate() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECReadTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostECReadTests"), writer: store)
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
        func rows(_ answer: [String: Any]) -> [[String: Any]] { answer["instructions"] as? [[String: Any]] ?? [] }

        // e9a5c336 (a): the version string is its 16 characters, and 0xA0 is code.
        func version() async throws -> [String: Any]? {
            let listed = try await read("/v1/data?limit=5000")
            return (listed["data"] as? [[String: Any]] ?? []).first { $0["address"] as? String == "0x90" }
        }
        let datum = try await version()
        XCTAssertEqual(datum?["type"] as? String, "string", "\(datum as Any)")
        let calls = try await read("/v1/xrefs?to=0xA0")
        XCTAssertTrue((calls["references"] as? [[String: Any]] ?? []).contains { $0["from"] as? String == "0x38F2" },
                      "the jral5 in ResetEntry calls 0xA0: \(calls)")
        XCTAssertEqual(datum?["length"] as? Int, 16, "\(datum as Any)")
        let atA0 = try await read("/v1/disassembly/0xA0?limit=2")
        XCTAssertNil(atA0["undecoded"], "0xA0 is decoded by the analysis: \(atA0)")
        XCTAssertEqual(rows(atA0).first?["address"] as? String, "0xA0", "\(atA0)")
        XCTAssertTrue((rows(atA0).first?["text"] as? String ?? "").hasPrefix("push25"), "\(atA0)")

        // e9a5c336 (b): defined data reads as code, read only, and says so.
        let over = try await read("/v1/disassembly/0x90?limit=3")
        XCTAssertEqual(over["undecoded"] as? Bool, true, "\(over)")
        XCTAssertNotNil(over["over_data"], "\(over)")
        XCTAssertFalse(rows(over).isEmpty, "\(over)")
        let after = try await version()
        XCTAssertEqual(after?["length"] as? Int, 16, "the datum stays: \(after as Any)")

        // a79c591d: 0x80001, built by sethi/ori/ori ending at 0x3862, named.
        try await host.take(module)
        _ = try await post("/v1/set/data", ["address": "0x80000", "name": "TaskEventPending", "type": "byte[32]"])
        let named = try await post("/v1/set/equate", ["address": "0x3862", "value": "0x80001",
                                                      "name": "DLMB_BASE_80000_ENABLE", "enum": "NDS32_LMB_VALUE"])
        XCTAssertEqual(named["name"] as? String, "DLMB_BASE_80000_ENABLE", "\(named)")
        let c = try await read("/v1/function/0x3800")
        XCTAssertTrue("\(c)".contains("DLMB_BASE_80000_ENABLE"), "\(c)")
        XCTAssertFalse("\(c)".contains("TaskEventPending + 1"), "\(c)")
    }

    /// Issue 3fcfda14: a rodata table reads as bytes and as 32-bit values,
    /// the cap holds, and an address outside memory is refused.
    func testBytesReadsATableAsValues() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECReadTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostECReadTests"), writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }

        let data = try await host.read(module, "/v1/bytes?address=0x239F8&length=0x2C&unit=4")
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(answer["address"] as? String, "0x239F8", "\(answer)")
        XCTAssertEqual(answer["length"] as? Int, 0x2C, "\(answer)")
        XCTAssertNil(answer["truncated"], "\(answer)")
        XCTAssertEqual((answer["hex"] as? String)?.split(separator: " ").count, 0x2C, "\(answer)")
        let values = answer["values"] as? [String] ?? []
        XCTAssertEqual(values.count, 11, "\(answer)")
        XCTAssertEqual(Array(values.prefix(4)), ["0x00F01C01", "0x00F01C03", "0x00F01C02", "0x00F01C00"], "\(answer)")

        func refused(_ call: String) async -> String? {
            do { _ = try await host.read(module, call); return nil } catch { return "\(error)" }
        }
        let over = await refused("/v1/bytes?address=0x239F8&length=4097")
        XCTAssertTrue(over?.contains("4096") == true, "the cap: \(over ?? "answered")")
        let outside = await refused("/v1/bytes?address=0xFFFFFFF0&length=4")
        XCTAssertTrue(outside?.contains("not in the program's memory") == true, "\(outside ?? "answered")")
    }
}
