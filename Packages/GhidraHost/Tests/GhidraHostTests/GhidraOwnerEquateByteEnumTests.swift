import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// An equate on a negative byte constant names the byte, not its sign
/// extension (issue c81f9348).
///
/// The ITE EC image (`GHIDRA_EC_MODULE`, NDS32) loads `movi a?,-0x80` at
/// 0x1F3EA and stores it with a byte store: the operand holds 0xFFFFFFFF80.
/// An enum of byte values — one byte wide, or wider with every member in a
/// byte — takes the member 0x80; a value its width cannot hold is refused
/// with nothing changed.
final class GhidraOwnerEquateByteEnumTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testANegativeByteConstantIsTheByteMemberAndATooWideOneIsRefused() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerEquateByteEnumTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraOwnerEquateByteEnumTests"),
                              writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }
        try await host.take(module)

        func post(_ call: String, _ body: [String: Any]) async throws -> [String: Any] {
            let data = try await host.write(module, call, body: try JSONSerialization.data(withJSONObject: body))
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        func type(_ name: String) async throws -> String {
            String(decoding: try await host.read(module, "/v1/type?name=\(name)"), as: UTF8.self)
        }

        // One byte wide: the member is 0x80.
        _ = try await post("/v1/type", ["c": """
            typedef enum _KBC_KBHISR_VALUE : unsigned char { KbhisrTest01 = 0x01, KbhisrTest40 = 0x40 } KBC_KBHISR_VALUE;
            """])
        let byte = try await post("/v1/set/equate", ["address": "0x1F3EA", "operand": 1,
                                                     "name": "KbhisrMuxPort2", "enum": "KBC_KBHISR_VALUE"])
        XCTAssertEqual(byte["value"] as? String, "0x80", "\(byte)")
        XCTAssertEqual(byte["in_c"] as? Bool, true, "\(byte)")
        let code = String(decoding: try await host.read(module, "/v1/function/0x1F3EA"), as: UTF8.self)
        XCTAssertTrue(code.contains("KBC_KBHISR = KbhisrMuxPort2"), code)
        let byteType = try await type("KBC_KBHISR_VALUE")
        XCTAssertTrue(byteType.contains("KbhisrMuxPort2 = 0x80"), byteType)
        XCTAssertFalse(byteType.contains("FF80"), byteType)

        // Four bytes wide, every member in a byte: still 0x80.
        _ = try await post("/v1/type", ["c": """
            typedef enum _KBC_WIDE_TEST : unsigned int { WideTest01 = 0x01, WideTest40 = 0x40 } KBC_WIDE_TEST;
            """])
        _ = try await post("/v1/set/equate", ["address": "0x1F3EA", "operand": 1,
                                              "name": "WideTest80", "enum": "KBC_WIDE_TEST"])
        let wideType = try await type("KBC_WIDE_TEST")
        XCTAssertTrue(wideType.contains("WideTest80 = 0x80"), wideType)
        XCTAssertFalse(wideType.contains("FF80"), wideType)

        // `sethi a0,0xf01` at 0x1F3E6 holds a value no byte holds: refused,
        // and neither the enum nor the operand changed.
        do {
            _ = try await post("/v1/set/equate", ["address": "0x1F3E6", "operand": 1,
                                                  "name": "KbhisrTooWide", "enum": "KBC_KBHISR_VALUE"])
            XCTFail("a value wider than a one-byte enum was taken")
        } catch {
            XCTAssertTrue("\(error)".contains("does not fit"), "\(error)")
        }
        let unchanged = try await type("KBC_KBHISR_VALUE")
        XCTAssertEqual(unchanged, byteType)
        let disassembly = String(decoding: try await host.read(module, "/v1/disassembly/0x1F3E6"), as: UTF8.self)
        XCTAssertFalse(disassembly.contains("KbhisrTooWide"), disassembly)
    }

    /// The same byte named through `items`: the name reaches the store in
    /// the C, as for one call (issue f509c69c).
    func testANegativeByteNamedInAListReachesTheC() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_EC_MODULE"], !path.isEmpty else {
            throw XCTSkip("GHIDRA_EC_MODULE names no EC image")
        }
        guard (try? GhidraInstall.find()) != nil else { throw XCTSkip("no Ghidra on this machine") }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerEquateByteEnumTests-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                                   idle: 300, holder: "GhidraOwnerEquateByteEnumTests"),
                              writer: store)
        let module = GhidraHost.moduleDigest(of: image)
        _ = try await host.create(module: image, name: "ItEcNmD562", source: .init(document: "dump", node: "0.0.3"))
        defer { Task { await host.stop(module) } }
        try await host.take(module)

        func post(_ call: String, _ body: [String: Any]) async throws -> [String: Any] {
            let data = try await host.write(module, call, body: try JSONSerialization.data(withJSONObject: body))
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        _ = try await post("/v1/type", ["c": """
            typedef enum _GPIO_GPCR_TEST : unsigned char { GpcrTestAlt = 0x00, GpcrTestOutput = 0x40 } GPIO_GPCR_TEST;
            """])
        let answer = try await post("/v1/set/equate", ["enum": "GPIO_GPCR_TEST", "items": [
            ["address": "0x1355C", "operand": 1, "name": "GpcrTestInput"]]])
        XCTAssertEqual(answer["not_in_c"] as? [String], [], "\(answer)")
        let item = try XCTUnwrap((answer["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["narrowed_from"] as? String != nil, true, "\(item)")
        XCTAssertNotNil(item["c_address"], "\(item)")
        let code = String(decoding: try await host.read(module, "/v1/function/0x1355C"), as: UTF8.self)
        XCTAssertTrue(code.contains("= GpcrTestInput"), code)
    }
}
