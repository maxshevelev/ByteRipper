import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// `ghidra_profile`'s read: the profile a module's kept facts derive, for an
/// EC module (`GHIDRA_EC_MODULE`) and a UEFI one (`GHIDRA_TYPE_MODULE`). A
/// run without the image or Ghidra skips.
final class GhidraHostProfileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostProfile-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func image(_ variable: String) throws -> Data {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("\(variable) is not set")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func made(_ image: Data, name: String) async throws -> (GhidraHost, ContentStore, SHA256Digest) {
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostProfileTests"), writer: store)
        _ = try await host.create(module: image, name: name, source: .init(document: "dump", node: "0.0.1"))
        return (host, store, GhidraHost.moduleDigest(of: image))
    }

    private func readProfile(_ host: GhidraHost, _ module: SHA256Digest) async throws -> [String: Any] {
        let data = try await host.read(module, "/v1/profile")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnECModuleReadsTheEcProfile() async throws {
        let (host, store, module) = try await made(try image("GHIDRA_EC_MODULE"), name: "ItEcNmD562")
        defer { Task { await host.stop(module) } }
        var answer = try await readProfile(host, module)
        XCTAssertEqual(answer["kind"] as? String, "EC")
        XCTAssertEqual(answer["stamp"] as? String, "ec-ite-nds32@2")
        XCTAssertEqual(answer["type_group"] as? String, "Nds32")
        XCTAssertNil(answer["note"])
        XCTAssertNil(answer["latest_revision_profile"])
        let profile = try XCTUnwrap(answer["profile"] as? [String: Any])
        XCTAssertEqual(profile["skill"] as? String, "ghidra-ec")
        XCTAssertEqual((profile["records"] as? [[String: Any]])?.compactMap { $0["id"] as? String },
                       ["irq_map", "host_commands", "ec_ram", "smbus_peers", "gpio", "eflash_area"])
        XCTAssertTrue(((profile["inapplicable_tools"] as? [[String: Any]]) ?? [])
            .contains { $0["tool"] as? String == "ghidra_set_interfaces" && ($0["hint"] as? String)?.isEmpty == false })
        XCTAssertFalse((profile["gates"] as? [Any] ?? []).isEmpty)
        // The Code panel's part, an addition under `panel`: the EC hides
        // interfaces, POST codes, strings and status codes, and every record has a section.
        let panel = try XCTUnwrap(profile["panel"] as? [String: Any])
        XCTAssertEqual((panel["built_in"] as? [[String: Any]])?.compactMap { $0["shown"] as? Bool }, [false, false, false, false])
        XCTAssertTrue(((profile["records"] as? [[String: Any]]) ?? []).allSatisfy { $0["panel"] != nil })

        // A revision that recorded its profile is answered as such.
        let review = try store.putObject(Data(#"{"schema":1}"#.utf8))
        _ = try store.recordRevision(module: module, reading: AnalysisReading(rev: 1, review: review,
                                                                             profile: "ec-ite-nds32@1"))
        answer = try await readProfile(host, module)
        XCTAssertEqual(answer["latest_revision"] as? Int, 1)
        XCTAssertEqual(answer["latest_revision_profile"] as? String, "ec-ite-nds32@1")
    }

    func testAUEFIModuleReadsTheUefiProfile() async throws {
        let (host, _, module) = try await made(try image("GHIDRA_TYPE_MODULE"), name: "PeiVariable")
        defer { Task { await host.stop(module) } }
        let answer = try await readProfile(host, module)
        XCTAssertTrue(["PE32", "TE"].contains(answer["kind"] as? String ?? ""), "\(answer)")
        XCTAssertEqual(answer["stamp"] as? String, "uefi@1")
        XCTAssertEqual(answer["type_group"] as? String, "Ia32", "PeiVariable is a 32-bit PEI module")
        XCTAssertNil(answer["latest_revision"])
        let profile = try XCTUnwrap(answer["profile"] as? [String: Any])
        XCTAssertEqual(profile["skill"] as? String, "ghidra-uefi")
        XCTAssertEqual((profile["records"] as? [[String: Any]])?.compactMap { $0["id"] as? String },
                       ["interfaces", "post_codes"])
        XCTAssertEqual((profile["inapplicable_tools"] as? [[String: Any]])?.compactMap { $0["tool"] as? String },
                       ["register_registry"])
    }
}
