import XCTest
import UEFIImage
@testable import UEFITool

/// What `uefi_node` answers about a module's dependency expression, and what
/// `uefi_find`'s `depends_on` matches: the same tree the panel reads.
@MainActor
final class DependencyAgentTests: XCTestCase {
    private let first = EFIGUID("11111111-1111-1111-1111-111111111111")!
    private let second = EFIGUID("22222222-2222-2222-2222-222222222222")!
    private let unrelated = EFIGUID("33333333-3333-3333-3333-333333333333")!

    private func le(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private func section(type: UInt8, body: [UInt8]) -> [UInt8] {
        le(UInt64(4 + body.count), 3) + [type] + body
    }

    private func file(guid: UInt8, type: UInt8, body: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: guid, count: 16)
        header += [0, 0xAA, type, 0]
        header += le(UInt64(0x18 + body.count), 3)
        header.append(0xF8)
        let sum = header.enumerated()
            .filter { ![0x10, 0x11, 0x17].contains($0.offset) }
            .reduce(UInt8(0)) { $0 &+ $1.element }
        header[0x10] = 0 &- sum
        return header + body
    }

    private func volume(length: UInt64, files: [[UInt8]]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 16)
        header += KnownGUIDs.ffsV2.bytes
        header += le(length, 8)
        header += Array("_FVH".utf8)
        header += le(0x800, 4)
        header += le(0x48, 2)
        header += [0, 0]
        header += [0, 0, 0, 2]
        header += le(1, 4) + le(length, 4) + le(0, 8)
        var sum: UInt16 = 0
        for index in stride(from: 0, to: header.count, by: 2) {
            sum &+= UInt16(header[index]) | UInt16(header[index + 1]) << 8
        }
        let checksum = 0 &- sum
        header[0x32] = UInt8(checksum & 0xFF)
        header[0x33] = UInt8(checksum >> 8)
        var bytes = header
        for file in files {
            while bytes.count % 8 != 0 { bytes.append(0xFF) }
            bytes += file
        }
        bytes += [UInt8](repeating: 0xFF, count: Int(length) - bytes.count)
        return bytes
    }

    private func tree() async -> LazyUEFITree {
        let depex = [0x02] + first.bytes + [0x02] + second.bytes + [0x03, 0x08]
        let peim = file(guid: 0x33, type: 0x06, body: section(type: 0x1B, body: depex))
        let driver = file(guid: 0x44, type: 0x07, body: [0xDE, 0xAD])
        let bytes = volume(length: 0x1000, files: [peim, driver])
        let tree = LazyUEFITree(bytes)
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await UEFIAgentQueries.openEverything(in: tree)
        return tree
    }

    func testTheNodeAnswerCarriesTheExpression() async throws {
        let tree = await tree()
        let node = try XCTUnwrap(tree.image().allNodes.first { $0.kind == .file && $0.subtype == 0x06 })
        let answer = try XCTUnwrap(UEFIAgentQueries.dependencyAnswer(
            for: node, in: tree,
            catalogue: GuidsCatalogue(names: [first: "First PPI", second: "Second PPI"])))

        XCTAssertEqual(answer["kind"]?.stringValue, "PEI")
        XCTAssertEqual(answer["expression"]?.stringValue, "First PPI AND Second PPI")
        XCTAssertEqual(answer["always"]?.boolValue, false)
        XCTAssertEqual(answer["malformed"]?.boolValue, false)
        XCTAssertEqual(answer["guids"], .array([.string(first.description), .string(second.description)]))
        XCTAssertEqual(answer["problems"], .array([]))

        let tokens = try XCTUnwrap(answer["tokens"]?.arrayValue)
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[0]["operation"]?.stringValue, "PUSH")
        XCTAssertEqual(tokens[0]["guid"]?.stringValue, first.description)
        XCTAssertEqual(tokens[0]["name"]?.stringValue, "First PPI")
        XCTAssertEqual(tokens[2]["operation"]?.stringValue, "AND")
        XCTAssertEqual(tokens[3]["operation"]?.stringValue, "END")
    }

    func testDependsOnMatchesTheFilesThatPushTheGUID() async throws {
        let tree = await tree()
        let peim = try XCTUnwrap(tree.image().allNodes.first { $0.kind == .file && $0.subtype == 0x06 })
        let driver = try XCTUnwrap(tree.image().allNodes.first { $0.kind == .file && $0.subtype == 0x07 })
        XCTAssertTrue(UEFIAgentQueries.dependencyPushes(first, in: peim, in: tree))
        XCTAssertTrue(UEFIAgentQueries.dependencyPushes(second, in: peim, in: tree))
        XCTAssertFalse(UEFIAgentQueries.dependencyPushes(unrelated, in: peim, in: tree))
        XCTAssertFalse(UEFIAgentQueries.dependencyPushes(first, in: driver, in: tree))
    }

    func testAFileWithoutADependencyHasNoAnswer() async throws {
        let tree = await tree()
        let driver = try XCTUnwrap(tree.image().allNodes.first { $0.kind == .file && $0.subtype == 0x07 })
        XCTAssertNil(UEFIAgentQueries.dependencyAnswer(for: driver, in: tree, catalogue: .empty))
    }
}
