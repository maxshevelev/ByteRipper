import AgentKit
import Foundation
import ToolModuleKit
import UEFIImage

/// What the nodes the parser cannot name hold (`Design/AGENT_PLAN.md`,
/// issue #34): padding, unused and unknown areas, raw files, each judged by
/// its bytes — empty, text, data or code — so the one with the board's data
/// in it is found without reading each by hand.
///
/// Only a judgement and a few short strings are answered, never the bytes. An
/// area the flash map names a key, a password or an MSDM table gives no
/// strings at all.
@MainActor
public enum UEFIAgentRegions {
    nonisolated public static var all: [ToolAgentQuery] { [scan] }

    nonisolated static let scan = ToolAgentQuery(
        name: "region_scan",
        title: "Scan the nameless areas",
        description: """
            Judges by their bytes the nodes the parser cannot name — Padding (the flash map's Unused, \
            Unknown and named areas among them) and Raw files and sections — under `node` (default: the \
            BIOS region), in address order. A node its children divide is replaced by them; one whose only \
            child covers it whole stays, naming the child as `inner`. Each: `node`, `name`, `type`, \
            `subtype`, `guid`, `start`, `end`, `size`; `fill` (the share of 0xFF and 0x00 bytes), \
            `first_nonfill` and `last_nonfill` (the first and the last other byte); `class` — `empty` (at \
            least 99% fill), `text` (most of the other bytes are ASCII or UTF-16LE strings of 4 characters \
            or more), `code` (x86-64 instructions, by a heuristic: frequent REX.W moves, calls and \
            returns, or a PE image), else `data`; and up to five `strings` with their addresses. The \
            bytes themselves are never answered: `read` or `uefi_node_data` read them. An area whose name \
            in the flash map says MSDM, Password or Key gives its class and sizes, no strings, and \
            `redacted: true`. `kinds` picks the node types (the Type or Subtype column), default Padding \
            and Raw; `min_size` leaves out smaller nodes. Pages: `limit`, `after` as in `uefi_find`. With \
            `survey`, the same area across a folder of dumps.
            """,
        properties: [
            "node": AgentSchema.string("Scan under this node, e.g. \"0.2\". Default: the BIOS region, or the whole image."),
            "kinds": AgentSchema.strings("Node types to take, as the Type or Subtype column shows them. Default [\"Padding\", \"Raw\"]."),
            "min_size": AgentSchema.offset("Leave out nodes smaller than this. Default 0x100."),
            "limit": AgentSchema.limit(default: 50, maximum: 200),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        let kinds = Set((try arguments.has("kinds") ? arguments.strings("kinds") : ["Padding", "Raw"]).map { $0.lowercased() })
        let minSize = try arguments.optionalOffset("min_size") ?? 0x100
        let limit = try arguments.limit(default: 50, maximum: 200)
        let tree = try await UEFIAgentQueries.readyTree(host)
        var under = try UEFIAgentQueries.nodeID(arguments.optionalString("node"))
        if under == .root, let bios = tree.rootNodes.flatMap({ [$0] + $0.children }).first(where: isBIOSRegion) {
            under = bios.id
        }
        if under != .root {
            _ = await UEFIAgentQueries.reachable(under, in: tree)
        }
        let start: [UEFINode]
        if under == .root {
            start = tree.rootNodes
        } else {
            guard let node = tree.node(under) else { throw UEFIAgentQueries.unknownNode(under) }
            start = [node]
        }
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [host.contentVersion, under.description, kinds.sorted().joined(separator: ","), minSize]))

        var taken: [(node: UEFINode, inner: UEFINode?)] = []
        for node in start {
            taken += await collect(node, kinds: kinds, minSize: minSize, in: tree)
        }
        let reader = tree.imageReader
        let page = Array(taken.dropFirst(paging.first).prefix(limit))
        let judged = await Task.detached(priority: .userInitiated) {
            page.map { entry -> Judgement? in
                guard let range = entry.node.fileRange, let bytes = reader.bytes(range) else { return nil }
                return judge(bytes, at: range.lowerBound)
            }
        }.value

        var items: [JSONValue] = []
        for (entry, judgement) in zip(page, judged) {
            guard case .object(var members) = UEFIAgentQueries.summary(of: entry.node, in: tree) else { continue }
            members["node"] = members.removeValue(forKey: "id")
            members["children"] = nil
            if let range = entry.node.fileRange { members["size"] = .string(UEFIAgentQueries.hex(UInt64(range.count))) }
            if let inner = entry.inner {
                members["inner"] = ["node": .string(inner.id.description),
                                    "name": .string(UEFITreeDisplay.ownName(of: inner) ?? inner.name)]
            }
            if let judgement {
                members["class"] = .string(judgement.kind.rawValue)
                members["fill"] = .double((judgement.fill * 1000).rounded() / 1000)
                if let first = judgement.firstNonFill { members["first_nonfill"] = .string(UEFIAgentQueries.hex(first)) }
                if let last = judgement.lastNonFill { members["last_nonfill"] = .string(UEFIAgentQueries.hex(last)) }
                if isSecret(entry.node, in: tree) {
                    members["strings"] = .array([])
                    members["redacted"] = true
                } else {
                    members["strings"] = .array(judgement.strings.map { found in
                        ["at": .string(UEFIAgentQueries.hex(found.offset)), "text": .string(found.text),
                         "encoding": .string(found.utf16 ? "utf16le" : "ascii")]
                    })
                }
            }
            items.append(.object(members))
        }
        return .json(try paging.answer(["total": .count(taken.count), "under": .string(under.description)],
                                       key: "nodes", items: items, total: taken.count, bound: arguments.answerBound))
    }

    // MARK: - Which nodes

    /// The nodes of `kinds` under `node`, in the file: a matching node its
    /// children divide gives way to the matching ones among them; one whose
    /// only child covers it whole is taken itself, the child named.
    static func collect(_ node: UEFINode, kinds: Set<String>, minSize: UInt64,
                        in tree: LazyUEFITree) async -> [(node: UEFINode, inner: UEFINode?)] {
        guard node.space == .file, let range = node.fileRange else { return [] }
        let children = (node.isExpandable || !node.children.isEmpty
            ? await UEFIAgentQueries.expanded(node.id, in: tree) : []).filter { $0.space == .file }
        var below: [(node: UEFINode, inner: UEFINode?)] = []
        for child in children {
            below += await collect(child, kinds: kinds, minSize: minSize, in: tree)
        }
        let matches = kinds.contains(UEFITreeDisplay.typeText(for: node).lowercased())
            || kinds.contains(UEFITreeDisplay.subtypeText(for: node).lowercased())
        guard matches, UInt64(range.count) >= minSize else { return below }
        let whole = children.count == 1 && children[0].range == node.range
        if !below.isEmpty, !whole { return below }
        return [(node, whole ? children[0] : nil)]
    }

    nonisolated static func isBIOSRegion(_ node: UEFINode) -> Bool {
        UEFITreeDisplay.typeText(for: node) == "Region" && UEFITreeDisplay.subtypeText(for: node) == "BIOS"
    }

    /// Whether the node or an area holding it is named for a secret in the
    /// flash map: its strings are never answered.
    static func isSecret(_ node: UEFINode, in tree: LazyUEFITree) -> Bool {
        (1...max(1, node.id.path.count)).contains { length in
            guard let holder = tree.node(NodeID(Array(node.id.path.prefix(length)))) else { return false }
            return isSecretName(UEFITreeDisplay.ownName(of: holder) ?? holder.name)
        }
    }

    /// MSDM, Password or Key as a word of the name, any case.
    nonisolated public static func isSecretName(_ name: String) -> Bool {
        let words = name.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }
        return words.contains { ["msdm", "password", "passwords", "key", "keys"].contains($0) }
    }

    // MARK: - Judging the bytes

    enum Kind: String { case empty, text, data, code }

    struct FoundString: Equatable {
        var offset: UInt64
        var text: String
        var utf16: Bool
    }

    struct Judgement {
        var kind: Kind
        var fill: Double
        var firstNonFill: UInt64?
        var lastNonFill: UInt64?
        var strings: [FoundString]
    }

    /// The share of fill below which an area is `empty`.
    nonisolated static let emptyFill = 0.99
    /// The share of the non-fill bytes strings must make up for `text`.
    nonisolated static let textShare = 0.5
    /// x86-64 markers per KiB of non-fill bytes from which an area is `code`.
    nonisolated static let codeMarkersPerKiB = 6.0

    /// Judges `bytes`, which start at file address `base`.
    nonisolated static func judge(_ bytes: [UInt8], at base: UInt64) -> Judgement {
        let fillCount = bytes.reduce(0) { $0 + ($1 == 0xFF || $1 == 0x00 ? 1 : 0) }
        let fill = bytes.isEmpty ? 1 : Double(fillCount) / Double(bytes.count)
        let first = bytes.firstIndex { $0 != 0xFF && $0 != 0x00 }
        let last = bytes.lastIndex { $0 != 0xFF && $0 != 0x00 }
        let runs = strings(in: bytes)
        let shown = Array(runs.prefix(5)).map {
            FoundString(offset: base + UInt64($0.offset), text: String($0.text.prefix(64)), utf16: $0.utf16)
        }
        var judgement = Judgement(kind: .data, fill: fill,
                                  firstNonFill: first.map { base + UInt64($0) },
                                  lastNonFill: last.map { base + UInt64($0) }, strings: shown)
        let other = bytes.count - fillCount
        if fill >= emptyFill || other == 0 {
            judgement.kind = .empty
            return judgement
        }
        // Text: the characters of the strings against every byte that is
        // not fill. A UTF-16 character's zero byte is fill already.
        let inStrings = runs.reduce(0) { $0 + $1.text.count }
        if Double(inStrings) / Double(other) >= textShare {
            judgement.kind = .text
        } else if looksLikeCode(bytes, nonFill: other) {
            judgement.kind = .code
        }
        return judgement
    }

    /// A PE image's `MZ`, or REX.W moves (48 89, 48 8B), stack adjustments
    /// (48 83 EC) and near calls (E8) as often as compiled x86-64 has them —
    /// a random byte pair turns up once in 64 KiB, code has dozens per KiB.
    nonisolated static func looksLikeCode(_ bytes: [UInt8], nonFill: Int) -> Bool {
        if bytes.count >= 2, bytes[0] == 0x4D, bytes[1] == 0x5A { return true }
        guard bytes.count > 4, nonFill >= 256 else { return false }
        var markers = 0
        for index in 0..<(bytes.count - 2) where bytes[index] == 0x48 {
            let next = bytes[index + 1]
            if next == 0x89 || next == 0x8B || (next == 0x83 && bytes[index + 2] == 0xEC) { markers += 1 }
        }
        return Double(markers) / (Double(nonFill) / 1024) >= codeMarkersPerKiB
    }

    /// Printable ASCII runs and UTF-16LE runs of four characters or more, in
    /// order of where they start.
    nonisolated static func strings(in bytes: [UInt8]) -> [(offset: Int, text: String, utf16: Bool)] {
        func printable(_ byte: UInt8) -> Bool { byte >= 0x20 && byte < 0x7F }
        var found: [(offset: Int, text: String, utf16: Bool)] = []
        var index = 0
        while index < bytes.count {
            // UTF-16LE first: its every other byte is zero, which would cut an
            // ASCII run to one character.
            var units = 0
            while index + 2 * units + 1 < bytes.count, printable(bytes[index + 2 * units]),
                  bytes[index + 2 * units + 1] == 0 {
                units += 1
            }
            if units >= 4 {
                let text = String(decoding: (0..<units).map { bytes[index + 2 * $0] }, as: UTF8.self)
                found.append((index, text, true))
                index += 2 * units
                continue
            }
            var length = 0
            while index + length < bytes.count, printable(bytes[index + length]) { length += 1 }
            if length >= 4 {
                found.append((index, String(decoding: bytes[index..<(index + length)], as: UTF8.self), false))
                index += length
            } else {
                index += max(1, length)
            }
        }
        return found
    }
}
