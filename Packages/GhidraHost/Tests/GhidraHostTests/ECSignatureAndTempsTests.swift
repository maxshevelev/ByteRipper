import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// An EC (NDS32) image (`GHIDRA_EC_MODULE`) reviewed the way the issues
/// asked: EDK2's base types read in a signature, and an unknown one is named
/// (issue fe4bc8b0); every value of an unnamed decompiler temporary is listed
/// by where it is written and named in one `items` call (issue cf7016bd). A
/// run without the image or Ghidra skips.
final class ECSignatureAndTempsTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func made() async throws -> (GhidraHost, SHA256Digest) {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ECSignatureAndTempsTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "ECSignatureAndTempsTests"), writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        try await host.take(module)
        return (host, module)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBaseTypesInASignatureAndAnUnknownTypeNamed() async throws {
        let (host, module) = try await made()
        defer { Task { await host.stop(module) } }
        func signature(_ text: String) async throws -> [String: Any] {
            try json(try await host.write(module, "/v1/set/signature", body: try JSONSerialization.data(
                withJSONObject: ["address": "0xB58A", "signature": text])))
        }
        func refusal(_ text: String) async -> String {
            do { _ = try await signature(text); return "answered" } catch { return "\(error)" }
        }
        let bool = try await signature("BOOL UtilMemEqual(const UINT8 *A, const UINT8 *B, UINT8 Count)")
        XCTAssertTrue((bool["signature"] as? String ?? "\(bool)").hasPrefix("BOOL UtilMemEqual(UINT8 * A"), "\(bool)")
        let boolean = try await signature("BOOLEAN UtilMemEqual(CONST UINT8 *A, CONST CHAR8 *B, UINTN Count)")
        XCTAssertTrue("\(boolean)".contains("BOOLEAN UtilMemEqual"), "\(boolean)")
        XCTAssertTrue("\(boolean)".contains("UINTN Count"), "\(boolean)")
        let definition = try json(try await host.read(module, "/v1/type?name=UINTN"))
        XCTAssertTrue("\(definition)".contains("/UINTN"), "\(definition)")
        for text in ["FOO_T UtilMemEqual(UINT8 *A, UINT8 Count)", "BOOL UtilMemEqual(FOO_T *A, UINT8 Count)"] {
            let refused = await refusal(text)
            XCTAssertTrue(refused.contains("unknown type `FOO_T`"), refused)
            XCTAssertTrue(refused.contains("BOOLEAN, BOOL, INT8, UINT8"), refused)
        }
    }

    func testEveryValueOfATemporaryNamedInOneCall() async throws {
        let (host, module) = try await made()
        defer { Task { await host.stop(module) } }
        func locals() async throws -> [[String: Any]] {
            try json(try await host.read(module, "/v1/function/0x12DD0"))["locals"] as? [[String: Any]] ?? []
        }
        func unnamed(_ list: [[String: Any]]) -> [[String: Any]] {
            list.filter { ($0["named"] as? Bool) == false }
        }
        func temps(_ list: [[String: Any]]) -> [[String: Any]] {
            unnamed(list).filter { ($0["storage"] as? String) == "HASH:00000000:1" }
        }
        // The register reads named one by one, as the reporter did, until
        // the decompiler's temporary shows.
        var round = 0
        while round < 12 {
            let now = try await locals()
            if !temps(now).isEmpty { break }
            let target = try XCTUnwrap(unnamed(now).first, "nothing left unnamed: \(now)")
            _ = try await host.write(module, "/v1/rename/variable", body: try JSONSerialization.data(withJSONObject: [
                "function": "0x12DD0", "storage": target["storage"]!, "first_use": target["first_use"]!,
                "name": "Register\(round)", "type": "UINT8"]))
            round += 1
        }
        let listed = temps(try await locals())
        print("ECSignatureAndTempsTests: \(listed.count) values of the temporary listed")
        let starts = Set(listed.compactMap { $0["first_use"] as? String })
        XCTAssertGreaterThan(listed.count, 5, "every value of the temporary at once: \(listed)")
        XCTAssertEqual(starts.count, listed.count, "each by its own first use: \(listed)")
        let items: [[String: Any]] = listed.enumerated().map { index, local in
            ["function": "0x12DD0", "storage": "HASH:00000000:1", "first_use": local["first_use"]!,
             "name": "PortRead\(index)", "type": "UINT8"]
        }
        let answer = try json(try await host.write(module, "/v1/rename/variables", body: try JSONSerialization.data(
            withJSONObject: ["items": items])))
        let results = answer["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.count, items.count, "\(answer)")
        XCTAssertTrue(results.allSatisfy { $0["ok"] as? Bool == true }, "\(answer)")
        let after = try await locals()
        XCTAssertTrue(temps(after).isEmpty, "none left unnamed on the temporary: \(temps(after))")
        let named = Set(after.compactMap { $0["name"] as? String })
        for index in items.indices { XCTAssertTrue(named.contains("PortRead\(index)"), "PortRead\(index): \(after)") }
    }
}
