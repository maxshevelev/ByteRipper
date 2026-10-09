import AgentKit
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
            on by `offset`; at most 4096 bytes at a time. A node of the file gives `file_start` as well: \
            its bytes are the document's at that address, unsaved edits included, and `read`, `reveal` \
            and `write` work there. `find_bytes` with `node` searches the same bytes.
            """,
        properties: [
            "node": AgentSchema.string("The node's id, e.g. \"0.2.5.0.0.1.0.530.2\"."),
            "part": AgentSchema.choice(Part.allCases.map(\.rawValue), "Which bytes of the node. Default \"body\"."),
            "offset": AgentSchema.offset("Where to start inside the part. Default 0x0."),
            "length": AgentSchema.offset("How many bytes. Default 256, at most 4096."),
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
        guard asked > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
        guard asked <= 4096 else { throw AgentToolError("Argument `length`: at most 4096 bytes in one read.") }
        let found = try await bytes(host, node: arguments.string("node"), part: part)
        let size = UInt64(found.range.count)
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
        answer["node"] = .string(found.node.id.description)
        answer["part"] = .string(part.rawValue)
        answer["offset"] = .string(UEFIAgentQueries.hex(offset))
        answer["length"] = .string(UEFIAgentQueries.hex(length))
        answer["size"] = .string(UEFIAgentQueries.hex(size))
        answer["in_compressed"] = .bool(found.isCompressed)
        if let fileRange = found.fileRange { answer["file_start"] = .string(UEFIAgentQueries.hex(fileRange.lowerBound)) }
        if let source = source(of: found.node, in: found.tree, including: part == .decompressed) {
            answer["source"] = source
        }
        if length < asked { answer["cut_at_end_of_part"] = true }
        return .json(.object(answer))
    }
}
