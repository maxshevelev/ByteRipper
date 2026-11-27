import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// TEMPORARY probe for issues 89b84dd1/ce53fb17. Not to be committed.
final class ProbeIdtBaseTests: XCTestCase {
    func testProbe() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_PROBE_MODULE"] else { throw XCTSkip("no probe") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeIdt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "probe"), writer: store)
        let module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "ChipsetSvcPei")
        defer { Task { await host.stop(module) } }
        func read(_ p: String) async throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: try await host.read(module, p)) as! [String: Any]
        }
        func post(_ p: String, _ o: [String: Any]) async -> String {
            do {
                try await host.take(module)
                let d = try await host.write(module, p, body: try JSONSerialization.data(withJSONObject: o))
                return String(data: d, encoding: .utf8) ?? ""
            } catch { return "ERROR \(error)" }
        }
        var log: [String] = []
        let entry = ProcessInfo.processInfo.environment["PROBE_ENTRY"] ?? "0x9A54BE9"
        func dump(_ title: String) async throws {
            guard let f = try? await read("/v1/function/\(entry)") else { log.append("== \(title): no function"); return }
            log.append("== \(title) purge=\(f["stack_purge"] ?? 0) cc=\(f["calling_convention"] ?? "-")")
            for l in (f["locals"] as? [[String: Any]]) ?? [] {
                log.append("  local \(l["name"] ?? "") \(l["type"] ?? "") \(l["storage"] ?? "") \(l["first_use"] ?? "")")
            }
            log.append(f["c"] as? String ?? "")
        }
        try await dump("fresh")
        if let steps = ProcessInfo.processInfo.environment["PROBE_STEPS"],
           let list = try JSONSerialization.jsonObject(with: Data(steps.utf8)) as? [[String: Any]] {
            for step in list {
                let p = step["path"] as! String
                var body = step; body.removeValue(forKey: "path")
                log.append("-> \(p) \(body)")
                log.append(await post(p, body))
                try await dump("after \(p)")
            }
        }
        try log.joined(separator: "\n").write(toFile: ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "/dev/null",
                                              atomically: true, encoding: .utf8)
    }
}
