import Foundation
import XCTest
@testable import CodeAnalysis

/// `byteripper-cas`: the store's command line, as the skill's Python calls it.
final class CASCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CASCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func run(_ arguments: String...) -> CASCommand.Output {
        CASCommand.run(["--store", directory.appendingPathComponent("store").path] + arguments)
    }

    private func json(_ output: CASCommand.Output) throws -> Any {
        try JSONSerialization.jsonObject(with: output.stdout, options: .fragmentsAllowed)
    }

    private func file(_ text: String) throws -> String {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private let module = #"{"sha256":"\#(String(repeating: "a", count: 64))","size":4,"name":"M","phase":"pei"}"#
    private let recipe = #"{"id":"code-v4-ghidra-12.1.2","exporter":4,"ghidra":"12.1.2","script":"ExportCode.java","types":"edk2-stable202608","passes":["ApplyUefi.java"]}"#

    func testHelloNamesTheProtocol() throws {
        let output = run("hello")
        XCTAssertEqual(output.status, 0)
        let answer = try XCTUnwrap(json(output) as? [String: Any])
        XCTAssertEqual(answer["protocol"] as? Int, CASCommand.protocolVersion)
    }

    func testAnObjectGoesInAndComesOutAsItsBytes() throws {
        let put = run("put-object", try file("hello"))
        let digest = try XCTUnwrap((json(put) as? [String: Any])?["sha256"] as? String)
        XCTAssertEqual(run("get-object", digest).stdout, Data("hello".utf8))
    }

    func testAnAnalysisKeepsEveryFieldItWasGiven() throws {
        let put = run("put-analysis", "--module", module, "--recipe", recipe,
                      "--artifact", try file(#"{"functions":[]}"#),
                      "--reading", #"{"project":"p","rev":1}"#)
        XCTAssertEqual(put.status, 0, String(decoding: put.stderr, as: UTF8.self))
        let found = run("analysis", String(repeating: "a", count: 64))
        let manifest = try XCTUnwrap(json(found) as? [String: Any])
        XCTAssertEqual((manifest["recipe"] as? [String: Any])?["types"] as? String, "edk2-stable202608")
        XCTAssertEqual((manifest["module"] as? [String: Any])?["phase"] as? String, "pei")
        XCTAssertEqual((manifest["reading"] as? [String: Any])?["rev"] as? Int, 1)
    }

    func testAnUnknownFieldIsRefusedNotDropped() throws {
        let output = run("put-analysis", "--module", #"{"sha256":"x","size":1,"name":"M","colour":"red"}"#,
                         "--recipe", recipe, "--artifact", try file("{}"))
        XCTAssertEqual(output.status, 2)
        XCTAssertTrue(String(decoding: output.stderr, as: UTF8.self).contains("colour"))
    }

    func testAMissingAnalysisIsNullAndARefusalIsAnErrorObject() throws {
        XCTAssertTrue(try json(run("analysis", String(repeating: "b", count: 64))) is NSNull)
        let refused = run("get-object", "../../etc/passwd")
        XCTAssertEqual(refused.status, 1)
        let error = try JSONSerialization.jsonObject(with: refused.stderr) as? [String: Any]
        XCTAssertNotNil(error?["error"])
    }

    func testAUsageErrorIsPlainTextAndHelpIsTheUsage() {
        let bogus = run("bogus")
        XCTAssertEqual(bogus.status, 2)
        let text = String(decoding: bogus.stderr, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("byteripper-cas: unknown command bogus\n"), text)
        XCTAssertTrue(text.contains("usage: byteripper-cas"), "an unknown command shows the usage")
        XCTAssertNil(try? JSONSerialization.jsonObject(with: bogus.stderr))

        let extra = run("verify", "extra")
        XCTAssertEqual(extra.status, 2)
        XCTAssertEqual(String(decoding: extra.stderr, as: UTF8.self),
                       "byteripper-cas: unexpected argument extra\n", "a wrong argument is one line")

        let help = run("help")
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(String(decoding: help.stdout, as: UTF8.self).hasPrefix("usage: byteripper-cas"))
        XCTAssertTrue(help.stderr.isEmpty)
    }

    func testGuidRemoveIsADryRunUntilApplied() throws {
        let guid = "9C98130A-8921-45EB-86F3-16041C6BB7AD"
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        _ = try store.offerGuid(GuidOffer(guid: guid, name: "gAmdFactoryResetPpiGuid", kind: .ppi,
                                          source: .review(module: SHA256Digest(data: Data("m".utf8)), address: "0x10")),
                                by: "x")
        let dry = run("guid-remove", guid, "--reason", "wrong", "--expect-name", "gAmdFactoryResetPpiGuid")
        XCTAssertEqual(dry.status, 0, String(decoding: dry.stderr, as: UTF8.self))
        XCTAssertEqual((try json(dry) as? [String: Any])?["applied"] as? Bool, false)
        XCTAssertNotNil(try store.guidRegistry().entries[guid])
        XCTAssertNotEqual(run("guid-remove", guid, "--reason", "wrong", "--expect-name", "gOtherGuid", "--apply").status, 0)
        let done = run("guid-remove", guid, "--reason", "wrong", "--apply")
        XCTAssertEqual(done.status, 0, String(decoding: done.stderr, as: UTF8.self))
        XCTAssertNil(try store.guidRegistry().entries[guid])
    }
}
