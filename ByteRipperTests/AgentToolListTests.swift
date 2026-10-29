import AgentKit
import Foundation
import XCTest
@testable import ByteRipper

/// What the app's agent plans against, pinned in a file
/// (`Design/SERVER_HEADLESS_PLAN.md` phase 3): a tool moving between hosts, a
/// description edited for one of them, a schema key renamed — each changes the
/// list an agent has already cached, so each has to be seen and meant.
///
/// The golden is `AgentToolList.json` beside this file, one tool per line
/// block as `tools/list` answers them. A run with no golden writes one and
/// fails: read it, then commit it. A run that differs writes
/// `AgentToolList.actual.json` beside it and names the tools that changed.
@MainActor
final class AgentToolListTests: XCTestCase {
    private var defaultsName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
    }

    override func tearDown() async throws {
        discardIsolatedDefaults(defaultsName, defaults)
        defaults = nil
        try await super.tearDown()
    }

    func testTheAppServesTheToolListItsAgentsPlanAgainst() async throws {
        let desk = AgentDesk(controllers: { [] }, keyController: { nil })
        let service = AgentService(desk: desk, defaults: defaults,
                                   socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        let client = AgentTestClient(service)
        let tools = try await client.tools()
        XCTAssertFalse(tools.arrayValue?.isEmpty ?? true, "the app served no tools")

        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("AgentToolList.json")
        let actual = tools.prettyText + "\n"
        guard let expected = try? String(contentsOf: path, encoding: .utf8) else {
            try actual.write(to: path, atomically: true, encoding: .utf8)
            XCTFail("There was no \(path.lastPathComponent): one was written from this run. Read it, then commit it.")
            return
        }
        guard expected != actual else { return }

        let beside = path.deletingPathExtension().appendingPathExtension("actual.json")
        try actual.write(to: beside, atomically: true, encoding: .utf8)
        XCTFail("The tool list changed: \(Self.changed(expected, actual)). \(beside.lastPathComponent) is what this "
            + "run serves; if the change is meant, replace \(path.lastPathComponent) with it.")
    }

    /// Which tools differ, by name, for the failure's first line.
    static func changed(_ expected: String, _ actual: String) -> String {
        func byName(_ text: String) -> [String: JSONValue] {
            var named: [String: JSONValue] = [:]
            for tool in (try? JSONValue.parse(Data(text.utf8)))?.arrayValue ?? [] {
                guard let name = tool["name"]?.stringValue else { continue }
                named[name] = tool
            }
            return named
        }
        let before = byName(expected)
        let after = byName(actual)
        var said: [String] = []
        for name in before.keys.sorted() where after[name] == nil { said.append("removed \(name)") }
        for name in after.keys.sorted() where before[name] == nil { said.append("added \(name)") }
        for name in before.keys.sorted()
        where after[name] != nil && before[name] != after[name] {
            said.append("changed \(name)")
        }
        return said.isEmpty ? "same tools, in another order or number" : said.joined(separator: ", ")
    }
}
