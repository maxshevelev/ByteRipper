import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A function-pointer typedef as an element type (issue 50d8733a): the
/// typedef and the function definition `typedef R (*X)(…)` makes are one
/// name, not an ambiguity, and the path form takes `*` and `[N]`. Run on an
/// EC (NDS32) image (`GHIDRA_EC_MODULE`); without it or Ghidra it skips.
final class ECFunctionPointerArrayTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAFunctionPointerTypedefIsAnArrayElement() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ECFunctionPointerArrayTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "ECFunctionPointerArrayTests"), writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        try await host.take(module)
        defer { Task { await host.stop(module) } }

        _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: [
            "c": "typedef void (*INTC_ISR_HANDLER)(void);"]))
        func setData(_ address: String, _ name: String, _ type: String) async throws -> String {
            let body = try JSONSerialization.data(withJSONObject: ["address": address, "name": name, "type": type])
            return "\(try json(try await host.write(module, "/v1/set/data", body: body)))"
        }
        let bare = try await setData("0x5000", "IsrIrqTable", "INTC_ISR_HANDLER[240]")
        XCTAssertTrue(bare.contains("INTC_ISR_HANDLER[240]"), bare)
        let pathed = try await setData("0x5000", "IsrIrqTable", "/INTC_ISR_HANDLER[16]")
        XCTAssertTrue(pathed.contains("INTC_ISR_HANDLER[16]"), pathed)
        let functions = try await setData("0x5000", "IsrIrqTable", "/functions/INTC_ISR_HANDLER *[4]")
        XCTAssertTrue(functions.contains("[4]"), functions)
        let read = try json(try await host.read(module, "/v1/type?name=INTC_ISR_HANDLER"))
        let definition = "\(read)"
        XCTAssertTrue(definition.contains("(*INTC_ISR_HANDLER)"), definition)
    }
}
