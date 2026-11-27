import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Three EC fixes on the ITE image (`GHIDRA_EC_MODULE`, NDS32):
/// `movi a1,-0x80` stored by `sbi333` names the byte 0x80 even in a new
/// four-byte enum; the GPIO registers registers.h does not list but the
/// firmware uses carry names; `filter: "unfinished"` keeps the address range,
/// and its summary counts only the functions in it.
final class GhidraOwnerECStoreWidthTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testByteStoreNarrowsANewEnumAndTheRangeHoldsWithTheFilter() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerECStoreWidthTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraOwnerECStoreWidthTests"),
                              writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }
        try await host.take(module)
        func post(_ call: String, _ body: [String: Any]) async throws -> [String: Any] {
            let data = try await host.write(module, call, body: try JSONSerialization.data(withJSONObject: body))
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        func read(_ call: String) async throws -> [String: Any] {
            let answer = try await host.read(module, call)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
        }

        // The enum does not exist yet: the first member is the stored byte.
        for address in ["0xADDC", "0xAE92", "0x12BE0"] {
            let answer = try await post("/v1/set/equate", ["address": address, "operand": 1,
                                                           "name": "GPCR_INPUT", "enum": "GPIO_GPCR_MODE"])
            XCTAssertEqual(answer["value"] as? String, "0x80", "\(address): \(answer)")
        }
        let type = String(decoding: try await host.read(module, "/v1/type?name=GPIO_GPCR_MODE"), as: UTF8.self)
        XCTAssertTrue(type.contains("GPCR_INPUT = 0x80"), type)
        XCTAssertFalse(type.contains("FF80"), type)

        // GPCRD5, a register registers.h leaves out, has its name.
        let data = try await read("/v1/data?limit=5000")
        let names = (data["data"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            if let a = $1["address"] as? String, let n = $1["name"] as? String { $0[a.uppercased()] = n }
        }
        XCTAssertEqual(names.first { $0.key.hasSuffix("F0162D") }?.value, "GPIO_GPCRD5")
        XCTAssertEqual(names.first { $0.key.hasSuffix("F01604") }?.value, "GPIO_GPDRD")

        // The range holds with the filter, and the summary counts only it.
        let listed = try await read("/v1/functions?filter=unfinished&address_from=0xA000&address_to=0xB000&limit=5000")
        let entries = (listed["functions"] as? [[String: Any]] ?? []).compactMap {
            ($0["entry"] as? String ?? $0["address"] as? String).flatMap(CodeAddress.init(hex:))?.value
        }
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { (0xA000...0xB000).contains($0) }, "\(entries)")
        let summary = try XCTUnwrap(listed["summary"] as? [String: Any])
        XCTAssertLessThan(summary["functions"] as? Int ?? .max, 100, "\(summary)")
    }
}
