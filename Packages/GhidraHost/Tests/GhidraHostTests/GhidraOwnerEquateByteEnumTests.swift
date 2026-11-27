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

    /// `functions` names the reply byte of `movi a1,0x0`, not the frame size
    /// of the `push25 s0,0x0` and `pop25 s0,0x0` around it (issue 36dabe9a).
    func testFunctionsModeSkipsTheStackFrameImmediate() async throws {
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
        let data = try await host.write(module, "/v1/set/equate", body: try JSONSerialization.data(withJSONObject: [
            "functions": ["0x74AA", "0x75FA", "0x7606"], "value": "0x0", "name": "ReplyTestZero", "dry_run": true]))
        let answer = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let applied = (answer["applied"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let frames = (answer["stack_adjust"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        XCTAssertFalse(applied.contains { $0.hasPrefix("push25") || $0.hasPrefix("pop25") }, "\(answer)")
        XCTAssertTrue(frames.contains { $0.hasPrefix("push25") }, "\(answer)")
        XCTAssertTrue(frames.contains { $0.hasPrefix("pop25") }, "\(answer)")
        XCTAssertFalse(applied.isEmpty, "\(answer)")
    }

    /// A byte set by a read-modify-write — `movi a?,-0x80; or33; zeb33; sbi`
    /// at 0xAA00 — is the byte 0x80 and its name prints in the C (issue
    /// 3b4c00cb).
    func testAByteOrredIntoARegisterIsTheByteMember() async throws {
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
        func post(_ body: [String: Any]) async throws -> [String: Any] {
            let data = try await host.write(module, "/v1/set/equate", body: try JSONSerialization.data(withJSONObject: body))
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        _ = try await host.write(module, "/v1/type", body: try JSONSerialization.data(withJSONObject: ["c": """
            typedef enum _ADC_TEST_BIT : unsigned char { AdcTestEnable = 0x01 } ADC_TEST_BIT;
            """]))
        let answer = try await post(["enum": "ADC_TEST_BIT", "items": [
            ["address": "0xAA00", "operand": 1, "name": "AdcTestValid"]]])
        let item = try XCTUnwrap((answer["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["value"] as? String, "0x80", "\(item)")
        XCTAssertEqual(answer["not_in_c"] as? [String], [], "\(answer)")
        let code = String(decoding: try await host.read(module, "/v1/function/0xAA00"), as: UTF8.self)
        XCTAssertTrue(code.contains("| AdcTestValid"), code)
        let type = String(decoding: try await host.read(module, "/v1/type?name=ADC_TEST_BIT"), as: UTF8.self)
        XCTAssertFalse(type.contains("FF80"), type)

        // A negative value is a number in `functions` mode too.
        let negative = try await post(["functions": ["0xAA00"], "value": "-0x80", "name": "AdcTestValid", "dry_run": true])
        XCTAssertNotNil(negative["applied"], "\(negative)")
    }
}
