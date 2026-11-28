import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// Stubs (issue da4ac97a) and equates over an enum defined again (issue
/// 47a30e81), on an EC (NDS32) image (`GHIDRA_EC_MODULE`); without it or
/// Ghidra they skip.
final class ECStubAndEnumEquateTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func open() async throws -> (GhidraHost, SHA256Digest, ContentStore) {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ECStubAndEnumEquateTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "ECStubAndEnumEquateTests"), writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        try await host.take(module)
        return (host, module, store)
    }

    private func row(_ entry: String, _ store: ContentStore, _ module: SHA256Digest) throws -> [String: Any]? {
        let manifest = try XCTUnwrap(try store.analysis(module: module))
        let list = try json(try store.object(manifest.artifact.sha256))["functions"] as? [[String: Any]] ?? []
        return list.first { ($0["entry"] as? String)?.lowercased() == entry.lowercased() }
    }

    func testAnEmptyBodyIsAStubAndAReviewDecidesOverTheRule() async throws {
        let (host, module, store) = try await open()
        defer { Task { await host.stop(module) } }
        _ = try await host.publish(module, by: "agent")
        // push25/pop25 and nothing else; the one that calls 0x126D0 does work.
        XCTAssertEqual(try row("0x53c0", store, module)?["review_level"] as? String, "stub")
        let caller = try row("0x5d80", store, module)?["review_level"] as? String
        XCTAssertNotNil(caller)
        let unused = try row("0x5868", store, module)
        XCTAssertEqual(unused?["review_level"] as? String, "stub", "\(unused ?? [:])")
        XCTAssertEqual(unused?["unused"] as? Bool, true)

        _ = try await host.write(module, "/v1/rename/function",
                                 body: try JSONSerialization.data(withJSONObject: ["address": "0x53C0", "stub": "not_stub"]))
        _ = try await host.write(module, "/v1/rename/function",
                                 body: try JSONSerialization.data(withJSONObject: ["address": "0x5D80", "stub": "stub"]))
        _ = try await host.publish(module, by: "agent")
        XCTAssertNotEqual(try row("0x53c0", store, module)?["review_level"] as? String, "stub")
        XCTAssertEqual(try row("0x5d80", store, module)?["review_level"] as? String, "stub")
    }

    func testAnEnumDefinedAgainKeepsTheEquatesOfItsMembers() async throws {
        let (host, module, _) = try await open()
        defer { Task { await host.stop(module) } }
        func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            try json(try await host.write(module, path, body: try JSONSerialization.data(withJSONObject: body)))
        }
        // Any instruction with an immediate of four hex digits or more.
        let page = try json(try await host.read(module, "/v1/disassembly/0x7000?count=400"))
        var values: Set<String> = []
        let places = (page["instructions"] as? [[String: Any]] ?? []).compactMap { instruction -> (String, Int, String)? in
            let text = instruction["text"] as? String ?? ""
            guard let match = text.range(of: #"0x[0-9a-fA-F]{3,}$"#, options: .regularExpression),
                  let at = instruction["address"] as? String,
                  values.insert(String(text[match]).lowercased()).inserted else { return nil }
            return (at, text[..<match.lowerBound].filter { $0 == "," }.count, String(text[match]))
        }
        guard places.count >= 2 else { throw XCTSkip("too few immediates") }
        let first = try await post("/v1/set/equate", ["address": places[0].0, "operand": places[0].1,
                                              "name": "KeptMember", "enum": "TEST_EQUATE_ENUM"])
        _ = try await post("/v1/set/equate", ["address": places[1].0, "operand": places[1].1,
                                              "name": "RenamedMember", "enum": "TEST_EQUATE_ENUM"])
        XCTAssertEqual(first["name"] as? String, "KeptMember")
        let again = "enum TEST_EQUATE_ENUM { KeptMember = \(places[0].2), OtherName = \(places[1].2) };"
        let answer = try await post("/v1/type", ["c": again])
        XCTAssertEqual(answer["equates_kept"] as? Int, 1, "\(answer)")
        let orphaned = answer["equates_orphaned"] as? [[String: Any]] ?? []
        XCTAssertEqual(orphaned.first?["member"] as? String, "RenamedMember", "\(answer)")
        let held = try json(try await host.read(module, "/v1/disassembly/\(places[0].0)?count=1"))
        let equates = ((held["instructions"] as? [[String: Any]])?.first { $0["address"] as? String == places[0].0 }?["equates"] as? [[String: Any]]) ?? []
        XCTAssertEqual(equates.first?["name"] as? String, "KeptMember", "\(held)")
    }
}
