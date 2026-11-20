import AgentKit
import ByteRipperCore
import Foundation
import HexText
import LenovoDMI
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
/// agent and a person find the same; it is given holes in a hex pattern, and
/// matches overlap as they do in the find bar unless `overlapping` is false.
/// With a node it is the UEFI panel's Contents search instead: the node and
/// everything decompressed or decoded under it (`UEFIContentSearch`). A part
/// opens as the window opens one — Open Zone's way for a range, the UEFI panel's Open for a node —
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

    // MARK: - find_bytes

    /// `find_bytes` is `UEFIAgentFind`'s, the analysis server's too: here it
    /// runs over the open panel's bytes, unsaved edits included.
    private nonisolated var findTool: AgentTool {
        AgentTool(
            name: "find_bytes",
            title: "Find bytes or text",
            description: UEFIAgentFind.description(
                contents: "the document's bytes as they are stored, with unsaved edits", opensParts: true,
                extra: "With `survey`, which dumps of a folder hold a string."),
            inputSchema: AgentSchema.object(UEFIAgentFind.properties(
                document: "The document's id from `documents`. Default: the focused one.")),
            annotations: .readOnly
        ) { call in
            try await self.find(call.arguments)
        }
    }

    private func find(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try diff.resolve(arguments.optionalString("document"))
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        return .json(try await UEFIAgentFind.run(arguments, host: host,
                                                 document: .init(id: place.id, named: place.named),
                                                 locators: diff.locators))
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
                `node` (with `part`) for a UEFI node: "all" (the default) or "body" for its bytes — a node \
                inside a compressed section opens as what it decompressed to — "decompressed" for what a \
                compressed section decompresses to, "decoded" for a Lenovo LENV block (or one of its \
                entries) decoded, its XOR encoding removed. The part stays linked: edits to it stay \
                in it until the person puts them back with Update in Parent, which for a decompressed node \
                compresses them again. The answer says which `part` opened, and a LENV block opened \
                without "decoded" comes with a `hint`. Asking again for a part that is already open \
                raises its panel and answers `reused: true` with its `document` — not a second copy. \
                `tool_panel` names the tool panel the part shows, null when none: `open_panel` with the \
                part's `document` opens one on it. From then on the UEFI tools name the same node in the \
                parent and the part (`counterpart`, `decoded_in`), and a call that names the parent while the \
                focus is on the part answers with a `focus_note`. \
                The new part takes the focus, so a call that leaves out `document` now goes to the part, \
                and a node id belongs to the document it was listed on, the parent: give `document` \
                (the `parent` of the answer) when you go on with that node. A part has its own tree, \
                with its own ids: the parent's 0.3.4.1.2.5 is 0.0.5 in the decoded block. The parent must be on screen (`show` puts a background dump there). \
                Closes with `close_dump` or by the person.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The parent's id from `documents`. Default: the focused one."),
                "offset": AgentSchema.offset("Where the part starts in the parent."),
                "length": AgentSchema.offset("How many bytes the part is."),
                "node": AgentSchema.string("Instead of `offset` and `length`: a UEFI node's id."),
                "part": AgentSchema.choice(["all", "body", "decompressed", "decoded"],
                    "With `node`: the whole node, its body, what a compressed section decompresses to, or a LENV block decoded. Default \"all\"."),
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
            let which = try arguments.choice("part", from: ["all", "body", "decompressed", "decoded"], default: "all")
            let body = which == "body"
            let host = PaneToolHost(pane: place.pane, owner: controller, tools: nil)
            let found = try await UEFIAgentNodeData.bytes(
                host, node: text, part: which == "decompressed" ? .decompressed : body ? .body : .all)
            let image = found.tree.image()
            if which == "decompressed" || which == "decoded" {
                let name = which == "decompressed"
                    ? try Self.decompressedPart(found, in: image)
                    : try Self.decodedPart(found, in: image)
                answer["node"] = .string(found.node.id.description)
                answer["part"] = .string(which)
                answer["in_compressed"] = .bool(which == "decompressed")
                answer["source"] = AgentHostTools.range(name.source)
                answer["size"] = .string(name.size.hexNumber)
                if let reused = reusedPart(controller, place, source: name.source, layout: name.layout,
                                           codec: name.codec, defaultName: name.name, acceptsEarlierName: false) {
                    return reuse(reused, controller: controller, answer: answer)
                }
                opening = controller.openPart(named: named ?? name.name, from: place.pane, source: name.source,
                                              layout: name.layout, codec: name.codec)
                return try await finishOpening(opening, controller: controller, place: place, before: before, answer: answer)
            }
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
            let defaultName = open.partName
            answer["node"] = .string(found.node.id.description)
            answer["part"] = .string(which)
            answer["in_compressed"] = .bool(open.space != .file)
            answer["source"] = AgentHostTools.range(open.source)
            answer["size"] = .string(open.range.count.hexNumber)
            // A LENV block opened as it is reads as XOR noise, and nothing in
            // the answer said there was a decoded way to open it.
            if let reader = found.tree.spaceReaders.reader(for: .file),
               UEFILenovoDMIDetail.decodableBlock(for: found.node, image: image, reader: reader) != nil {
                answer["hint"] = .string("A Lenovo LENV block: its bytes are XOR-encoded as they are in the file. "
                    + "part: \"decoded\" opens it decoded.")
            }
            if let reused = reusedPart(controller, place, source: open.source, layout: open.layout,
                                       codec: codec, defaultName: defaultName, acceptsEarlierName: false) {
                return reuse(reused, controller: controller, answer: answer)
            }
            opening = controller.openPart(named: named ?? defaultName,
                                          from: place.pane, source: open.source, layout: open.layout, codec: codec)
        } else {
            guard arguments.has("offset"), arguments.has("length") else {
                throw AgentToolError("Give `offset` and `length`, or `node`.")
            }
            let offset = try arguments.offset("offset")
            let length = try arguments.offset("length")
            let size = place.pane.fileSize
            guard length > 0, offset < size, length <= size - offset else {
                throw AgentToolError("\(offset.hexNumber) and \(length.hexNumber) bytes "
                    + "do not fit in \(place.named), which is \(size.hexNumber) bytes long.")
            }
            let source = offset..<(offset + length)
            let defaultName = source.hexExtent
            let name = named ?? defaultName
            // As Open Zone: a stretch that is a structure of the image goes
            // back through the rebuild planner, any other as it is.
            let image = place.pane.uefiState.tree?.image()
            let layout = image.map { UEFIRootLayout.forFileRange(source, in: $0) } ?? .image
            let codec: any PartCodec = image
                .flatMap { UEFIRebuild.target(forFileRange: source, in: $0) }
                .map { UEFIPartCodec(target: $0) }
                ?? CopyPartCodec()
            answer["source"] = AgentHostTools.range(source)
            answer["size"] = .string(length.hexNumber)
            if let reused = reusedPart(controller, place, source: source, layout: layout,
                                       codec: codec, defaultName: defaultName, acceptsEarlierName: true) {
                return reuse(reused, controller: controller, answer: answer)
            }
            opening = controller.openPart(named: name, from: place.pane, source: source, layout: layout, codec: codec)
        }
        return try await finishOpening(opening, controller: controller, place: place, before: before, answer: answer)
    }

    /// The panel of `place` that already holds this part, if one does: the same
    /// bytes of the parent, read the same way, under the name it would be given.
    /// A second call for the same part raises that panel instead of opening a
    /// copy beside it — a copy the reader has to close, and edits that would
    /// then be in one of two places.
    private func reusedPart(_ controller: MainViewController, _ place: AgentDesk.Place, source: Range<UInt64>,
                            layout: UEFIRootLayout, codec: any PartCodec, defaultName: String,
                            acceptsEarlierName: Bool)
        -> (id: FragmentDock.PanelID, pane: PaneViewModel)? {
        for id in controller.fragments.panelsLinked(to: place.pane) {
            guard let pane = controller.fragments.pane(id), let origin = pane.origin,
                  origin.sourceRange == source, origin.layout == layout,
                  type(of: origin.codec) == type(of: codec),
                  origin.partName == defaultName
                    || (acceptsEarlierName && origin.partName == Self.earlierDefaultName(source))
            else { continue }
            return (id, pane)
        }
        return nil
    }

    /// The name a part opened by address got before builds wrote a range
    /// first to last: `0x100-0x140`, the end exclusive. A workspace may still
    /// hold a part under it, and asking for the same bytes by address again
    /// finds that panel rather than opening a second one over them. Only by
    /// address: a node asked for is never taken for a part opened by address.
    private nonisolated static func earlierDefaultName(_ source: Range<UInt64>) -> String {
        "\(source.lowerBound.hexNumber)-\(source.upperBound.hexNumber)"
    }

    private func reuse(_ part: (id: FragmentDock.PanelID, pane: PaneViewModel), controller: MainViewController,
                       answer: [String: JSONValue]) -> AgentAnswer {
        var answer = answer
        controller.fragments.expand(part.id)
        answer["reused"] = true
        answer["document"] = part.pane.document.map { .string(desk.id(of: $0)) } ?? .null
        answer["name"] = .string(part.pane.status.fileName)
        answer.merge(toolPanel(of: part.id, controller: controller, document: answer["document"])) { _, new in new }
        return .json(.object(answer))
    }

    /// Which tool panel the part's panel shows, and, when none, how to open
    /// one on the part — not on the parent, whose tree numbers the same nodes
    /// otherwise and whose bytes may be the encoded ones.
    private func toolPanel(of id: FragmentDock.PanelID, controller: MainViewController,
                           document: JSONValue?) -> [String: JSONValue] {
        let active = controller.fragments.surface(id)?.tools.activeIdentifier
        guard let active else {
            let named = document?.stringValue.map { "\"\($0)\"" } ?? "the part's id"
            return ["tool_panel": .null,
                    "next": .string("No tool panel on the part yet: `open_panel` with `document` \(named) opens one on it "
                        + "(module \"uefi-structure\" for its tree), and `uefi_select` then chooses the part's own nodes.")]
        }
        return ["tool_panel": .string(String(active.split(separator: ".").last ?? Substring(active)))]
    }

    /// What a part is opened as, before it is: its name, the bytes of the
    /// parent it is linked to, how the panel lays it out and the codec that
    /// decodes it and puts it back.
    private struct PartPlan {
        var name: String
        var source: Range<UInt64>
        var layout: UEFIRootLayout
        var codec: any PartCodec
        var size: UInt64
    }

    /// As the UEFI panel's Open Decompressed Body: the buffer a compressed
    /// section opens to, linked to the section and compressed again on the way
    /// back.
    private static func decompressedPart(_ found: UEFIAgentNodeData.Bytes, in image: UEFIImage) throws -> PartPlan {
        guard let body = UEFIPresenter.decompressedBody(for: found.node, in: image),
              let source = UEFIPresenter.fileSource(of: found.node, in: image) else {
            throw AgentToolError("Node \(found.node.id) is not a compressed section; part \"decompressed\" is a compressed section's.")
        }
        let codec = UEFIPartCodec(
            target: UEFIRebuild.Target(space: body.space),
            compression: UEFIPresenter.compressionName(of: body.space, in: image),
            readers: found.tree.spaceReaders)
        return PartPlan(name: body.partName, source: source, layout: body.layout,
                        codec: codec, size: UInt64(found.reader.count))
    }

    /// As Open Decoded Block: a LENV block, or the one an entry is in, with its
    /// XOR encoding removed; Update in Parent encodes it again and writes the
    /// checksum.
    private static func decodedPart(_ found: UEFIAgentNodeData.Bytes, in image: UEFIImage) throws -> PartPlan {
        guard let reader = found.tree.spaceReaders.reader(for: .file),
              let block = UEFILenovoDMIDetail.decodableBlock(for: found.node, image: image, reader: reader) else {
            throw AgentToolError("Node \(found.node.id) is not a LENV block, or in one, that has anything to decode.")
        }
        // The panel's name is the block's, as the panel the person opens on
        // the same block is named: the pill's badge says it is decoded.
        return PartPlan(name: block.name.text,
                        source: block.block.range, layout: .image,
                        codec: LenovoDMIBlockCodec(block: block.block), size: block.block.range.upperBound - block.block.range.lowerBound)
    }

    private func finishOpening(_ opening: Task<Void, Never>?, controller: MainViewController,
                               place: AgentDesk.Place, before: Set<FragmentDock.PanelID>,
                               answer: [String: JSONValue]) async throws -> AgentAnswer {
        var answer = answer
        // A part that decompresses opens when its bytes are ready.
        await opening?.value
        guard let opened = controller.fragments.panelsLinked(to: place.pane).first(where: { !before.contains($0) }),
              let pane = controller.fragments.pane(opened), let document = pane.document else {
            throw AgentToolError("The part could not be opened.")
        }
        answer["document"] = .string(desk.id(of: document))
        answer["name"] = .string(pane.status.fileName)
        answer.merge(toolPanel(of: opened, controller: controller, document: answer["document"])) { _, new in new }
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
