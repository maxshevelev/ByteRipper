import AgentKit
import Foundation
import ToolModuleKit
import UEFIImage

/// Every checksum of an image checked at once, for an agent
/// (`Design/AGENT_PLAN.md`): what the panel's red flags say, without opening
/// each branch to see them. The check is the panel's own
/// (`UEFIChecksumCheck`), so a node is wrong here exactly when its row is
/// flagged there.
@MainActor
public enum UEFIAgentChecksums {
    nonisolated public static var all: [ToolAgentQuery] { [check] }

    nonisolated static let check = ToolAgentQuery(
        name: "uefi_checksums",
        title: "Check the UEFI checksums",
        description: """
            Checks every checksum the UEFI Structure panel checks — a volume's header checksum, a file's \
            header and data checksums, a microcode's, an AMD PSP or BIOS directory's — in the whole image or \
            under `node`, opening every volume and decompressing every section it can, and lists the nodes \
            whose checksums are wrong: which field, what is stored and what it should be. A node inside a \
            compressed section is checked against what the section decompresses to; it is marked \
            `in_compressed` and cannot be fixed in place. `checked` counts the nodes that carry a checksum, \
            `wrong` those listed. `uefi_fix_checksum` puts them right, one node or all at once. Pages: \
            `limit` is a ceiling — a page also stops before the answer passes the size bound and then says \
            `truncated: "size"`; pass `next` back as `after` until it is null.
            """,
        properties: [
            "node": AgentSchema.string("Check only under this node, e.g. \"0.2\". Default: the whole image."),
            "limit": AgentSchema.limit(default: 50, maximum: 200),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        let under = try UEFIAgentQueries.nodeID(arguments.optionalString("node"))
        let limit = try arguments.limit(default: 50, maximum: 200)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([host.contentVersion, under.description]))
        let tree = try await UEFIAgentQueries.readyTree(host)
        if under != .root {
            _ = await UEFIAgentQueries.reachable(under, in: tree)
            guard tree.node(under) != nil else { throw UEFIAgentQueries.unknownNode(under) }
        }
        let scan = await scan(tree, under: under)

        var items: [JSONValue] = []
        for (index, wrong) in scan.wrong.enumerated() where index >= paging.first && items.count < limit {
            items.append(UEFIAgentQueries.merged(UEFIAgentQueries.summary(of: wrong.node, in: tree), [
                "path": .array(UEFIAgentQueries.path(to: wrong.node.id, in: tree).map { .string($0) }),
                "checksums": .array(wrong.fields.map { field in
                    var members: [String: JSONValue] = [
                        "field": .string(field.field.rawValue),
                        "at": .string(UEFIAgentQueries.hex(field.offset)),
                        "stored": .string(hexText(field.stored)),
                        "should_be": .string(hexText(field.shouldBe))
                    ]
                    if wrong.node.fileRange == nil { members["at_in"] = "decompressed" }
                    return .object(members)
                })
            ]))
        }
        let fixable = scan.wrong.filter { $0.node.space == .file }.count
        return .json(try paging.answer(
            ["checked": .count(scan.checked), "wrong": .count(scan.wrong.count), "fixable": .count(fixable)],
            key: "nodes", items: items, total: scan.wrong.count, bound: arguments.answerBound))
    }

    // MARK: - The pass

    /// One wrong checksum: which, where — a file address, or an offset in the
    /// decompressed buffer for a node inside a compressed section — and the
    /// bytes there and the bytes that belong there.
    struct WrongField {
        let field: UEFIChecksumField
        let offset: UInt64
        let stored: [UInt8]
        let shouldBe: [UInt8]
    }

    struct WrongNode {
        let node: UEFINode
        let fields: [WrongField]
    }

    struct Scan {
        /// The nodes that carry a checksum.
        var checked = 0
        /// Those with one wrong, in tree order.
        var wrong: [WrongNode] = []
    }

    /// Opens everything, then checks every node under `under` that carries a
    /// checksum, off the main actor.
    static func scan(_ tree: LazyUEFITree, under: NodeID) async -> Scan {
        await UEFIAgentQueries.openEverything(in: tree)
        let image = tree.image()
        let readers = tree.spaceReaders
        let nodes = image.allNodes.filter { node in
            Self.carriesChecksum(node) && Self.isUnder(node.id, under)
        }
        let ids = Set(nodes.map(\.id))
        return await Task.detached(priority: .userInitiated) {
            let repairs = UEFIChecksumCheck.repairs(in: image, only: ids, readers: readers)
            var scan = Scan(checked: nodes.count)
            for node in nodes {
                guard let nodeRepairs = repairs[node.id], let reader = readers.reader(for: node.space) else { continue }
                let fields = nodeRepairs.map { repair in
                    WrongField(
                        field: UEFIChecksumCheck.fields(of: [repair], for: node).first ?? .volume,
                        offset: repair.offset,
                        stored: reader.bytes(at: repair.offset, count: UInt64(repair.bytes.count)) ?? [],
                        shouldBe: repair.bytes)
                }
                scan.wrong.append(WrongNode(node: node, fields: fields))
            }
            return scan
        }.value
    }

    /// The writes that put every checksum under `under` right that can be
    /// written in place, and the nodes they fix.
    ///
    /// A file can hold a volume, and that volume files: fixing an inner file
    /// changes the body of the outer one, whose checksum then has to be worked
    /// out over the fixed bytes. So the pass is repeated over a copy of the
    /// file with each round's fixes in it, until a round finds nothing.
    static func fixAll(_ tree: LazyUEFITree, under: NodeID) async -> (writes: [ToolTransaction.Write], fixed: [UEFINode]) {
        await UEFIAgentQueries.openEverything(in: tree)
        let image = tree.image()
        let file = tree.imageReader
        let nodes = image.allNodes.filter { node in
            node.space == .file && Self.carriesChecksum(node) && Self.isUnder(node.id, under)
        }
        let ids = Set(nodes.map(\.id))
        let found: (bytes: [UInt64: UInt8], fixed: Set<NodeID>) = await Task.detached(priority: .userInitiated) {
            guard var copy = file.bytes(file.all) else { return ([:], []) }
            var changed: [UInt64: UInt8] = [:]
            var fixed: Set<NodeID> = []
            for _ in 0..<8 {
                let reader = ImageReader(Data(copy))
                let round = UEFIChecksumCheck.repairs(in: image, only: ids, readers: SpaceReaders(file: reader))
                guard !round.isEmpty else { break }
                for (id, repairs) in round {
                    fixed.insert(id)
                    for repair in repairs {
                        for (index, byte) in repair.bytes.enumerated() {
                            let offset = repair.offset + UInt64(index)
                            copy[Int(offset)] = byte
                            changed[offset] = byte
                        }
                    }
                }
            }
            return (changed, fixed)
        }.value
        // Runs of neighbouring bytes, one write each.
        var writes: [ToolTransaction.Write] = []
        for offset in found.bytes.keys.sorted() {
            let byte = found.bytes[offset]!
            if let last = writes.last, last.offset + UInt64(last.bytes.count) == offset {
                writes[writes.count - 1] = ToolTransaction.Write(offset: last.offset, bytes: last.bytes + [byte])
            } else {
                writes.append(ToolTransaction.Write(offset: offset, bytes: [byte]))
            }
        }
        return (writes, nodes.filter { found.fixed.contains($0.id) })
    }

    nonisolated static func carriesChecksum(_ node: UEFINode) -> Bool {
        node.kind == .volume || node.kind == .file || node.kind == .microcode || node.kind == .amdDirectory
    }

    nonisolated static func isUnder(_ id: NodeID, _ under: NodeID) -> Bool {
        under == .root || id.path.starts(with: under.path)
    }

    nonisolated static func hexText(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
