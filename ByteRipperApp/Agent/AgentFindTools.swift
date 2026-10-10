import AgentKit
import ByteRipperCore
import Foundation
import Localization
import PartCodec
import ToolModuleKit
import UEFIContentSource
import UEFIImage
import UEFITool

/// Searching a document's bytes, and opening a stretch of them as a part
/// (`Design/AGENT_PLAN.md`, search and extract).
///
/// The search is the find bar's own engine (`SearchEngine.matches`), so an
/// agent and a person find the same; it is given holes in a hex pattern and,
/// when asked, matches that overlap. A node inside a compressed section is
/// searched in what the tree decompressed it to. A part opens as the window
/// opens one — Open Zone's way for a range, the UEFI panel's Open for a node —
/// over its parent, linked back to it.
@MainActor
final class AgentFindTools {
    private let desk: AgentDesk
    /// Where a match is in the firmware, and the documents' bytes: the byte
    /// comparison's own helpers.
    private let diff: AgentDiffTools

    init(desk: AgentDesk, diff: AgentDiffTools) {
        self.desk = desk
        self.diff = diff
    }

    nonisolated func tools() -> [AgentTool] { [findTool, openPartTool] }

    /// The most bytes a preview takes on either side of a match.
    nonisolated static let maxContext = 64

    // MARK: - find_bytes

    private nonisolated var findTool: AgentTool {
        AgentTool(
            name: "find_bytes",
            title: "Find bytes or text",
            description: """
                Every place a text or a byte pattern occurs in a document, in address order, read as it is \
                now with unsaved edits — the find bar's own search. `text` is looked for as ASCII, as \
                UTF-16LE, or both (`encoding`, default both), any case with `ignore_case`; `hex` is bytes, \
                with `??` for a byte that may be anything ("24 ?? 4D 49"). The file is searched as it is \
                stored, so nothing inside a compressed section is found that way: give `node` (an id from \
                `uefi_tree`, `uefi_find` or `uefi_at`) to search that node's bytes, and for a node inside a \
                compressed section, what it decompressed to; a compressed section itself is searched in \
                what it decompresses to (`decompressed: true`). Matches in a decompressed buffer say \
                `node_start` and `node_end` inside it instead of file addresses, and `uefi_node_data` reads \
                around them — with part `decompressed` for a section's. \
                Each match: `start`, `end` (half-open), the `encoding` that matched, `where` it is — as \
                `diff` places a run: the top-level area and the deepest node that holds it — and, with \
                `context`, a `preview` of the bytes around it — none, and `redacted: true`, in an area the flash map names MSDM, Password or Key. `total` counts every match in the range. \
                Matches do not overlap unless `overlapping`: "AA" in "AAAA" is two, or three with it. \
                Pages: `limit` is a ceiling — a page also stops before the answer passes the size bound and \
                says `truncated: "size"`; pass `next` back as `after` until it is null. With `survey`, which \
                dumps of a folder hold a string.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "text": AgentSchema.string("A text to find. Give `text` or `hex`."),
                "hex": AgentSchema.string("Bytes to find, as hex pairs; `??` for any byte: \"24 ?? 4D 49\"."),
                "encoding": AgentSchema.choice(["ascii", "utf16le", "both"],
                                               "How `text` is stored. Default \"both\"."),
                "ignore_case": AgentSchema.boolean("Letters in either case — ASCII letters of `text`. Default false."),
                "overlapping": AgentSchema.boolean("Count matches that overlap one another. Default false."),
                "offset": AgentSchema.offset("Where the search starts — inside the node with `node`. Default 0x0."),
                "end": AgentSchema.offset("The first byte after the searched range. Default: the end."),
                "node": AgentSchema.string("Search only this UEFI node's bytes, decompressed where it is in a compressed section."),
                "context": AgentSchema.integer("Bytes before and after each match to show in `preview`. Default 0, at most 64."),
                "limit": AgentSchema.limit(default: 100, maximum: 1000),
                "after": AgentSchema.after
            ]),
            annotations: .readOnly
        ) { call in
            try await self.find(call.arguments)
        }
    }

    /// One pattern the search runs, and what its matches are called.
    private struct Wanted {
        var pattern: MaskedPattern
        var encoding: String
    }

    private func patterns(_ arguments: AgentArguments) throws -> [Wanted] {
        let text = try arguments.optionalString("text")
        let hex = try arguments.optionalString("hex")
        switch (text, hex) {
        case (nil, nil), (.some, .some):
            throw AgentToolError("Give `text` or `hex`, one of them.")
        case (_, .some(let hex)):
            do {
                return [Wanted(pattern: try MaskedPattern.hex(hex), encoding: "hex")]
            } catch {
                throw AgentToolError("`hex` is not a byte pattern. Give pairs of hex digits and `??` for any byte, "
                    + "e.g. \"24 ?? 4D 49\"; a pattern of `??` alone matches everywhere.")
            }
        case (.some(let text), _):
            guard !text.isEmpty else { throw AgentToolError("`text` is empty.") }
            let encoding = try arguments.choice("encoding", from: ["ascii", "utf16le", "both"], default: "both")
            let ignoreCase = try arguments.bool("ignore_case", default: false)
            var wanted: [Wanted] = []
            if encoding != "utf16le" {
                guard let ascii = text.data(using: .ascii) else {
                    throw AgentToolError("`text` is not ASCII; look for it with `encoding` \"utf16le\".")
                }
                wanted.append(Wanted(pattern: MaskedPattern(bytes: Array(ascii), folding: ignoreCase ? .asciiBytes : .exact),
                                     encoding: "ascii"))
            }
            if encoding != "ascii" {
                let units = Array(text.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
                wanted.append(Wanted(pattern: MaskedPattern(bytes: units,
                                                            folding: ignoreCase ? .utf16(littleEndian: true) : .exact),
                                     encoding: "utf16le"))
            }
            return wanted
        }
    }

    private func find(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try diff.resolve(arguments.optionalString("document"))
        let wanted = try patterns(arguments)
        let overlapping = try arguments.bool("overlapping", default: false)
        let context = Int(max(0, min(Int64(Self.maxContext), try arguments.has("context") ? arguments.integer("context") : 0)))
        let limit = try arguments.limit(default: 100, maximum: 1000)
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)

        // What is searched: the document, or one node's bytes — in the file,
        // or in the buffer its compressed section opened to.
        let storage: any ByteStorage
        let scope: Range<UInt64>
        var node: UEFIAgentNodeData.Bytes?
        var envelope: [String: JSONValue] = ["document": .string(place.id)]
        if let text = try arguments.optionalString("node") {
            // A compressed section is searched in what it decompresses to:
            // its own bytes are compressed, and nothing in them reads as text.
            let whole = try await UEFIAgentNodeData.bytes(host, node: text, part: .all)
            let decompressed = UEFIAgentNodeData.isCompressedSection(whole.node)
            let found = decompressed ? try await UEFIAgentNodeData.bytes(host, node: text, part: .decompressed) : whole
            node = found
            storage = found.isCompressed ? ReaderStorage(reader: found.reader) : try diff.snapshot(place)
            scope = found.range
            envelope["node"] = .string(found.node.id.description)
            envelope["node_size"] = AgentHostTools.hex(UInt64(found.range.count))
            envelope["in_compressed"] = .bool(found.isCompressed)
            if decompressed { envelope["decompressed"] = true }
            if let source = UEFIAgentNodeData.source(of: found.node, in: found.tree, including: decompressed) {
                envelope["source"] = source
            }
        } else {
            storage = try diff.snapshot(place)
            scope = 0..<storage.size
        }
        // `offset` and `end` count from the scope's start: the file's, or the
        // node's.
        let offset = try arguments.optionalOffset("offset") ?? 0
        let end = try arguments.optionalOffset("end") ?? UInt64(scope.count)
        guard offset < end, end <= UInt64(scope.count) else {
            throw AgentToolError("The range \(AgentHostTools.hexText(offset))–\(AgentHostTools.hexText(end)) is not inside "
                + (node == nil ? "\(place.id), which is " : "the node, which is ")
                + "\(AgentHostTools.hexText(UInt64(scope.count))) bytes long.")
        }
        let range = (scope.lowerBound + offset)..<(scope.lowerBound + end)
        envelope["range"] = AgentHostTools.range(offset..<end)
        if wanted.allSatisfy({ $0.pattern.count > range.count }) {
            throw AgentToolError("The pattern is longer than the range searched.")
        }

        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [host.contentVersion, JSONValue.object(arguments.values.filter { $0.key != "after" && $0.key != "limit" }).jsonText]))
        let first = paging.first
        let patterns = wanted.map(\.pattern)
        let (total, page) = try await Task.detached(priority: .userInitiated) {
            var total = 0
            var page: [(range: Range<UInt64>, pattern: Int)] = []
            try SearchEngine.matches(of: patterns, in: storage, range: range, overlapping: overlapping) { match, pattern in
                if total >= first, page.count < limit { page.append((match, pattern)) }
                total += 1
                return true
            }
            return (total, page)
        }.value
        envelope["total"] = .count(total)

        // Where each match is: the firmware's areas for the file's bytes, the
        // deepest node under the searched one for a buffer's.
        var places: [[JSONValue]] = []
        if let node, node.isCompressed {
            for match in page {
                let deepest = await UEFIAgentNodeData.deepest(covering: match.range, in: node.space,
                                                              under: node.node, in: node.tree)
                places.append([AgentDiffTools.placeJSON(ToolAgentPlace(
                    kind: "uefi", id: deepest.id.description,
                    name: UEFITreeDisplay.ownName(of: deepest) ?? deepest.name, range: nil))])
            }
        } else {
            places = await diff.locate(host, page.map(\.range)).map { $0.map(AgentDiffTools.placeJSON) }
        }

        var items: [JSONValue] = []
        for (match, places) in zip(page, places) {
            var members: [String: JSONValue] = [
                "encoding": .string(wanted[match.pattern].encoding),
                "where": .array(places)
            ]
            if let node, node.isCompressed {
                members["node_start"] = AgentHostTools.hex(match.range.lowerBound - node.range.lowerBound)
                members["node_end"] = AgentHostTools.hex(match.range.upperBound - node.range.lowerBound)
            } else {
                members["start"] = AgentHostTools.hex(match.range.lowerBound)
                members["end"] = AgentHostTools.hex(match.range.upperBound)
            }
            // An area the flash map names for a secret — MSDM, a password, a
            // key — gives its matches but not the bytes around them.
            let secret = places.contains { UEFIAgentRegions.isSecretName($0["name"]?.stringValue ?? "") }
            if secret, context > 0 { members["redacted"] = true }
            if context > 0, !secret {
                let around = max(scope.lowerBound, match.range.lowerBound &- UInt64(min(UInt64(context), match.range.lowerBound)))
                    ..< min(scope.upperBound, match.range.upperBound + UInt64(context))
                let bytes = (try? storage.read(at: around.lowerBound, length: around.count)) ?? []
                members["preview"] = [
                    "hex": .string(AgentBytes.hexText(bytes)),
                    "text": .string(wanted[match.pattern].encoding == "utf16le"
                                    ? AgentBytes.utf16le(bytes) : AgentBytes.printable(bytes)),
                    "before": .count(Int(match.range.lowerBound - around.lowerBound))
                ]
            }
            items.append(.object(members))
        }
        return .json(try paging.answer(envelope, key: "matches", items: items, total: total,
                                       bound: arguments.answerBound) { item in
            guard case .object(var members) = item, members["preview"] != nil else { return nil }
            members["preview"] = nil
            members["truncated"] = "item"
            return .object(members)
        })
    }

    // MARK: - open_part

    private nonisolated var openPartTool: AgentTool {
        AgentTool(
            name: "open_part",
            title: "Open a part",
            description: """
                Opens a stretch of a document as a part of its own, in a fragment panel over its parent's \
                tab — as Open Zone and the UEFI Structure panel's Open do — and answers its new `document` \
                id. This is the way to open a node, compressed or not, or any stretch you want to read or \
                edit: it keeps the person in the window they are in, with the parent showing behind the \
                panel. A new tab is for switching to another context or for comparing two parts; \
                `compare` opens one. The part's \
                addresses start at 0, so two blocks at different addresses of two dumps compare with `diff` \
                and `compare`; every tool that takes `document` works on it. Give `offset` and `length`, or \
                `node` (with `part` "all", the default, or "body") for a UEFI node's bytes — a node inside a \
                compressed section opens as what it decompressed to. The part stays linked: edits to it stay \
                in it until the person puts them back with Update in Parent, which for a decompressed node \
                compresses them again. The parent must be on screen (`show` puts a background dump there). \
                Closes with `close_dump` or by the person.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The parent's id from `documents`. Default: the focused one."),
                "offset": AgentSchema.offset("Where the part starts in the parent."),
                "length": AgentSchema.offset("How many bytes the part is."),
                "node": AgentSchema.string("Instead of `offset` and `length`: a UEFI node's id."),
                "part": AgentSchema.choice(["all", "body"], "With `node`: the whole node, or its body. Default \"all\"."),
                "name": AgentSchema.string("What the part is called. Default: the parent's name and what it is.")
            ]),
            annotations: .view
        ) { call in
            try await self.openPart(call.arguments)
        }
    }

    private func openPart(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try diff.resolve(arguments.optionalString("document"))
        let controller = try place.onScreen()
        let named = try arguments.optionalString("name")
        var answer: [String: JSONValue] = ["parent": .string(place.id)]
        let before = Set(controller.fragments.panelsLinked(to: place.pane))
        let opening: Task<Void, Never>?

        if let text = try arguments.optionalString("node") {
            guard !arguments.has("offset"), !arguments.has("length") else {
                throw AgentToolError("Give `node`, or `offset` and `length` — not both.")
            }
            let body = try arguments.choice("part", from: ["all", "body"], default: "all") == "body"
            let host = PaneToolHost(pane: place.pane, owner: controller, tools: nil)
            let found = try await UEFIAgentNodeData.bytes(host, node: text, part: body ? .body : .all)
            let image = found.tree.image()
            guard let open = UEFIPresenter.nodeOpen(for: found.node, in: image, body: body) else {
                throw AgentToolError("Node \(text) cannot be opened as a part: there is nothing there, "
                    + "or its compressed section cannot be traced back to the file.")
            }
            // As the UEFI panel's Open: the file's own bytes go back as they
            // are, or through the planner for a structure; a decompressed
            // node's go back through its section, compressed again.
            let codec: any PartCodec
            if open.space == .file, open.rebuild == nil {
                codec = CopyPartCodec()
            } else {
                codec = UEFIPartCodec(
                    target: open.rebuild ?? UEFIRebuild.Target(space: open.space, range: open.range),
                    compression: UEFIPresenter.compressionName(of: open.space, in: image),
                    readers: found.tree.spaceReaders)
            }
            opening = controller.openPart(named: named ?? open.partName(fileName: place.pane.status.fileName),
                                          from: place.pane, source: open.source, layout: open.layout, codec: codec)
            answer["node"] = .string(found.node.id.description)
            answer["in_compressed"] = .bool(open.space != .file)
            answer["source"] = AgentHostTools.range(open.source)
            answer["size"] = AgentHostTools.hex(UInt64(open.range.count))
        } else {
            guard arguments.has("offset"), arguments.has("length") else {
                throw AgentToolError("Give `offset` and `length`, or `node`.")
            }
            let offset = try arguments.offset("offset")
            let length = try arguments.offset("length")
            let size = place.pane.fileSize
            guard length > 0, offset < size, length <= size - offset else {
                throw AgentToolError("\(AgentHostTools.hexText(offset)) and \(AgentHostTools.hexText(length)) bytes "
                    + "do not fit in \(place.id), which is \(AgentHostTools.hexText(size)) bytes long.")
            }
            let source = offset..<(offset + length)
            let stem = (place.pane.status.fileName as NSString).deletingPathExtension
            let name = named ?? "\(stem)_\(AgentHostTools.hexText(offset))-\(AgentHostTools.hexText(source.upperBound))"
            // As Open Zone: a stretch that is a structure of the image goes
            // back through the rebuild planner, any other as it is.
            let image = place.pane.uefiState.tree?.image()
            let layout = image.map { UEFIRootLayout.forFileRange(source, in: $0) } ?? .image
            let codec: any PartCodec = image
                .flatMap { UEFIRebuild.target(forFileRange: source, in: $0) }
                .map { UEFIPartCodec(target: $0) }
                ?? CopyPartCodec()
            opening = controller.openPart(named: name, from: place.pane, source: source, layout: layout, codec: codec)
            answer["source"] = AgentHostTools.range(source)
            answer["size"] = AgentHostTools.hex(length)
        }
        // A part that decompresses opens when its bytes are ready.
        await opening?.value
        guard let opened = controller.fragments.panelsLinked(to: place.pane).first(where: { !before.contains($0) }),
              let pane = controller.fragments.pane(opened), let document = pane.document else {
            throw AgentToolError("The part could not be opened.")
        }
        answer["document"] = .string(desk.id(of: document))
        answer["name"] = .string(pane.status.fileName)
        return .json(.object(answer))
    }
}

/// A buffer the tree holds — what a compressed section decompressed to — as
/// the storage the search engine reads.
struct ReaderStorage: ByteStorage {
    let reader: ImageReader

    var size: UInt64 { UInt64(reader.count) }

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard offset < size, length > 0 else { return [] }
        return reader.bytes(at: offset, count: min(UInt64(length), size - offset)) ?? []
    }
}
