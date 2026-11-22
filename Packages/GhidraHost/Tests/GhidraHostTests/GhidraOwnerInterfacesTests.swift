import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// The record of what a module installs, locates and is notified of
/// (`ghidra_set_interfaces`): each list unanswered until written, an empty one
/// an answer, every entry checked against the program, and the record carried
/// by a publish into the reading the app and `code_modules` show. Run with
/// `GHIDRA_TYPE_MODULE` naming a module; skipped otherwise.
final class GhidraOwnerInterfacesTests: XCTestCase {
    private var directory: URL!
    private var host: GhidraHost!
    private var module: SHA256Digest!

    override func tearDown() async throws {
        if let host, let module { await host.stop(module) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func open() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraOwnerInterfacesTests-\(UUID().uuidString)", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300),
                          writer: store)
        module = SHA256Digest(data: image)
        _ = try await host.createCached(module: image, name: "Module")
        try await host.take(module)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func set(_ body: [String: Any]) async throws -> [String: Any] {
        try object(try await host.write(module, "/v1/set/interfaces",
                                        body: try JSONSerialization.data(withJSONObject: body)))
    }

    private func refused(_ body: [String: Any], saying words: String) async {
        do {
            _ = try await set(body)
            XCTFail("not refused: \(body)")
        } catch let error as GhidraHostError {
            XCTAssertTrue(error.message.contains(words), error.message)
        } catch {
            XCTFail("\(error)")
        }
    }

    /// Two functions of the module: an entry to call from, another as a callback.
    private func entries() async throws -> (String, String) {
        let data = try await host.read(module, "/v1/functions?limit=2", holder: "a reader")
        let functions = try XCTUnwrap(try object(data)["functions"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(functions.count, 2)
        return (try XCTUnwrap(functions[0]["entry"] as? String), try XCTUnwrap(functions[1]["entry"] as? String))
    }

    private let guid = "0ae8ce5d-e448-4437-a8d7-ebf5f194f731"

    func testTheListsAreUnansweredUntilWrittenAndAnEmptyOneIsAnAnswer() async throws {
        try await open()
        let read = try object(try await host.read(module, "/v1/interfaces", holder: "a reader"))
        XCTAssertEqual(read["unanswered"] as? [String], ["installs", "locates", "notifies"])
        XCTAssertTrue(read["installs"] == nil || read["installs"] is NSNull, "\(String(describing: read["installs"]))")

        let (call, callback) = try await entries()
        let answer = try await set([
            "installs": [],
            "locates": [["guid": guid, "name": "EFI_PEI_READ_ONLY_VARIABLE2_PPI", "kind": "ppi", "address": call,
                         "condition": "always", "purpose": "Reads the variable store.", "required": true]]
        ])
        XCTAssertEqual(answer["unanswered"] as? [String], ["notifies"])
        XCTAssertEqual((answer["installs"] as? [Any])?.count, 0, "an empty list is an answer")
        let located = try XCTUnwrap((answer["locates"] as? [[String: Any]])?.first)
        XCTAssertEqual(located["guid"] as? String, guid.uppercased(), "the GUID in its canonical form")
        XCTAssertEqual(located["required"] as? Bool, true)

        // A list not given stays; null takes one back.
        let notified = try await set(["notifies": [["guid": guid, "name": "EFI_PEI_READ_ONLY_VARIABLE2_PPI",
                                                    "kind": "ppi", "address": call, "condition": "only on S3 resume",
                                                    "purpose": "Reads the store once it is up.", "callback": callback]]])
        XCTAssertEqual(notified["unanswered"] as? [String], [])
        XCTAssertEqual((notified["locates"] as? [Any])?.count, 1)
        let back = try await set(["installs": NSNull()])
        XCTAssertEqual(back["unanswered"] as? [String], ["installs"])
    }

    func testAnEntryTheProgramDoesNotBearIsRefusedAndNothingIsWritten() async throws {
        try await open()
        let (call, _) = try await entries()
        let good: [String: Any] = ["guid": guid, "name": "EFI_PEI_READ_ONLY_VARIABLE2_PPI", "kind": "ppi",
                                   "address": call, "condition": "always", "purpose": "Reads the variable store.",
                                   "required": false]
        var bad = good
        bad["guid"] = "0AE8CE5D-E448-4437-A8D7"
        await refused(["locates": [good, bad]], saying: "8-4-4-4-12")
        bad = good
        bad["address"] = "0xFFFFFF00"
        await refused(["locates": [bad]], saying: "outside the module")
        bad = good
        bad.removeValue(forKey: "required")
        await refused(["locates": [bad]], saying: "required")
        bad = good
        bad["purpose"] = "  "
        await refused(["locates": [bad]], saying: "purpose")
        var notify = good
        notify.removeValue(forKey: "required")
        notify["callback"] = "0xFFFFFF00"
        await refused(["notifies": [notify]], saying: "callback")
        await refused(["installs": [good]], saying: "`required` is not a field of installs")
        await refused(["depex": []], saying: "not a list of the record")

        let read = try object(try await host.read(module, "/v1/interfaces", holder: "a reader"))
        XCTAssertEqual(read["unanswered"] as? [String], ["installs", "locates", "notifies"], "one wrong entry writes nothing")
    }

    /// A publish carries the record from the review document into the
    /// reading; the module is complete only with all three lists answered.
    func testAPublishCarriesTheRecordIntoTheReading() async throws {
        try await open()
        let (call, _) = try await entries()
        _ = try await set(["installs": [["guid": guid, "name": "EFI_PEI_READ_ONLY_VARIABLE2_PPI", "kind": "ppi",
                                         "address": call, "condition": "always", "purpose": "Gives the store to the modules after it.",
                                         "method": "reinstall"]],
                           "locates": []])
        _ = try await host.publish(module, by: "agent")
        let writer = await host.writer
        let store = try XCTUnwrap(writer as? ContentStore)
        let reading = try XCTUnwrap(try store.analysis(module: module)?.reading)
        let interfaces = try XCTUnwrap(reading.interfaces)
        XCTAssertEqual(interfaces.installs?.first?.method, .reinstall)
        XCTAssertEqual(interfaces.installs?.first?.purpose, "Gives the store to the modules after it.")
        XCTAssertEqual(interfaces.locates, [])
        XCTAssertNil(interfaces.notifies)
        XCTAssertEqual(interfaces.unanswered, ["notifies"])
    }
}
