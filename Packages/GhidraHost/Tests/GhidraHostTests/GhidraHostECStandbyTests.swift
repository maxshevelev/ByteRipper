import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// `standby` on a Ghidra whose NDS32 language carries nds32-standby-1
/// (`GHIDRA_PATCHED_HOME`), on an ITE EC module (`GHIDRA_EC_MODULE`,
/// ItEcNmD562): issue a29c3b91. Stock reads standby as a branch to itself, so
/// the function at 0x20CD2 ends at 0x20CE2 and decompiles as an endless loop.
/// Made on the patched Ghidra it reaches its return at 0x20CE6; made on stock
/// (the default install) and opened on the patched one, `ec/reapply` gives it
/// that body, and a second run changes nothing. A run without the image or
/// either Ghidra skips.
final class GhidraHostECStandbyTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func setUp() throws -> (image: Data, patched: URL) {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard let home = ProcessInfo.processInfo.environment["GHIDRA_PATCHED_HOME"], !home.isEmpty else {
            throw XCTSkip("GHIDRA_PATCHED_HOME is not set")
        }
        let patched = URL(fileURLWithPath: home)
        guard let install = try? GhidraInstall.find(home: patched),
              install.languagePatch(for: "NDS32")?.split(separator: "+").contains("nds32-standby-1") == true else {
            throw XCTSkip("GHIDRA_PATCHED_HOME has no nds32-standby-1")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECStandbyTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        return (try Data(contentsOf: URL(fileURLWithPath: path)), patched)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The function's body ranges, as `/v1/function` answers them, as text.
    private func function(_ host: GhidraHost, _ module: SHA256Digest, _ address: String) async throws -> [String: Any] {
        try json(try await host.read(module, "/v1/function/\(address)"))
    }

    private func assertGoesOn(_ answer: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let c = answer["c"] as? String ?? "\(answer)"
        XCTAssertTrue(c.contains("standby(1)"), c, file: file, line: line)
        XCTAssertTrue(c.contains("return"), c, file: file, line: line)
        XCTAssertFalse(c.contains("while( true )"), c, file: file, line: line)
    }

    func testAModuleMadeOnThePatchedGhidraReachesItsReturn() async throws {
        let (image, patched) = try setUp()
        let directory = try XCTUnwrap(directory)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   ghidraHome: patched, idle: 300, holder: "GhidraHostECStandbyTests"),
                              writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }
        let hello = try json(try await host.read(module, "/v1/hello"))
        // An NDS32 module names its processor's patch only.
        XCTAssertEqual(hello["language_patch"] as? String, "nds32-standby-1", "\(hello)")
        assertGoesOn(try await function(host, module, "0x20CD2"))
        let caller = try await function(host, module, "0x15324")
        XCTAssertTrue("\(caller)".contains("20cd2") || "\(caller)".contains("20CD2"), "the caller reads past the call: \(caller)")
        try await host.take(module)
        let published = try await host.publish(module, by: "t")
        XCTAssertTrue(published.manifest.recipe.id.hasSuffix("-lang-nds32-standby-1-decomp-stack-params-1-equates-1"),
                      published.manifest.recipe.id)
        XCTAssertFalse(published.manifest.recipe.id.contains("descriptor-tables"), published.manifest.recipe.id)
    }

    func testReapplyGivesAStockProjectItsStandbyBodies() async throws {
        let (image, patched) = try setUp()
        let directory = try XCTUnwrap(directory)
        guard let stockInstall = try? GhidraInstall.find(), stockInstall.languagePatch == nil else {
            throw XCTSkip("the default Ghidra is not a stock install")
        }
        _ = stockInstall
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let projects = directory.appendingPathComponent("projects")
        let module = GhidraHost.moduleDigest(of: image)

        // 1. Made on stock: the function ends at the standby.
        let stock = GhidraHost(configuration: .init(projectsRoot: projects, idle: 300, holder: "GhidraHostECStandbyTests"),
                               writer: store)
        _ = try await stock.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        let before = try await function(stock, module, "0x20CD2")
        XCTAssertFalse((before["c"] as? String ?? "").contains("standby(1)"), "\(before)")
        await stock.stop(module)

        // 2. Opened on the patched Ghidra, the step.
        let host = GhidraHost(configuration: .init(projectsRoot: projects, ghidraHome: patched, idle: 300,
                                                   holder: "GhidraHostECStandbyTests"), writer: store)
        defer { Task { await host.stop(module) } }
        try await host.take(module)
        let first = try json(try await host.write(module, "/v1/ec/reapply", body: Data("{}".utf8)))
        XCTAssertTrue((first["standby_sites"] as? [String] ?? []).contains("0x20CE2"), "\(first)")
        XCTAssertTrue((first["standby_disassembled"] as? [String] ?? []).contains("0x20CE6"), "\(first)")
        XCTAssertTrue((first["standby_bodies"] as? [String] ?? []).contains("0x20CD2"), "\(first)")
        assertGoesOn(try await function(host, module, "0x20CD2"))

        // 3. Again: nothing changes.
        let second = try json(try await host.write(module, "/v1/ec/reapply", body: Data("{}".utf8)))
        for list in ["standby_disassembled", "standby_bodies", "standby_returning", "standby_calls"] {
            XCTAssertEqual((second[list] as? [Any])?.count, 0, "\(list): \(second)")
        }
    }
}
