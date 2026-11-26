import CodeAnalysis
import ECImage
import Foundation
import XCTest
@testable import GhidraHost

/// An ITE EC firmware image (`GHIDRA_EC_MODULE`, a BIOS copy of 0x30000
/// bytes) made a module, opened and published: kind EC, NDS32, its own type
/// and registry group. A run without the image or Ghidra skips.
final class GhidraHostECTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testAnECImageIsCreatedNamedAndPublished() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostECTests"), writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        XCTAssertEqual(module.hex, "889159a794a3015e5547312b224db1f43c76daeddb90069ee856e32b6eac2b39")
        XCTAssertTrue(GhidraHost.isModuleImage(image))
        XCTAssertEqual(GhidraHost.ecModuleName(image), "ITE8380-EC-V0.00")

        let state = try await host.create(module: image, name: "ItEcNmD562",
                                          source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }
        XCTAssertEqual(state.module.kind, "EC")
        XCTAssertEqual(state.module.size, 0x2497C)
        XCTAssertEqual(state.module.ec?.family, "ite-nds32")
        XCTAssertEqual(state.module.ec?.extentSource, "crt0")
        XCTAssertEqual(state.module.ec?.sliceSize, 0x30000)
        XCTAssertEqual(state.module.ec?.hostUpdateSize, 0x2C000)
        XCTAssertEqual(state.module.ec?.masked, [.init(offset: 0x8D, actual: 0xAF, normalised: 0)])
        let past = try XCTUnwrap(state.module.ec?.refsPastExtent)
        XCTAssertEqual(past.count, 11, "\(past)")
        XCTAssertTrue(past.contains(.init(address: 0x2A600, from: 0x718C)), "\(past)")
        XCTAssertFalse(past.contains { $0.address == 0x249F0 }, "a timer's 150000 ms is no address: \(past)")
        XCTAssertEqual(state.madeWith.passes, ["ApplyItEc.java"])
        XCTAssertNil(state.madeWith.types)
        XCTAssertEqual(GhidraHost.typeGroup(state), "Nds32")
        let group = await host.moduleGroup(module)
        XCTAssertEqual(group, "Nds32")

        func read(_ call: String) async throws -> [String: Any] {
            let answer = try await host.read(module, call)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
        }
        let hello = try await read("/v1/hello")
        XCTAssertTrue("\(hello)".contains("NDS32"), "\(hello)")
        let listed = try await read("/v1/functions?limit=5000")
        let functions = try XCTUnwrap(listed["functions"] as? [[String: Any]])
        let names = Dictionary(functions.compactMap { row -> (String, String)? in
            guard let name = row["name"] as? String, let entry = row["entry"] as? String else { return nil }
            return (name, entry)
        }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(names["ResetEntry"].flatMap { CodeAddress(hex: $0)?.value }, 0x3800)
        XCTAssertEqual(names["main"].flatMap { CodeAddress(hex: $0)?.value }, 0x2C00)
        XCTAssertEqual(names["IsrDispatch"].flatMap { CodeAddress(hex: $0)?.value }, 0x3200)
        XCTAssertEqual(names["IsrCommonEntry"].flatMap { CodeAddress(hex: $0)?.value }, 0x448)
        XCTAssertNotNil(names["Isr_Lvl0"])
        XCTAssertTrue(names.keys.contains { $0.hasPrefix("Isr_Irq") }, "\(names.keys.sorted().prefix(40))")

        // A register of the GPIO block, labelled from the map.
        let defined = try await read("/v1/data?limit=5000")
        let data = try XCTUnwrap(defined["data"] as? [[String: Any]])
        XCTAssertTrue(data.contains { row in
            guard let name = row["name"] as? String, let address = (row["address"] as? String).flatMap(CodeAddress.init(hex:))
            else { return false }
            return name.hasPrefix("GPIO_") && (0xF01600..<0xF01700).contains(address.value)
        }, "\(data.prefix(20))")

        // The flash past the extent the code points at: in the pass's input,
        // and labelled with its plate.
        let input = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try GhidraHost.ecPassInput(try ECFirmware(slice: image), reference: nil)) as? [String: Any])
        let references = try XCTUnwrap(input["refs_past_extent"] as? [[String: Int]])
        XCTAssertTrue(references.contains(["address": 0x2A600, "from": 0x718C]), "\(references)")
        // The label, in the eflash_data block, and the code that uses it;
        // the timer's 150000 at 0x15424 is no reference, not even the
        // analysis's (the block is made after it).
        let xrefs = try await read("/v1/xrefs?to=0x2A600")
        let from = (xrefs["references"] as? [[String: Any]] ?? []).compactMap { $0["from"] as? String }
        XCTAssertTrue(from.contains { CodeAddress(hex: $0)?.value == 0x718C }, "\(xrefs)")
        let timer = try await read("/v1/xrefs?to=0x249F0")
        XCTAssertTrue((timer["references"] as? [Any] ?? []).isEmpty, "\(timer)")
        let user = try await read("/v1/function/0x15324")
        XCTAssertFalse("\(user)".contains("FlashRef_249F0"), "\(user)")
        let c = try await read("/v1/function/0x718C")
        XCTAssertTrue("\(c)".contains("FlashRef_2A600"), "\(c)")

        try await host.take(module)
        // The eflash_data block, made after the analysis: data there takes a type.
        _ = try await host.write(module, "/v1/set/data", body: try JSONSerialization.data(
            withJSONObject: ["address": "0x2B800", "type": "byte[16]"]))
        let typed = try await read("/v1/data?limit=5000")
        XCTAssertTrue((typed["data"] as? [[String: Any]] ?? []).contains {
            ($0["address"] as? String).flatMap(CodeAddress.init(hex:))?.value == 0x2B800 }, "\(typed)")
        let published = try await host.publish(module, by: "agent")
        XCTAssertEqual(published.manifest.module.kind, "EC")
        XCTAssertEqual(published.manifest.module.language?.hasPrefix("NDS32"), true)
        XCTAssertEqual(published.manifest.module.ec?.extent, 0x2497C)
        XCTAssertEqual(published.manifest.module.ec?.refsPastExtent?.count, 11, "the facts travel with the publish")
        XCTAssertEqual(published.manifest.recipe.passes, ["ApplyItEc.java"])
        XCTAssertTrue(published.manifest.recipe.id.contains("-ec-"), published.manifest.recipe.id)
    }
}
