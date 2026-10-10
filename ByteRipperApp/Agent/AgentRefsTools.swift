import AgentKit
import ByteRipperCore
import Foundation
import ToolModuleKit
import UEFIImage
import UEFITool

/// Who in a firmware image refers to an address or a GUID
/// (`Design/AGENT_PLAN.md`, issue #34): every place its bytes occur — in the
/// file and in what the compressed sections decompress to — answered per FFS
/// file rather than per section, so "which modules use this region" is one
/// call instead of a search and a lookup per hit.
///
/// The search is `find_bytes`'s (`SearchEngine.matches`) over the same
/// buffers the tree decompressed; nothing is decompressed a second time.
@MainActor
final class AgentRefsTools {
    private let desk: AgentDesk
    private let diff: AgentDiffTools

    init(desk: AgentDesk, diff: AgentDiffTools) {
        self.desk = desk
        self.diff = diff
    }

    nonisolated func tools() -> [AgentTool] { [refsTool] }

    /// The most hits one file lists before the rest are only counted.
    nonisolated static let maxHitsPerFile = 20

    private nonisolated var refsTool: AgentTool {
        AgentTool(
            name: "refs",
            title: "Find references to an address or a GUID",
            description: """
                Every place in a firmware image that refers to an address or a GUID, in the file and inside \
                its compressed sections, grouped by the FFS file each is in — so "which modules use this \
                region" is one call. `guid` is written as usual and searched in its EFI byte order. \
                `address` is a file address (or, with `relative_to` "region", an offset in the BIOS region) \
                and is searched in the forms `forms` names: `bus` — where the BIOS region is mapped below \
                4 GiB, the region's end at 0x100000000, as 32 and 64 bits; `file` — the file address; \
                `region` — the offset in the BIOS region; each little-endian, 32 bits. Address hits are \
                chance as often as not in code: each says the `form` it matched, and none is hidden, but a \
                shorter form is not listed apart where it only matched inside a longer one. `scope`: "all" \
                (default), "raw" (the file as stored) or "compressed" (what the sections decompress to). \
                Per file: `file` (its id), `name`, `guid`, `type`, `in_compressed`, and `hits` — `form`, \
                `section` and `section_offset` in it, `file_start` where the hit has a file address. A hit \
                in no FFS file is listed by the deepest `node` holding it. `total` counts the hits, `files` \
                the groups. Pages: `limit` is a ceiling on files — a page also stops before the answer \
                passes the size bound and says `truncated: "size"`; pass `next` back as `after`. With \
                `survey`, which dumps of a folder refer to a GUID.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "guid": AgentSchema.string("A GUID, e.g. \"8C8CE578-8A3D-4F1C-9935-896185C32DD3\". Give `guid` or `address`."),
                "address": AgentSchema.offset("An address, e.g. \"0x668000\". Give `guid` or `address`."),
                "relative_to": AgentSchema.choice(["file", "region"],
                                                  "What `address` counts from: the file (default) or the BIOS region."),
                "forms": AgentSchema.strings("Which forms of `address` to search: \"bus\", \"file\", \"region\". Default all three."),
                "scope": AgentSchema.choice(["all", "raw", "compressed"], "Where to search. Default \"all\"."),
                "limit": AgentSchema.limit(default: 50, maximum: 200),
                "after": AgentSchema.after
            ]),
            annotations: .readOnly
        ) { call in
            try await self.refs(call.arguments)
        }
    }

    /// One byte pattern and the form it stands for.
    struct Form: Equatable {
        var name: String
        var bytes: [UInt8]
    }

    /// The patterns `address` is searched as, longest first within a form.
    /// `bios` is the BIOS region's file range, the whole file when the image
    /// is the BIOS alone. A form whose value fits in a byte is left out: it
    /// would match nearly everywhere.
    nonisolated static func forms(address: UInt64, relativeToRegion: Bool, bios: Range<UInt64>,
                                  names: Set<String>) -> (forms: [Form], skipped: [String]) {
        let file = relativeToRegion ? bios.lowerBound + address : address
        let region = file - bios.lowerBound
        let bus = 0x1_0000_0000 - (bios.upperBound - file)
        var forms: [Form] = []
        var skipped: [String] = []
        func add(_ name: String, _ value: UInt64, width: Int) {
            guard names.contains(name) else { return }
            guard value > 0xFF else {
                if !skipped.contains(name) { skipped.append(name) }
                return
            }
            let bytes = (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
            // The same bytes under two names — a BIOS-only image, where the
            // file and the region are one — are searched once, by the first.
            guard !forms.contains(where: { $0.bytes == bytes }) else { return }
            forms.append(Form(name: name, bytes: bytes))
        }
        add("bus", bus, width: 8)
        add("bus", bus, width: 4)
        add("file", file, width: 4)
        add("region", region, width: 4)
        return (forms, skipped)
    }

    /// One place the bytes were found: in which space, where in it, and as
    /// which form.
    struct Hit {
        var range: Range<UInt64>
        var form: Int
    }

    /// The hits of one buffer without those that only matched inside a hit
    /// of a longer form — `bus` 32 bits inside `bus` 64, a short value inside
    /// a long one.
    nonisolated static func withoutInner(_ hits: [Hit], forms: [Form]) -> [Hit] {
        // The hits come in order of where they start, and a form is at most
        // 16 bytes: an enclosing hit starts at most that far before.
        let sorted = hits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        return sorted.enumerated().filter { index, hit in
            var other = index - 1
            while other >= 0, hit.range.lowerBound - sorted[other].range.lowerBound <= 16 {
                if Self.encloses(sorted[other], hit, forms) { return false }
                other -= 1
            }
            other = index + 1
            while other < sorted.count, sorted[other].range.lowerBound == hit.range.lowerBound {
                if Self.encloses(sorted[other], hit, forms) { return false }
                other += 1
            }
            return true
        }.map(\.element)
    }

    private nonisolated static func encloses(_ outer: Hit, _ inner: Hit, _ forms: [Form]) -> Bool {
        forms[outer.form].bytes.count > forms[inner.form].bytes.count
            && outer.range.lowerBound <= inner.range.lowerBound && inner.range.upperBound <= outer.range.upperBound
    }

    private func refs(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try diff.resolve(arguments.optionalString("document"))
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let scope = try arguments.choice("scope", from: ["all", "raw", "compressed"], default: "all")
        let limit = try arguments.limit(default: 50, maximum: 200)
        let guidText = try arguments.optionalString("guid")
        guard (guidText == nil) != (!arguments.has("address")) else {
            throw AgentToolError("Give `guid` or `address`, one of them.")
        }
        let tree = try await UEFIAgentQueries.readyTree(host)
        await UEFIAgentQueries.openEverything(in: tree)
        let image = tree.image()

        var envelope: [String: JSONValue] = ["document": .string(place.id), "scope": .string(scope)]
        let forms: [Form]
        if let guidText {
            guard let guid = EFIGUID(guidText) else {
                throw AgentToolError("`guid` is not a GUID; write it as \"8C8CE578-8A3D-4F1C-9935-896185C32DD3\".")
            }
            forms = [Form(name: "guid", bytes: guid.bytes)]
            envelope["guid"] = .string(guid.description)
        } else {
            let address = try arguments.offset("address")
            let relative = try arguments.choice("relative_to", from: ["file", "region"], default: "file") == "region"
            let names = Set(try arguments.has("forms") ? arguments.strings("forms") : ["bus", "file", "region"])
            if let unknown = names.first(where: { !["bus", "file", "region"].contains($0) }) {
                throw AgentToolError("`forms` takes \"bus\", \"file\" and \"region\"; not \"\(unknown)\".")
            }
            let bios = Self.biosRegion(in: image) ?? 0..<place.pane.fileSize
            let file = relative ? bios.lowerBound + address : address
            guard file < place.pane.fileSize else {
                throw AgentToolError("\(AgentHostTools.hexText(file)) is past the end of \(place.id).")
            }
            // An address outside the BIOS region has no bus or region form.
            guard bios.contains(file) || names.contains("file") else {
                throw AgentToolError("\(AgentHostTools.hexText(file)) is not inside the BIOS region "
                    + "\(AgentHostTools.hexText(bios.lowerBound))–\(AgentHostTools.hexText(bios.upperBound)); "
                    + "only the `file` form means anything for it.")
            }
            let made = Self.forms(address: address, relativeToRegion: relative, bios: bios,
                                  names: bios.contains(file) ? names : ["file"])
            forms = made.forms
            guard !forms.isEmpty else {
                throw AgentToolError("Every form asked for is a value under 0x100, which matches nearly everywhere.")
            }
            if !made.skipped.isEmpty { envelope["skipped_forms"] = .array(made.skipped.map { .string($0) }) }
            envelope["forms"] = .object(Dictionary(uniqueKeysWithValues: forms.map {
                ("\($0.name)\($0.bytes.count == 8 ? "64" : "")", JSONValue.string(AgentBytes.hexText($0.bytes)))
            }))
        }

        // The buffers searched: the file as stored, and what each compressed
        // section decompressed to — each with the node its hits are placed
        // under.
        struct Buffer {
            var storage: any ByteStorage
            var space: ByteSpace
            var under: UEFINode?
        }
        var buffers: [Buffer] = []
        if scope != "compressed" {
            buffers.append(Buffer(storage: try diff.snapshot(place), space: .file, under: nil))
        }
        if scope != "raw" {
            for node in image.allNodes where UEFIAgentNodeData.isCompressedSection(node) {
                guard let body = UEFIPresenter.decompressedBody(for: node),
                      let reader = tree.spaceReaders.reader(for: body.space), reader.count > 0 else { continue }
                buffers.append(Buffer(storage: ReaderStorage(reader: reader), space: body.space, under: node))
            }
        }

        let patterns = forms.map { MaskedPattern(bytes: $0.bytes) }
        var found: [(buffer: Int, hit: Hit)] = []
        for (index, buffer) in buffers.enumerated() {
            let storage = buffer.storage
            let hits = try await Task.detached(priority: .userInitiated) {
                // One pass per form: a single pattern takes the engine's fast
                // path, several at once do not.
                var hits: [Hit] = []
                for (form, pattern) in patterns.enumerated() {
                    try SearchEngine.matches(of: [pattern], in: storage, overlapping: true) { match, _ in
                        hits.append(Hit(range: match, form: form))
                        return true
                    }
                }
                return Self.withoutInner(hits, forms: forms)
            }.value
            found += hits.map { (index, $0) }
        }

        // Each hit placed in its FFS file, or in the deepest node when it is
        // in none; the groups in the order their first hits were found.
        var groups: [(key: String, entry: [String: JSONValue], hits: [JSONValue], count: Int)] = []
        var groupIndex: [String: Int] = [:]
        for (bufferIndex, hit) in found {
            let buffer = buffers[bufferIndex]
            guard let top = buffer.under ?? image.roots.first(where: { $0.range.lowerBound <= hit.range.lowerBound
                && hit.range.upperBound <= $0.range.upperBound }) else { continue }
            let deepest = await UEFIAgentNodeData.deepest(covering: hit.range, in: buffer.space, under: top, in: tree)
            let chain = Self.chain(to: deepest, in: tree)
            let file = chain.last { $0.kind == .file }
            let section = chain.last { $0.kind == .section && $0.space == buffer.space }
            var members: [String: JSONValue] = ["form": .string(forms[hit.form].name + (forms[hit.form].bytes.count == 8 ? "64" : ""))]
            if let section {
                members["section"] = .string(section.id.description)
                members["section_offset"] = AgentHostTools.hex(hit.range.lowerBound - section.range.lowerBound)
            }
            if buffer.space == .file {
                members["file_start"] = AgentHostTools.hex(hit.range.lowerBound)
            } else {
                members["node_start"] = AgentHostTools.hex(hit.range.lowerBound)
                members["in_compressed"] = true
            }
            if deepest.id != (section ?? file)?.id { members["node"] = .string(deepest.id.description) }

            let owner = file ?? deepest
            let key = owner.id.description
            if let at = groupIndex[key] {
                groups[at].count += 1
                if groups[at].hits.count < Self.maxHitsPerFile { groups[at].hits.append(.object(members)) }
                continue
            }
            var entry: [String: JSONValue] = [
                "name": .string(UEFITreeDisplay.ownName(of: owner) ?? owner.name),
                "type": .string(UEFITreeDisplay.subtypeText(for: owner).isEmpty
                                ? UEFITreeDisplay.typeText(for: owner) : UEFITreeDisplay.subtypeText(for: owner)),
                "in_compressed": .bool(owner.space != .file)
            ]
            entry[file == nil ? "node" : "file"] = .string(key)
            if let guid = owner.guid { entry["guid"] = .string(guid.description) }
            groupIndex[key] = groups.count
            groups.append((key, entry, [.object(members)], 1))
        }
        envelope["total"] = .count(found.count)
        envelope["files"] = .count(groups.count)

        let fingerprint = AgentPage.fingerprint([host.contentVersion, guidText, scope,
                                                 forms.map { AgentBytes.hexText($0.bytes) }.joined(separator: "|")])
        let paging = try AgentPage(arguments, fingerprint: fingerprint)
        let items: [JSONValue] = groups.dropFirst(paging.first).prefix(limit).map { group in
            var entry = group.entry
            entry["hits"] = .array(group.hits)
            if group.count > group.hits.count { entry["hits_total"] = .count(group.count) }
            return .object(entry)
        }
        return .json(try paging.answer(envelope, key: "refs", items: items, total: groups.count,
                                       bound: arguments.answerBound))
    }

    /// The nodes from the top of the tree down to `node`, `node` last.
    private static func chain(to node: UEFINode, in tree: LazyUEFITree) -> [UEFINode] {
        (1...max(1, node.id.path.count)).compactMap { tree.node(NodeID(Array(node.id.path.prefix($0)))) }
    }

    /// The BIOS region's file range, when the image has a descriptor that
    /// names one.
    static func biosRegion(in image: UEFIImage) -> Range<UInt64>? {
        image.allNodes.first { node in
            node.space == .file && UEFITreeDisplay.typeText(for: node) == "Region"
                && UEFITreeDisplay.subtypeText(for: node) == "BIOS"
        }?.range
    }
}
