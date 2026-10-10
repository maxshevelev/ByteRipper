import AgentKit
import Foundation
import ToolModuleKit
import UEFIImage

/// What the UEFI Structure answers an agent from the bytes alone, with its
/// panel open or not (`Design/AGENT_PLAN.md`, stage 3): the tree, one node in
/// full, a search, and what holds an address.
///
/// Every answer is read off the pane's one shared tree (`UEFITreeProviding`)
/// — the tree the panel draws — so a question asked with the panel closed
/// opens the same branches the panel will find open, and costs it nothing. A
/// node is named by its place in the tree, `"0.2.5"`, which is exact for these
/// bytes; a node in another dump is found by what it is (`uefi_find`), since
/// two images do not number their volumes alike.
@MainActor
public enum UEFIAgentQueries {
    nonisolated public static var all: [ToolAgentQuery] { all(catalogue: { .empty }) }

    /// The same, with `uefi_node` naming a file by the GUID catalogue as the
    /// panel does — `catalogue` is the UI target's, which holds the download.
    nonisolated public static func all(catalogue: @escaping @Sendable () async -> GuidsCatalogue) -> [ToolAgentQuery] {
        [tree, node(catalogue: catalogue), find, at]
    }

    // MARK: - uefi_tree

    nonisolated static let tree = ToolAgentQuery(
        name: "uefi_tree",
        title: "UEFI tree",
        description: """
            The structure of a firmware image as the UEFI Structure panel shows it: regions, volumes, \
            files, sections, NVRAM stores and the rest. Without `node`, the top of the tree and a one-line \
            summary of the image; with it, that node and its children. `depth` (1–3) goes further down. \
            Each node: `id` (pass it back as `node`), type, subtype, name, GUID, its bytes (`start`, `end`, \
            or `in_compressed: true` when it lives inside a decompressed section and has no file address), \
            and `children` — a count, or "unread" for a container not opened yet (asking for it opens it). \
            With `depth` above 1 a child carries the levels under it as `below`. Pages: `limit` is the most \
            children of `node` on one page, a ceiling — a page also stops before the answer passes the size \
            bound and then says `truncated: "size"`; pass `next` back as `after` until it is null. A child \
            whose levels below are too large alone comes without them, marked `truncated: "item"`; ask for \
            it as `node`. Ids belong to the document they were listed on: a part opened with `open_part` has \
            a tree of its own, with ids that start over (the parent's 0.3.4.1.2.5 is 0.0.5 in the \
            decoded block), so give the `document` the id came from.
            """,
        properties: [
            "node": AgentSchema.string("A node id such as \"0.2.5\" from an earlier answer. Default: the top."),
            "depth": AgentSchema.integer("How many levels below the node. Default 1, at most 3."),
            "limit": AgentSchema.limit(default: 100, maximum: 400),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        let tree = try await readyTree(host)
        let id = try nodeID(arguments.optionalString("node"))
        let depth = Int(max(1, min(3, try arguments.has("depth") ? arguments.integer("depth") : 1)))
        let limit = try arguments.limit(default: 100, maximum: 400)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([host.contentVersion, id.description, depth]))

        @MainActor func listed(_ node: UEFINode, level: Int) async -> JSONValue {
            var entry = summary(of: node, in: tree)
            if level < depth, !node.children.isEmpty || node.isExpandable {
                var below: [JSONValue] = []
                for child in await expanded(node.id, in: tree) {
                    below.append(await listed(child, level: level + 1))
                }
                entry = merged(entry, ["below": .array(below)])
            }
            return entry
        }

        var answer: [String: JSONValue] = [:]
        if id == .root {
            answer["image"] = .string(UEFITreeDisplay.summary(of: tree.image()))
        } else {
            guard let node = tree.node(id) else { throw unknownNode(id) }
            answer["node"] = summary(of: node, in: tree)
        }
        let children = await expanded(id, in: tree)
        var items: [JSONValue] = []
        for child in children.dropFirst(paging.first).prefix(limit) {
            items.append(await listed(child, level: 1))
        }
        answer["total"] = .count(children.count)
        return .json(try paging.answer(answer, key: "children", items: items, total: children.count,
                                       bound: arguments.answerBound) { item in
            guard case .object(var members) = item, members["below"] != nil else { return nil }
            members["below"] = nil
            members["truncated"] = "item"
            return .object(members)
        })
    }

    // MARK: - uefi_node

    nonisolated static func node(catalogue: @escaping @Sendable () async -> GuidsCatalogue) -> ToolAgentQuery {
      ToolAgentQuery(
        name: "uefi_node",
        title: "UEFI node",
        description: """
            Everything the UEFI Structure panel's detail says about one node: its fields (header values, \
            sizes, attributes, checksums — a wrong checksum is marked `problem`), its tables, the path of \
            names down to it, and the parser's diagnostics inside its bytes. NVRAM variables come with their \
            value decoded.
            """,
        properties: ["node": AgentSchema.string("The node's id, e.g. \"0.2.5\".")],
        required: ["node"]
    ) { host, arguments in
        let tree = try await readyTree(host)
        let id = try nodeID(arguments.string("node"))
        guard id != .root else { throw AgentToolError("The top of the tree is not a node; call `uefi_tree`.") }
        _ = await reachable(id, in: tree)
        guard let node = tree.node(id) else { throw unknownNode(id) }
        let image = tree.image()
        let readers = tree.spaceReaders
        let repairs = UEFIChecksumCheck.repairs(in: image, only: [id], readers: readers)[id] ?? []
        // What the panel's detail is built with: the catalogue's name for a
        // file, and for Lenovo's DMI store the drivers that read it.
        let names = node.kind == .file && node.guid != nil ? await catalogue() : .empty
        let lenovo = await lenovoDMIReaders(for: node, in: tree)
        let detail = UEFIDetail.build(
            for: node, image: image,
            reader: readers.reader(for: node.space) ?? ImageReader([UInt8]()),
            repairs: repairs,
            catalogue: names,
            lenovoDMIReaders: lenovo)

        var answer: [String: JSONValue] = [
            "node": summary(of: node, in: tree),
            "path": .array(path(to: id, in: tree).map { .string($0) }),
            "title": .string(detail.title),
            "fields": .array(detail.fields.map { field in
                var entry: [String: JSONValue] = ["label": .string(field.label), "value": .string(field.value)]
                if field.isProblem { entry["problem"] = true }
                return .object(entry)
            })
        ]
        if !detail.tables.isEmpty {
            answer["tables"] = .array(detail.tables.map { table in
                ["title": .string(table.title),
                 "columns": .array(table.columns.map { .string($0) }),
                 "rows": .array(table.rows.map { row in .array(row.map { .string($0.text) }) })]
            })
        }
        if let range = node.fileRange {
            let inside = image.diagnostics.filter { range.contains($0.offset) && $0.inside == nil }
            if !inside.isEmpty {
                answer["diagnostics"] = .array(inside.prefix(20).map { .string($0.message) })
            }
        }
        return .json(.object(answer))
      }
    }

    /// The drivers that read Lenovo's DMI store, for a node of the store —
    /// searched for the first time it is asked, as the panel does, and
    /// waited for a while; without them the detail says less, not wrong.
    static func lenovoDMIReaders(for node: UEFINode, in tree: LazyUEFITree) async -> LenovoDMIFirmwareReaders? {
        guard UEFILenovoDMIDetail.reads(node.kind) else { return nil }
        if tree.lenovoDMIReadersSearched { return tree.lenovoDMIReaders }
        final class Wait { var done = false; var token: LazyUEFITree.ObserverToken? }
        let wait = Wait()
        return await withCheckedContinuation { continuation in
            let finish: @MainActor () -> Void = {
                guard !wait.done else { return }
                wait.done = true
                if let token = wait.token { tree.removeObserver(token) }
                continuation.resume(returning: tree.lenovoDMIReaders)
            }
            wait.token = tree.addObserver { change in
                if case .lenovoDMIReadersRead = change { finish() }
            }
            tree.resolveLenovoDMIReaders()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                finish()
            }
        }
    }

    // MARK: - uefi_find

    nonisolated static let find = ToolAgentQuery(
        name: "uefi_find",
        title: "Find UEFI nodes",
        description: """
            Finds nodes anywhere in the image — opening every volume and decompressing every section it \
            can, which takes a few seconds on a large image the first time. Give any of: `name` (part of the \
            name, any case; the whole name with `exact`), `guid` (exact), `type` (the Type column, e.g. \
            "File", "Section", "Volume", "VSS entry", "NVAR entry"). All given must match. Each match has its \
            id and the path of names to it; `total` counts them all. Pages: `limit` is a ceiling — a page \
            also stops before the answer passes the size bound and then says `truncated: "size"`; pass \
            `next` back as `after` until it is null.
            """,
        properties: [
            "name": AgentSchema.string("Part of the node's name, any case."),
            "exact": AgentSchema.boolean("Match the whole name rather than a part of it. Default false."),
            "guid": AgentSchema.string("A GUID, e.g. \"8C8CE578-8A3D-4F1C-9935-896185C32DD3\"."),
            "type": AgentSchema.string("The node type as the Type column shows it."),
            "limit": AgentSchema.limit(default: 50, maximum: 200),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        let name = try arguments.optionalString("name")?.lowercased()
        let guid = try arguments.optionalString("guid")?.uppercased()
        let type = try arguments.optionalString("type")?.lowercased()
        let exact = try arguments.bool("exact", default: false)
        guard name != nil || guid != nil || type != nil else {
            throw AgentToolError("Give at least one of `name`, `guid` or `type`.")
        }
        let limit = try arguments.limit(default: 50, maximum: 200)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([host.contentVersion, name, guid, type, exact]))
        let tree = try await readyTree(host)
        await openEverything(in: tree)

        var matches: [JSONValue] = []
        var total = 0
        for node in tree.image().allNodes {
            if let name {
                let own = UEFITreeDisplay.ownName(of: node) ?? ""
                let names = [node.name.lowercased(), own.lowercased()]
                guard exact ? names.contains(name) : names.contains(where: { $0.contains(name) }) else { continue }
            }
            if let guid, node.guid?.description.uppercased() != guid { continue }
            if let type, UEFITreeDisplay.typeText(for: node).lowercased() != type { continue }
            total += 1
            if total > paging.first, matches.count < limit {
                matches.append(merged(summary(of: node, in: tree),
                                      ["path": .array(path(to: node.id, in: tree).map { .string($0) })]))
            }
        }
        return .json(try paging.answer(["total": .count(total)], key: "matches", items: matches, total: total,
                                       bound: arguments.answerBound))
    }

    // MARK: - uefi_at

    nonisolated static let at = ToolAgentQuery(
        name: "uefi_at",
        title: "UEFI nodes at an address",
        description: """
            The chain of nodes that hold a byte of the file, outermost first — region, volume, file, \
            section — opening the containers on the way. The last one is the innermost.
            """,
        properties: ["offset": AgentSchema.offset("A file address, e.g. \"0x7F3000\".")],
        required: ["offset"]
    ) { host, arguments in
        let offset = try arguments.offset("offset")
        guard offset < host.contentSize else {
            throw AgentToolError("Offset \(hex(offset)) is past the end of the file, which is \(hex(host.contentSize)) bytes long.")
        }
        let tree = try await readyTree(host)
        let chain = await withCheckedContinuation { continuation in
            tree.materialize(containing: offset) { continuation.resume(returning: $0) }
        }
        return .json(["offset": .string(hex(offset)), "chain": .array(chain.map { summary(of: $0, in: tree) })])
    }

    // MARK: - The tree

    /// The pane's shared tree, once its top level is there.
    public static func readyTree(_ host: any ToolReadHost) async throws -> LazyUEFITree {
        guard let tree = (host as? any UEFITreeProviding)?.uefiTree() else {
            throw AgentToolError("This document has no UEFI structure to read.")
        }
        await withCheckedContinuation { continuation in
            tree.whenReady { continuation.resume() }
        }
        return tree
    }

    /// The children of `id`, reading them first if nobody has yet.
    public static func expanded(_ id: NodeID, in tree: LazyUEFITree) async -> [UEFINode] {
        if id == .root { return tree.rootNodes }
        return await withCheckedContinuation { continuation in
            tree.expand(id) { continuation.resume(returning: $0) }
        }
    }

    /// Opens every container on the way down to `id`, so a node an agent was
    /// told about in an earlier session — before the branch was read in this
    /// one — can still be found by its id.
    public static func reachable(_ id: NodeID, in tree: LazyUEFITree) async -> Bool {
        var path: [Int] = []
        for index in id.path.dropLast() {
            path.append(index)
            _ = await expanded(NodeID(path), in: tree)
        }
        return tree.node(id) != nil
    }

    /// Opens every closed container in the image, breadth first.
    public static func openEverything(in tree: LazyUEFITree) async {
        var queue = tree.rootNodes
        while !queue.isEmpty {
            let node = queue.removeFirst()
            let children = node.isExpandable ? await expanded(node.id, in: tree) : node.children
            queue.append(contentsOf: children)
        }
    }

    // MARK: - Shapes

    public static func summary(of node: UEFINode, in tree: LazyUEFITree) -> JSONValue {
        var entry: [String: JSONValue] = [
            "id": .string(node.id.description),
            "type": .string(UEFITreeDisplay.typeText(for: node)),
            "name": .string(UEFITreeDisplay.ownName(of: node) ?? node.name)
        ]
        let subtype = UEFITreeDisplay.subtypeText(for: node)
        if !subtype.isEmpty { entry["subtype"] = .string(subtype) }
        if let guid = node.guid { entry["guid"] = .string(guid.description) }
        if let range = node.fileRange {
            entry["start"] = .string(hex(range.lowerBound))
            entry["end"] = .string(hex(range.upperBound))
        } else {
            entry["in_compressed"] = true
            entry["size"] = .string(hex(node.range.upperBound - node.range.lowerBound))
        }
        if node.isExpandable, node.children.isEmpty {
            entry["children"] = "unread"
        } else if !node.children.isEmpty {
            entry["children"] = .count(node.children.count)
        }
        if node.isErased { entry["erased"] = true }
        return .object(entry)
    }

    /// The names from the top of the tree down to `id`.
    public static func path(to id: NodeID, in tree: LazyUEFITree) -> [String] {
        (1...max(1, id.path.count)).compactMap { length in
            tree.node(NodeID(Array(id.path.prefix(length)))).map { UEFITreeDisplay.ownName(of: $0) ?? $0.name }
        }
    }

    public static func nodeID(_ text: String?) throws -> NodeID {
        guard let text, !text.isEmpty, text != "root" else { return .root }
        let parts = text.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else {
            throw AgentToolError("`\(text)` is not a node id. Ids look like \"0.2.5\" and come from `uefi_tree`, `uefi_find` or `uefi_at`.")
        }
        return NodeID(parts.compactMap { $0 })
    }

    public static func unknownNode(_ id: NodeID) -> AgentToolError {
        AgentToolError("No node \(id.description) in this image. Ids come from `uefi_tree`, `uefi_find` or `uefi_at` on the same document: "
            + "a part opened with `open_part` has its own tree and its own ids, and a call that leaves out `document` goes to the focused one — "
            + "the part, after `open_part` — so give the `document` the id was listed on.")
    }

    static func merged(_ value: JSONValue, _ more: [String: JSONValue]) -> JSONValue {
        guard case .object(var members) = value else { return value }
        members.merge(more) { _, new in new }
        return .object(members)
    }

    public static func hex(_ value: UInt64) -> String { String(format: "0x%llX", value) }
}
