import CodeAnalysis
import ECImage
import Foundation
import XCTest
@testable import GhidraHost

/// The IT8227E register map's status column as the EC pass applies it: the
/// SMBus host registers carry the names the firmware's own tables give them
/// (SmbChanRegsTable at 0x239F8, SmbChanPinsTable at 0x23AD4), the IT8320
/// names they replaced are gone, and a register nobody checked for IT8227E
/// says so in its comment. A run without the image or Ghidra skips.
final class GhidraHostECRegisterMapTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testTheMapReadsTheStatusColumn() throws {
        let map = try ECRegisterMap(tsv: """
            # comment
            name\taddress\twidth\tblock\tdescription\tsource\tstatus
            SMB_HOSTA_A\t0x00F01C00\t1\tSMB\t-\tIT8227E fw\tfirmware
            GPIO_GPDRA\t0x00F01601\t1\tGPIO\t-\tregisters.h:1\tunverified
            OLD\t0x00F01602\t1\tGPIO\t-\tregisters.h:2
            """)
        XCTAssertEqual(map.register(at: 0xF01C00)?.status, "firmware")
        XCTAssertEqual(map.register(at: 0xF01601)?.status, "unverified")
        XCTAssertNil(map.register(at: 0xF01602)?.status)
    }

    func testSMBusNamesComeFromTheFirmwareAndTheRestAreMarkedUnverified() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostECRegisterMapTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraHostECRegisterMapTests"), writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }
        func read(_ call: String) async throws -> [String: Any] {
            let answer = try await host.read(module, call)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
        }

        let listed = try await read("/v1/data?limit=5000")
        let data = try XCTUnwrap(listed["data"] as? [[String: Any]])
        var byAddress: [UInt64: String] = [:]
        for row in data {
            guard let name = row["name"] as? String,
                  let address = (row["address"] as? String).flatMap(CodeAddress.init(hex:)) else { continue }
            byAddress[address.value] = name
        }
        XCTAssertEqual(byAddress[0xF01C00], "SMB_HOSTA_A")
        XCTAssertEqual(byAddress[0xF01C01], "SMB_HOCTL_A")
        XCTAssertEqual(byAddress[0xF01C21], "SMB_HOCTL2_B")
        XCTAssertFalse(byAddress.values.contains("SMB_4P7USL"))
        XCTAssertFalse(byAddress.values.contains("SMB_CHSEF"))

        // An IT8320 register some function reaches directly: its comment, as
        // the function's data comments carry it, says it is not verified.
        let registers = byAddress.filter { (0xF01000..<0xF03000).contains($0.key) && !$0.value.hasPrefix("SMB_") }
            .keys.sorted()
        var said: String?
        search: for address in registers.prefix(400) {
            let xrefs = try await read(String(format: "/v1/xrefs?to=0x%X", address))
            for from in (xrefs["references"] as? [[String: Any]] ?? []).compactMap({ $0["from"] as? String }) {
                guard let function = try? await read("/v1/function/\(from)") else { continue }
                let comments = function["data_comments"] as? [[String: Any]] ?? []
                if let hit = comments.first(where: { ($0["comment"] as? String ?? "").contains("not verified for IT8227E") }) {
                    said = "\(hit)"
                    break search
                }
            }
        }
        XCTAssertNotNil(said, "no register read in C carries the unverified note")
    }
}
