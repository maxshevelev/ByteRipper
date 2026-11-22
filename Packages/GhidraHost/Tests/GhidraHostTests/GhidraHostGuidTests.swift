import AgentKit
import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// `ghidra_guid_add`: a review's name for a GUID reaches the store's GUID
/// registry through the host, as the host's holder, for a module the server
/// knows; a conflict is an answer naming the registry's name.
final class GhidraHostGuidTests: XCTestCase {
    private var directory: URL!
    private let guid = "9C98130A-8921-45EB-86F3-16041C6BB7AD"
    private let module = SHA256Digest(data: Data("ChipsetSvcPei".utf8))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhidraHostGuidTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func run(_ tool: AgentTool, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let answer = try await tool.run(AgentCall(tool: tool.name, arguments: AgentArguments(arguments)))
        guard case .json(let value) = answer else { throw AgentToolError("\(answer)") }
        return value
    }

    func testAReviewsNameReachesTheRegistryAsTheHostsHolder() async throws {
        let projects = directory.appendingPathComponent("projects", isDirectory: true)
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: projects, holder: "local MCP"), writer: store)
        let tool = try XCTUnwrap(GhidraTools.tools(backend: host).first { $0.name == "ghidra_guid_add" })
        let arguments: [String: JSONValue] = [
            "guid": .string(guid), "name": "gAmdFactoryResetPpiGuid", "kind": "ppi",
            "module": .string(module.hex), "address": "0x9A0F1C0"
        ]
        do {
            _ = try await run(tool, arguments)
            XCTFail("a module the server does not know")
        } catch let error as AgentToolError {
            XCTAssertTrue(error.message.contains("not one this server knows"), error.message)
        }

        try FileManager.default.createDirectory(at: projects.appendingPathComponent(module.hex),
                                                withIntermediateDirectories: true)
        var dry = arguments
        dry["dry_run"] = true
        let would = try await run(tool, dry)
        XCTAssertEqual(would["outcome"], "added")
        XCTAssertTrue(try store.guidRegistry().entries.isEmpty, "a dry run writes nothing")

        let added = try await run(tool, arguments)
        XCTAssertEqual(added["outcome"], "added")
        XCTAssertEqual(try store.guidRegistry().entries[guid]?.by, "local MCP")

        var other = arguments
        other["name"] = "gAmdPspFtpmPpiGuid"
        let conflict = try await run(tool, other)
        XCTAssertEqual(conflict["outcome"], "conflict")
        XCTAssertEqual(conflict["offered"], "gAmdPspFtpmPpiGuid")
        XCTAssertEqual(try store.guidRegistry().entries[guid]?.name, "gAmdFactoryResetPpiGuid")

        var typeName = arguments
        typeName["name"] = "AMD_FACTORY_RESET_PPI"
        do {
            _ = try await run(tool, typeName)
            XCTFail("a name out of the registry's form")
        } catch let error as AgentToolError {
            XCTAssertTrue(error.message.contains("gAmdFactoryResetPpiGuid"), error.message)
        }
    }
}
