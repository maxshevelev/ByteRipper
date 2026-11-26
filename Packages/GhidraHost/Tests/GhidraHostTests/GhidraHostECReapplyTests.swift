import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// `ec/reapply` (`ghidra_ec_reapply`) on an ITE EC module (`GHIDRA_EC_MODULE`)
/// made as a build before 866 made it: no flash references past the extent,
/// no `FlashRef_` labels or plates, no `eflash_data` block, no
/// `refs_past_extent` in the facts — and with a label the earlier rule made
/// by value (`FlashRef_249F0`, a timer's 150000 ms). The step adds them,
/// removes that label while it is still the pass's, keeps one a reviewer
/// renamed, keeps a reviewer's name for a place and every other edit,
/// adds nothing a second time, and is refused without the lease and for a
/// module that is no EC; the facts reach the next publish. A run without the
/// image or Ghidra skips. The project is made with the register and IRQ
/// maps as they were before the IT8227E overlays: the step renames the
/// register labels the pass gave from the old map (`SMB_4P7USL` at
/// 0xF01C00), adds the new ones, rewrites the ISR plates (`Isr_Irq160`'s
/// PECI) keeping a reviewer's line after the pass's, keeps a label and a
/// plate a reviewer changed, and changes nothing a second time.
final class GhidraHostECReapplyTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testAPreBuild866ProjectGetsItsFlashReferencesAndNothingElse() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECReapplyTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let root = directory.appendingPathComponent("projects")
        let host = GhidraHost(configuration: .init(projectsRoot: root, idle: 300, holder: "GhidraHostECReapplyTests"),
                              writer: store)
        let module = GhidraHost.moduleDigest(of: image)

        // 1. A project as a build before 866 made it.
        await host.setECCreatesAsBefore866(true)
        let made = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        await host.setECCreatesAsBefore866(false)
        defer { Task { await host.stop(module) } }
        XCTAssertNil(made.module.ec?.refsPastExtent)

        func json(_ data: Data) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func read(_ call: String) async throws -> [String: Any] { try json(try await host.read(module, call)) }
        func post(_ call: String, _ body: [String: Any]) async throws -> [String: Any] {
            try json(try await host.write(module, call, body: try JSONSerialization.data(withJSONObject: body)))
        }
        func xrefs(to address: String) async throws -> [Int] {
            let answer = try await read("/v1/xrefs?to=\(address)")
            return (answer["references"] as? [[String: Any]] ?? [])
                .compactMap { row -> Int? in
                    guard let text = row["from"] as? String, let address = CodeAddress(hex: text) else { return nil }
                    return Int(address.value)
                }
        }
        let before = try await xrefs(to: "0x2A600")
        XCTAssertFalse(before.contains(0x718C), "a pre-866 project has no reference: \(before)")
        let unlabelled = try await read("/v1/function/0x15324")
        XCTAssertFalse("\(unlabelled)".contains("FlashRef_249F0"), "\(unlabelled)")

        // 5. No lease: refused, and nothing written.
        do {
            _ = try await post("/v1/ec/reapply", [:])
            XCTFail("ec/reapply without the lease was taken")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(error)")
        }

        // The reviewer's work: a function named, a comment, and a flash
        // address named before the step.
        try await host.take(module)
        _ = try await post("/v1/rename/function", ["address": "0x15324", "name": "ReviewerFlashReader"])
        _ = try await post("/v1/set/comment", ["address": "0x15424", "kind": "eol", "text": "reviewer note kept"])
        _ = try await post("/v1/set/data", ["address": "0x2A600", "name": "EflashState_2A600"])
        // Names the maps before the IT8227E overlays gave: a register label a
        // reviewer renamed, a plate a reviewer wrote, one the pass wrote
        // with a reviewer's line after it.
        _ = try await post("/v1/set/data", ["address": "0xF01C01", "name": "ReviewerHostCtl"])
        _ = try await post("/v1/set/comment", ["address": "0x5A28", "kind": "plate", "text": "Reviewer: PM2 input."])
        let oldIsr160 = try await read("/v1/function/0x53E8")
        XCTAssertTrue("\(oldIsr160)".contains("IT83XX_IRQ_PECI"), "\(oldIsr160)")
        _ = try await post("/v1/set/comment", ["address": "0x53E8", "kind": "plate", "text":
            "INTC interrupt 160, source PECI (the register map's IT83XX_IRQ_PECI).\nReviewer line kept."])
        let oldData = try await read("/v1/data?limit=5000")
        XCTAssertTrue("\(oldData)".contains("SMB_4P7USL"), "the old map's name at 0xF01C00")
        // What the earlier rule (by value) left: FlashRef_249F0 from the
        // timer's `movi` at 0x15424, and one at 0x2A400 a reviewer renamed.
        let byValue: [String: Any] = ["extent": 0x249F0, "host_update_size": 0,
                                      "refs_past_extent": [["address": 0x249F0, "from": 0x15424],
                                                           ["address": 0x2A400, "from": 0x15424]]]
        _ = try await host.write(module, "/v1/ec/reapply", body: try JSONSerialization.data(withJSONObject: byValue),
                                 byHost: true)
        let oldReader = try await read("/v1/function/0x15324")
        XCTAssertTrue("\(oldReader)".contains("FlashRef_249F0"), "\(oldReader)")
        _ = try await post("/v1/set/data", ["address": "0x2A400", "name": "ReviewerNamed_2A400"])

        // 2. The step.
        let first = try await post("/v1/ec/reapply", [:])
        let added = first["references_added"] as? [[String: Any]] ?? []
        XCTAssertEqual(added.count, 11, "\(first)")
        let removed = first["labels_removed"] as? [[String: Any]] ?? []
        XCTAssertEqual(removed.map { $0["name"] as? String }, ["FlashRef_249F0"], "\(first)")
        XCTAssertEqual(first["plates_removed"] as? [String], ["0x249F0"], "\(first)")
        XCTAssertEqual((first["references_removed"] as? [[String: Any]])?.map { $0["from"] as? String }, ["0x15424"],
                       "\(first)")
        let rejectedKept = first["rejected_kept"] as? [[String: Any]] ?? []
        XCTAssertEqual(rejectedKept.map { $0["address"] as? String }, ["0x2A400"], "\(first)")
        XCTAssertEqual((first["eflash_data"] as? [String: Any])?["block"] as? String, "added", "\(first)")
        XCTAssertEqual((first["eflash_data"] as? [String: Any])?["end"] as? String, "0x2C000", "\(first)")
        let kept = first["labels_kept"] as? [[String: Any]] ?? []
        XCTAssertTrue(kept.contains { $0["address"] as? String == "0x2A600" && $0["name"] as? String == "EflashState_2A600" },
                      "\(first)")
        XCTAssertEqual((first["facts"] as? [String: Any])?["refs_past_extent"] as? String, "added", "\(first)")

        // The names: the old map's register labels renamed, the new
        // IT8227E ones added, the ISR plates rewritten; a reviewer's kept.
        XCTAssertEqual(first["registers_renamed"] as? Int, 9, "\(first)")
        XCTAssertEqual(first["registers_added"] as? Int, 40, "\(first)")
        XCTAssertGreaterThan(first["isr_plates_refreshed"] as? Int ?? 0, 100, "\(first)")
        let renames = first["register_renames"] as? [[String: Any]] ?? []
        XCTAssertTrue(renames.contains { $0["was"] as? String == "SMB_4P7USL" && $0["name"] as? String == "SMB_HOSTA_A" },
                      "\(renames)")
        let namesKept = first["kept"] as? [[String: Any]] ?? []
        XCTAssertTrue(namesKept.contains { $0["address"] as? String == "0xF01C01" && $0["name"] as? String == "ReviewerHostCtl" },
                      "\(namesKept)")
        XCTAssertTrue(namesKept.contains { $0["address"] as? String == "0x5A28" && $0["irq"] as? Int == 27 }, "\(namesKept)")
        let platesRefreshed = first["isr_plates"] as? [[String: Any]] ?? []
        XCTAssertTrue(platesRefreshed.contains { $0["irq"] as? Int == 160 }, "\(platesRefreshed)")
        let isr160 = "\(try await read("/v1/function/0x53E8"))"
        XCTAssertTrue(isr160.contains("source SMB_E") && isr160.contains("from the firmware: IT8227E fw"), isr160)
        XCTAssertTrue(isr160.contains("Reviewer line kept"), isr160)
        XCTAssertFalse(isr160.contains("IT83XX_IRQ_PECI"), isr160)
        let isr027 = "\(try await read("/v1/function/0x5A28"))"
        XCTAssertTrue(isr027.contains("Reviewer: PM2 input."), isr027)
        let isr152 = "\(try await read("/v1/function/0x53C8"))"
        XCTAssertTrue(isr152.contains("not verified for IT8227E"), isr152)
        let newData = "\(try await read("/v1/data?limit=5000"))"
        XCTAssertTrue(newData.contains("SMB_HOSTA_A") && newData.contains("SMB_HOCTL2_E"), "the new map's names")
        XCTAssertFalse(newData.contains("SMB_4P7USL"), "the old map's name is gone")
        XCTAssertTrue(newData.contains("ReviewerHostCtl"), "the reviewer's name stays")

        // 3. What it added, and what it kept.
        let to2A600 = try await xrefs(to: "0x2A600")
        XCTAssertTrue(to2A600.contains(0x718C) && to2A600.contains(0x71B2), "\(to2A600)")
        let reader = try await read("/v1/function/0x15324")
        XCTAssertFalse("\(reader)".contains("FlashRef_249F0"), "\(reader)")
        let toTimer = try await xrefs(to: "0x249F0")
        XCTAssertFalse(toTimer.contains(0x15424), "\(toTimer)")
        XCTAssertEqual(reader["name"] as? String, "ReviewerFlashReader", "the reviewer's name stays")
        XCTAssertTrue("\(reader)".contains("reviewer note kept"), "the reviewer's comment stays: \(reader)")
        let named = try await read("/v1/data?limit=5000")
        XCTAssertFalse("\(named)".contains("FlashRef_2A600"), "\(named)")
        let c = try await read("/v1/function/0x718C")
        XCTAssertTrue("\(c)".contains("EflashState_2A600"), "the reviewer's name for 0x2A600 stays: \(c)")
        let state = try await host.project(module).state()
        XCTAssertEqual(state.module.ec?.refsPastExtent?.count, 11)
        XCTAssertFalse(state.module.ec?.refsPastExtent?.contains { $0.address == 0x249F0 } ?? true)

        // The flash data area takes a type and a plate now.
        _ = try await post("/v1/type", ["c": "typedef struct { unsigned char Kind; unsigned char Data[31]; } EFLASH_EVENT_LOG_RECORD;"])
        _ = try await post("/v1/set/data", ["address": "0x2B800", "name": "EflashEventLog", "type": "EFLASH_EVENT_LOG_RECORD[32]"])
        _ = try await post("/v1/set/comment", ["address": "0x2B800", "kind": "plate", "text": "The event log."])
        let log = try await read("/v1/data?limit=5000")
        XCTAssertTrue("\(log)".contains("EflashEventLog") && "\(log)".contains("EFLASH_EVENT_LOG_RECORD"), "\(log)")

        // 4. Again: nothing added.
        let second = try await post("/v1/ec/reapply", [:])
        for list in ["references_added", "labels_added", "plates_added"] {
            XCTAssertEqual((second[list] as? [Any])?.count, 0, "\(list): \(second)")
        }
        XCTAssertEqual((second["references_kept"] as? [Any])?.count, 11, "\(second)")
        XCTAssertEqual((second["labels_removed"] as? [Any])?.count, 0, "\(second)")
        XCTAssertEqual((second["eflash_data"] as? [String: Any])?["block"] as? String, "kept", "\(second)")
        XCTAssertEqual((second["facts"] as? [String: Any])?["refs_past_extent"] as? String, "kept", "\(second)")
        for count in ["registers_renamed", "registers_added", "register_notes_refreshed", "isr_plates_refreshed"] {
            XCTAssertEqual(second[count] as? Int, 0, "\(count): \(second)")
        }
        XCTAssertEqual((second["kept"] as? [Any])?.count, namesKept.count, "\(second)")

        // 5. A module that is no EC: refused before anything is asked of an owner.
        let other = SHA256Digest(data: Data("not an EC module".utf8))
        let otherProject = await host.project(other)
        try FileManager.default.createDirectory(at: otherProject.folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: otherProject.folder.appendingPathComponent("module.gpr").path, contents: Data())
        var pe = state
        pe.module.sha256 = other.hex
        pe.module.kind = "PE32"
        pe.module.ec = nil
        try otherProject.write(pe)
        do {
            _ = try await host.write(other, "/v1/ec/reapply", body: Data("{}".utf8))
            XCTFail("ec/reapply on a PE32 module was taken")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 422, "\(error)")
        }

        // 6. The facts travel with the next publish.
        let published = try await host.publish(module, by: "agent")
        XCTAssertEqual(published.manifest.module.ec?.refsPastExtent?.count, 11, "the facts reach the manifest")
    }
}
