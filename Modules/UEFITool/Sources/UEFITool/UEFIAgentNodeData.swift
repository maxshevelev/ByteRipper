import AgentKit
import BytePattern
import Foundation
import ToolModuleKit
import UEFIImage

/// A node's own bytes for an agent, wherever the node lives — in the file, or
/// in what a compressed section decompressed to, where it has no file address
/// and `read` cannot reach it (`Design/AGENT_PLAN.md`, search and extract).
///
/// The bytes are the tree's: a node in the file is read from the document as
/// it is now, unsaved edits included; one inside a compressed section from the
/// buffer the tree already decompressed it into, never decompressed again.
@MainActor
public enum UEFIAgentNodeData {
    nonisolated public static var all: [ToolAgentQuery] { [data] }

    /// Which of a node's bytes.
    public enum Part: String, CaseIterable, Sendable {
        case body, header, all
        /// What a compressed section decompresses to — the whole buffer its
        /// children are read from.
        case decompressed
    }

    /// A node's bytes: where they are read from and which they are.
    public struct Bytes {
        public var node: UEFINode
        public var reader: ImageReader
        /// The part, in `space`.
        public var range: Range<UInt64>
        /// Where the part is: the file, or a buffer — the node's own, or for
        /// `decompressed` the one the section opens to.
        public var space: ByteSpace
        public var tree: LazyUEFITree

        /// The part's bytes as file addresses; nil inside a compressed section.
        public var fileRange: Range<UInt64>? { space == .file ? range : nil }
        public var isCompressed: Bool { space != .file }
    }

    /// The node `text` names and the bytes of its `part`.
    public static func bytes(_ host: any ToolReadHost, node text: String, part: Part) async throws -> Bytes {
        let tree = try await UEFIAgentQueries.readyTree(host)
        let id = try UEFIAgentQueries.nodeID(text)
        guard id != .root else { throw AgentToolError("The top of the tree is not a node; call `uefi_tree`.") }
        _ = await UEFIAgentQueries.reachable(id, in: tree)
        guard let node = tree.node(id) else { throw UEFIAgentQueries.unknownNode(id) }
        if part == .decompressed {
            guard let body = UEFIPresenter.decompressedBody(for: node) else {
                throw AgentToolError("Node \(id) is not a compressed section; part \"decompressed\" is a compressed section's.")
            }
            _ = await UEFIAgentQueries.expanded(id, in: tree)
            guard let reader = tree.spaceReaders.reader(for: body.space), reader.count > 0 else {
                throw AgentToolError("Section \(id) could not be decompressed.")
            }
            return Bytes(node: node, reader: reader, range: 0..<reader.count, space: body.space, tree: tree)
        }
        let range: Range<UInt64>
        switch part {
        case .body: range = node.body
        case .header: range = node.header
        case .all, .decompressed: range = node.range
        }
        guard !range.isEmpty else {
            throw AgentToolError(part == .all
                ? "Node \(id) holds no bytes."
                : "Node \(id) has no \(part.rawValue); ask for part \"all\"\(part == .header ? " or \"body\"" : " or \"header\"").")
        }
        guard let reader = tree.spaceReaders.reader(for: node.space) else {
            throw AgentToolError("Node \(id) is inside a compressed section whose contents could not be read.")
        }
        return Bytes(node: node, reader: reader, range: range, space: node.space, tree: tree)
    }

    /// Whether `node` is a compressed section, whose children are read from
    /// what it decompresses to.
    public static func isCompressedSection(_ node: UEFINode) -> Bool {
        UEFIPresenter.decompressedBody(for: node) != nil
    }

    /// The compressed section a node's bytes came out of: the outermost one,
    /// the section in the file, and how many more it is nested in. Nil for a
    /// node of the file.
    public static func source(of node: UEFINode, in tree: LazyUEFITree, including itself: Bool = false) -> JSONValue? {
        guard node.space != .file || itself else { return nil }
        var path: [Int] = []
        var outer: UEFINode?
        var depth = 0
        for index in itself ? node.id.path : Array(node.id.path.dropLast()) {
            path.append(index)
            guard let ancestor = tree.node(NodeID(path)), ancestor.compression != nil else { continue }
            if outer == nil, ancestor.space == .file { outer = ancestor }
            depth += 1
        }
        guard let outer, let range = outer.fileRange else { return nil }
        var members: [String: JSONValue] = [
            "section": .string(outer.id.description),
            "start": .string(UEFIAgentQueries.hex(range.lowerBound)),
            "end": .string(UEFIAgentQueries.hex(range.upperBound))
        ]
        if let algorithm = outer.compression?.algorithm { members["algorithm"] = .string(algorithm) }
        if depth > 1 { members["nested"] = .count(depth - 1) }
        return .object(members)
    }

    /// The deepest node under `node` whose bytes hold `range` whole — in the
    /// node's own space, opening containers on the way down.
    public static func deepest(covering range: Range<UInt64>, in space: ByteSpace, under node: UEFINode,
                               in tree: LazyUEFITree) async -> UEFINode {
        var current = node
        while true {
            let children = current.isExpandable || !current.children.isEmpty
                ? await UEFIAgentQueries.expanded(current.id, in: tree) : []
            guard let child = children.first(where: {
                $0.space == space && $0.range.lowerBound <= range.lowerBound
                    && range.upperBound <= $0.range.upperBound && !$0.range.isEmpty
            }) else { return current }
            current = child
        }
    }

    // MARK: - uefi_node_data

    nonisolated static let data = ToolAgentQuery(
        name: "uefi_node_data",
        title: "UEFI node bytes",
        description: """
            Reads a node's bytes as `read` reads a document's — rows of 16 with their address, text, or \
            integers — at addresses inside the node's `part` (`body` by default, `header`, or `all`), \
            from 0. Works for a node inside a compressed section too, which has no file address and \
            which `read` cannot reach: its bytes are what the tree decompressed it to, and `source` says \
            which compressed section in the file they came out of. For a compressed section itself, \
            part `decompressed` is what it decompresses to — the buffer its children are in. `size` is the whole part's, to read \
            on by `offset`; at most 4096 bytes at a time. `ranges` reads several places of the part in one \
            call, each as its own row of the answer's `ranges`, 4096 bytes in all. A node of the file gives `file_start` as well: \
            its bytes are the document's at that address, unsaved edits included, and `read`, `reveal` \
            and `write` work there. `find_bytes` with `node` searches the node and everything decompressed or decoded under it.
            """,
        properties: [
            "node": AgentSchema.string("The node's id, e.g. \"0.2.5.0.0.1.0.530.2\"."),
            "part": AgentSchema.choice(Part.allCases.map(\.rawValue), "Which bytes of the node. Default \"body\". `offset` counts from this part's start: a `find_bytes` match's `body_offset` goes with \"body\", its `node_offset` with \"all\"."),
            "offset": AgentSchema.offset("Where to start inside the part. Default 0x0."),
            "length": AgentSchema.offset("How many bytes. Default 256, at most 4096."),
            "ranges": AgentSchema.strings("Instead of `offset` and `length`: several places, each \"offset+length\", such as \"0x100+0x20\"; at most 64."),
            "format": AgentSchema.choice(AgentBytes.formats, "How to show them. Default \"hex\"."),
            "endian": AgentSchema.choice(["little", "big"], "For u16, u32 and u64. Default \"little\".")
        ],
        required: ["node"]
    ) { host, arguments in
        let part = Part(rawValue: try arguments.choice("part", from: Part.allCases.map(\.rawValue), default: "body"))!
        let offset = try arguments.optionalOffset("offset") ?? 0
        let asked = try arguments.optionalOffset("length") ?? 256
        let format = try arguments.choice("format", from: AgentBytes.formats, default: "hex")
        let bigEndian = try arguments.choice("endian", from: ["little", "big"], default: "little") == "big"
        let ranges = try parsed(ranges: arguments)
        guard asked > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
        guard asked <= 4096 else { throw AgentToolError("Argument `length`: at most 4096 bytes in one read.") }
        let found = try await bytes(host, node: arguments.string("node"), part: part)
        let size = UInt64(found.range.count)
        @MainActor func stamped(_ answer: inout [String: JSONValue]) {
            answer["node"] = .string(found.node.id.description)
            answer["part"] = .string(part.rawValue)
            answer["size"] = .string(UEFIAgentQueries.hex(size))
            answer["in_compressed"] = .bool(found.isCompressed)
            if let fileRange = found.fileRange { answer["file_start"] = .string(UEFIAgentQueries.hex(fileRange.lowerBound)) }
            if let source = source(of: found.node, in: found.tree, including: part == .decompressed) {
                answer["source"] = source
            }
        }
        if !ranges.isEmpty {
            var rows: [JSONValue] = []
            for range in ranges {
                guard range.offset < size else {
                    throw AgentToolError("Range \(UEFIAgentQueries.hex(range.offset))+\(UEFIAgentQueries.hex(range.length)) "
                        + "starts past the end of the \(part.rawValue), which is \(UEFIAgentQueries.hex(size)) bytes long.")
                }
                let length = min(range.length, size - range.offset)
                let start = found.range.lowerBound + range.offset
                guard let read = found.reader.bytes(start..<(start + length)), read.count == Int(length) else {
                    throw AgentToolError("Those bytes of node \(found.node.id) could not be read.")
                }
                var row = AgentBytes.shown(read, at: range.offset, format: format, bigEndian: bigEndian)
                row["offset"] = .string(UEFIAgentQueries.hex(range.offset))
                row["length"] = .string(UEFIAgentQueries.hex(length))
                if length < range.length { row["cut_at_end_of_part"] = true }
                rows.append(.object(row))
            }
            var answer: [String: JSONValue] = ["ranges": .array(rows)]
            stamped(&answer)
            return .json(.object(answer))
        }
        guard offset < size else {
            throw AgentToolError("Offset \(UEFIAgentQueries.hex(offset)) is past the end of the \(part.rawValue), "
                + "which is \(UEFIAgentQueries.hex(size)) bytes long.")
        }
        let length = min(asked, size - offset)
        let start = found.range.lowerBound + offset
        guard let read = found.reader.bytes(start..<(start + length)), read.count == Int(length) else {
            throw AgentToolError("Those bytes of node \(found.node.id) could not be read.")
        }
        var answer = AgentBytes.shown(read, at: offset, format: format, bigEndian: bigEndian)
        stamped(&answer)
        answer["offset"] = .string(UEFIAgentQueries.hex(offset))
        answer["length"] = .string(UEFIAgentQueries.hex(length))
        if length < asked { answer["cut_at_end_of_part"] = true }
        return .json(.object(answer))
    }

    /// `ranges`, read and bounded before any node is opened. Empty when not given.
    nonisolated private static func parsed(ranges arguments: AgentArguments) throws -> [(offset: UInt64, length: UInt64)] {
        let texts = try arguments.strings("ranges")
        guard !texts.isEmpty else { return [] }
        guard !arguments.has("offset"), !arguments.has("length") else {
            throw AgentToolError("Give `ranges`, or `offset` and `length`, not both.")
        }
        guard texts.count <= 64 else { throw AgentToolError("Argument `ranges`: at most 64 in one read.") }
        var total: UInt64 = 0
        let ranges = try texts.map { text -> (offset: UInt64, length: UInt64) in
            let (offset, length) = try parsed(range: text, argument: "ranges")
            // Checked one by one, so the sum never passes what a UInt64 holds.
            total += min(length, 4097)
            return (offset, length)
        }
        guard total <= 4096 else { throw AgentToolError("Argument `ranges`: at most 4096 bytes in one read, in all.") }
        return ranges
    }

    /// "offset+length", as `ranges`, `pattern_range` and `any` write a place.
    nonisolated private static func parsed(range text: String, argument: String) throws -> (offset: UInt64, length: UInt64) {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let offset = try? AgentArguments(["n": .string(String(parts[0]))]).offset("n"),
              let length = try? AgentArguments(["n": .string(String(parts[1]))]).offset("n"), length > 0,
              !offset.addingReportingOverflow(length).overflow else {
            throw AgentToolError("Argument `\(argument)`: \"\(text)\" is not \"offset+length\", such as \"0x100+0x20\".")
        }
        return (offset, length)
    }

    // MARK: - A search pattern from a node's bytes

    /// The most bytes a pattern takes from a node.
    nonisolated static let maxPatternBytes: UInt64 = 1 << 20

    /// `find_bytes`' words for the arguments that take its pattern from a node.
    nonisolated public static let patternProperties: [String: JSONValue] = [
        "pattern_node": AgentSchema.string("Take the pattern from this node's bytes instead of `text` or `hex`."),
        "pattern_part": AgentSchema.choice(Part.allCases.map(\.rawValue), "Which bytes of `pattern_node`. Default \"body\". `pattern_range` counts from this part's start: a match's `body_offset` goes with \"body\", its `node_offset` with \"all\"."),
        "pattern_range": AgentSchema.string("The stretch of the part to take, \"offset+length\": \"0x100+0x200\". Required with `pattern_node`; at most 1 MiB."),
        "any": AgentSchema.strings("Bytes of that pattern that match anything, each \"offset+length\" from the pattern's start: [\"0x10+4\"].")
    ]

    /// The pattern `find_bytes` was asked to take from a node's bytes; nil when
    /// it was not.
    public static func pattern(_ host: any ToolReadHost, _ arguments: AgentArguments) async throws -> MaskedPattern? {
        guard let node = try arguments.optionalString("pattern_node") else {
            for name in ["pattern_part", "pattern_range", "any"] where arguments.has(name) {
                throw AgentToolError("`\(name)` belongs to `pattern_node`, which was not given.")
            }
            return nil
        }
        guard !arguments.has("text"), !arguments.has("hex") else {
            throw AgentToolError("Give `text`, `hex` or `pattern_node`, one of them.")
        }
        guard let text = try arguments.optionalString("pattern_range") else {
            throw AgentToolError("`pattern_node` needs `pattern_range`, \"offset+length\".")
        }
        let (offset, length) = try parsed(range: text, argument: "pattern_range")
        guard length <= maxPatternBytes else { throw AgentToolError("Argument `pattern_range`: at most 1 MiB.") }
        let part = Part(rawValue: try arguments.choice("pattern_part", from: Part.allCases.map(\.rawValue), default: "body"))!
        let found = try await bytes(host, node: node, part: part)
        let size = UInt64(found.range.count)
        guard offset <= size, length <= size - offset else {
            throw AgentToolError("`pattern_range` \(text) does not fit the \(part.rawValue), "
                + "which is \(UEFIAgentQueries.hex(size)) bytes long.")
        }
        let start = found.range.lowerBound + offset
        guard let read = found.reader.bytes(start..<(start + length)), read.count == Int(length) else {
            throw AgentToolError("Those bytes of node \(found.node.id) could not be read.")
        }
        var wild = [Bool](repeating: false, count: read.count)
        for item in try arguments.strings("any") {
            let (from, count) = try parsed(range: item, argument: "any")
            guard from <= length, count <= length - from else {
                throw AgentToolError("Argument `any`: \(item) is outside the pattern, which is \(UEFIAgentQueries.hex(length)) bytes long.")
            }
            for index in from..<(from + count) { wild[Int(index)] = true }
        }
        guard wild.contains(false) else {
            throw AgentToolError("Argument `any` covers the whole pattern: it would match everywhere.")
        }
        return MaskedPattern(bytes: read, isWild: wild)
    }
}
