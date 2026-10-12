import Cocoa
import AgentKit
import ByteRipperCore
import LenovoDMI
import Localization
import UEFIContentSource
import UEFIImage
import UEFITool
import UEFIToolUI

/// `annotate`, `annotations` and `remove_annotations`: an agent's statements
/// about places in files (`Design/AGENT_PLAN.md`, "Annotations"; issue #37),
/// and the notes the person makes beside them.
///
/// One kind where there were two: a mark, drawn but gone with its document,
/// and a finding, kept but drawn nowhere. An annotation is kept here, for the
/// whole app and for as long as it runs, and a pane draws the ones for its
/// file whenever it shows it (`annotations(for:)`). Every tab's Notes panel
/// lists them (`NotesPanel`).
@MainActor
final class AgentAnnotationTools {
    let desk: AgentDesk
    /// Told whenever the annotations change.
    var onChange: () -> Void = {}
    /// The store the Notes panels read: the app's agent service's.
    static weak var current: AgentAnnotationTools?
    /// Opens a file in a tab of its own; the service hands `show`'s.
    var openInNewTab: (URL) -> Void = { _ in }
    /// The places a range of a document lies in, as `diff` names them — set
    /// by the service, which has the locators.
    var locate: (PaneToolHost, Range<UInt64>) async -> [JSONValue] = { _, _ in [] }
    private(set) var items: [AgentAnnotation] = []
    private var nextID = 1
    /// The agent's notes made while no Notes panel was in view, counted on
    /// the panel's pill until one is.
    private(set) var unseen: Set<String> = []
    /// Bumped by every change, so a pane knows its drawn list is stale.
    private(set) var generation = 0

    static let maxTitle = 80
    static let maxNote = 600

    init(desk: AgentDesk) {
        self.desk = desk
    }

    nonisolated func tools() -> [AgentTool] {
        [annotateTool, annotationsTool, removeTool]
    }

    // MARK: - What there is

    /// Every annotation, in the order they were made — without those on a
    /// document that has closed.
    func all() -> [AgentAnnotation] {
        items.removeAll { annotation in
            if case .document(let held) = annotation.file { return held.document == nil }
            return false
        }
        return items
    }

    /// The annotations `pane` draws, at its own addresses: those of its file,
    /// and — for a part that keeps its parent's addresses all the way to a
    /// file — those of that file over the stretch the part is.
    func annotations(for pane: PaneViewModel) -> [AgentAnnotation] {
        guard let document = pane.document else { return [] }
        var drawn = all().filter { annotation in
            if case .document(let held) = annotation.file { return held.holds(document) }
            return false
        }
        // A body decompressed from a file, opened from the file's own tab,
        // shows the annotations found in it at its own addresses.
        if let origin = pane.origin, !origin.codec.keepsOffsets, let parent = origin.parent, parent.origin == nil,
           !parent.isUntitled, let root = parent.document,
           let codec = origin.codec as? UEFIPartCodec, codec.target.space != .file {
            let start = codec.target.range?.lowerBound ?? 0
            let end = start + pane.fileSize
            for annotation in all() {
                guard case .disk(_, let identity) = annotation.file, identity == root.identity,
                      let decoded = annotation.decoded, decoded.space == codec.target.space,
                      decoded.source == origin.sourceRange,
                      decoded.range.lowerBound >= start, decoded.range.upperBound <= end else { continue }
                drawn.append(annotation.at((decoded.range.lowerBound - start)..<(decoded.range.upperBound - start)))
            }
            return drawn
        }
        // Out through the parts to a file on disk, adding up where each one
        // starts in the next.
        var shift: UInt64 = 0
        var window: Range<UInt64> = 0..<pane.fileSize
        var current = pane
        while let origin = current.origin {
            guard origin.codec.keepsOffsets, let parent = origin.parent else { return drawn }
            shift += origin.sourceRange.lowerBound
            window = (window.lowerBound + origin.sourceRange.lowerBound)..<(window.upperBound + origin.sourceRange.lowerBound)
            current = parent
        }
        guard !current.isUntitled, let root = current.document else { return drawn }
        for annotation in all() {
            guard case .disk(_, let identity) = annotation.file, identity == root.identity,
                  let range = annotation.range, range.lowerBound >= window.lowerBound,
                  range.upperBound <= window.upperBound else { continue }
            drawn.append(annotation.at((range.lowerBound - shift)..<(range.upperBound - shift)))
        }
        return drawn
    }

    /// Tells every pane on screen its annotations may have changed, and
    /// every tab's Notes panel.
    private func changed() {
        generation += 1
        PaneViewModel.annotationGeneration += 1
        for place in desk.places() { place.pane.annotationsChanged() }
        onChange()
        for tab in desk.tabs { tab.notesChanged() }
    }

    /// The notes have been looked at: the count on the pill goes.
    func markSeen() {
        guard !unseen.isEmpty else { return }
        unseen = []
        for tab in desk.tabs { tab.notesChanged() }
    }

    /// Adds `annotation` and tells everyone. An agent's note made while no
    /// Notes panel is in view waits on the pill as unseen.
    private func add(_ annotation: AgentAnnotation) {
        items.append(annotation)
        if annotation.author == .agent, !desk.tabs.contains(where: \.notesAreInView) {
            unseen.insert(annotation.id)
        }
        changed()
    }

    // MARK: - The person's notes

    /// The person's edit of note `id`: its title and note, the place kept.
    // help: window.notes.edit
    func update(_ id: String, title: String, note: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        items[index] = items[index].with(title: title, note: note)
        changed()
    }

    /// A note the person makes on `range` of `pane` — the dump's right-click
    /// ▸ Add Annotation…: placed the way an agent's on the same bytes is, in a part
    /// through to its file.
    // help: menu.offset.note
    @discardableResult
    func addNote(title: String, note: String, on range: Range<UInt64>,
                 of pane: PaneViewModel) async throws -> String {
        guard let place = desk.places().first(where: { $0.pane === pane }) else {
            throw AgentToolError("The document is not open.")
        }
        let answer = try await annotate(AgentArguments([
            "title": .string(title), "note": .string(note), "document": .string(place.id),
            "offset": .string(AgentHostTools.hexText(range.lowerBound)),
            "length": .string(AgentHostTools.hexText(UInt64(range.count)))
        ]), author: .person)
        guard case .json(let json) = answer, let id = json["id"]?.stringValue else { return "" }
        return id
    }

    // MARK: - annotate

    private nonisolated var annotateTool: AgentTool {
        AgentTool(
            name: "annotate",
            title: "Annotate a place",
            description: """
                Puts an annotation on a place in a file: a short `title` (what the bytes are), an optional \
                `note` (why they matter, or what you found there), and the place — a `document` or a file \
                `path`, with `offset` and `length`, or a UEFI `node` — whole, or with `offset` and `length` counted \
                from the node's first byte: a `find_bytes` match with `node` is `node` and `node_offset`. It is listed in the Annotations panel of every tab and \
                drawn over the bytes — a dashed outline, the note when the person rests the pointer on them — \
                whenever the file is on screen, now or after it is opened later; it is kept when the file \
                closes. Use it both to show what bytes are while you explain them and to leave a result for \
                the person to check — with `survey`, one on each file that matches. Whenever it is about \
                bytes you have already annotated — a pointer and its target, a size and the stretch it \
                names, a checksum and what it covers — annotate the other end first and pass its id in \
                `related_to`: the person sees the relation and cannot otherwise. `reveal: true` also brings \
                the place on screen, opening the file in a tab if it is not. In a part — a fragment panel — \
                it goes to the file the part came out of, at the same bytes where the part keeps the file's \
                addresses, otherwise at the bytes the part was decoded from; `from_part` says where it was in \
                the part. A place in bytes that are not the file's own — what a compressed section decompresses \
                to, a LENV block decoded, given as a node there or as a part of them — is kept there: the \
                annotation answers `decoded` (the section or block, the range in its bytes, the `codecs`), the \
                person's double-click opens those bytes in a fragment panel at the place, and the card shows the \
                codecs as badges, so the title need not name them. Annotations go with `remove_annotations` or when the person clears them.
                """,
            inputSchema: AgentSchema.object([
                "title": AgentSchema.string("A few words: what the bytes are. At most \(Self.maxTitle) characters."),
                "note": AgentSchema.string("A sentence or two: why they matter, or what was found. At most \(Self.maxNote) characters."),
                "document": AgentSchema.string("The document it is in. Default: the focused one."),
                "path": AgentSchema.string("Or the file it is in, by path, open or not."),
                "offset": AgentSchema.offset("The first byte: in the document, or with `node` from the node's first byte."),
                "length": AgentSchema.offset("How many bytes. Default 1."),
                "node": AgentSchema.string("Or the UEFI node it is about, e.g. \"0.2.5\" — inside a compressed section too."),
                "related_to": AgentSchema.strings(
                    "Ids of annotations this one is about, e.g. [\"a1\"] for the target of a pointer. Give it "
                    + "whenever there is such an annotation."),
                "reveal": AgentSchema.boolean("Also bring the place on screen. Default false.")
            ], required: ["title"]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: false)
        ) { call in
            try await self.annotate(call.arguments, author: .agent)
        }
    }

    private func annotate(_ arguments: AgentArguments, author: AgentAnnotation.Author) async throws -> AgentAnswer {
        let title = try arguments.string("title").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (try arguments.optionalString("note") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let related = try arguments.strings("related_to")
        guard !title.isEmpty else { throw AgentToolError("Argument `title` must say something.") }
        guard title.count <= Self.maxTitle else {
            throw AgentToolError("Argument `title`: at most \(Self.maxTitle) characters; put the rest in `note`.")
        }
        guard note.count <= Self.maxNote else { throw AgentToolError("Argument `note`: at most \(Self.maxNote) characters.") }
        let known = Set(all().map(\.id))
        if let missing = related.first(where: { !known.contains($0) }) {
            throw AgentToolError("No annotation \(missing). Call `annotations` for the ones there are.")
        }
        let offset = try arguments.optionalOffset("offset")
        let length = try arguments.optionalOffset("length") ?? 1
        guard length > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
        var node = try arguments.optionalString("node")
        // Without `node`, `offset` is in the document; with it, in the node.
        var range = node == nil ? offset.map { $0..<($0 + length) } : nil
        let within = node == nil ? nil : offset.map { $0..<($0 + length) }
        if node == nil, arguments.has("length"), offset == nil {
            throw AgentToolError("Give `offset` with `length`.")
        }
        var decoded: AgentAnnotation.Decoded?

        let file: AgentAnnotation.File
        var fromPart: JSONValue?
        var size: UInt64?
        if let path = try arguments.optionalString("path") {
            guard !arguments.has("document") else { throw AgentToolError("Give `document` or `path`, not both.") }
            let url = try AgentDumpTools.fileURL(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let bytes = attributes[.size] as? NSNumber else {
                throw AgentToolError("There is no file at \(url.path).")
            }
            size = bytes.uint64Value
            file = .disk(url, FileIdentity(url: url))
            // A node of a file that is open somewhere is placed by its tree.
            if let id = node, let place = desk.places().first(where: { place in
                !place.pane.isUntitled && place.pane.origin == nil && place.pane.document?.identity == FileIdentity(url: url)
            }) {
                (range, decoded) = try await nodePlace(id, within: within, in: place)
            } else if node != nil, within != nil {
                throw AgentToolError("A node's bytes are placed by the file's tree: open \(url.lastPathComponent) "
                    + "first, or give the node alone.")
            }
        } else {
            let place = try resolve(arguments.optionalString("document"))
            if let id = node {
                (range, decoded) = try await nodePlace(id, within: within, in: place)
                if place.pane.origin != nil {
                    guard decoded == nil else {
                        throw AgentToolError("Node \(id) is in a compressed section of \(place.named). Annotate it on "
                            + "the document that part was opened from, or open that section as a part of its own.")
                    }
                    // A part's node is named by the part's own tree: it goes
                    // as its bytes, which mean something in the file.
                    node = nil
                }
            }
            var pane = place.pane
            size = pane.fileSize
            if let range, range.upperBound > pane.fileSize {
                throw AgentToolError("The range \(AgentHostTools.hexText(range.lowerBound))–\(AgentHostTools.hexText(range.upperBound)) "
                    + "runs past the end of \(place.named), which is \(AgentHostTools.hexText(pane.fileSize)) bytes long.")
            }
            if pane.origin != nil {
                var answer: [String: JSONValue] = ["document": .string(place.id)]
                if let range { answer["range"] = AgentHostTools.range(range) }
                // A part decoded from the file — a decompressed body, a LENV
                // block decoded — keeps the place in its own bytes, where the
                // annotation is shown.
                if let range, let found = await partPlace(range, of: place) {
                    decoded = found
                    answer["decoded"] = .bool(true)
                }
                // Out through every part to the file: byte for byte where the
                // codec keeps the addresses, otherwise the bytes the part was
                // decoded from.
                var exact = true
                var mapped = range
                var reachesFile = true
                while let origin = pane.origin {
                    guard let parent = origin.parent else { reachesFile = false; break }
                    let source = origin.sourceRange
                    if let inside = mapped, origin.codec.keepsOffsets, exact {
                        mapped = (source.lowerBound + inside.lowerBound)..<(source.lowerBound + inside.upperBound)
                    } else {
                        mapped = source
                        exact = false
                    }
                    pane = parent
                }
                if reachesFile, !pane.isUntitled, pane.document != nil {
                    // Bytes that are no bytes of the file are not drawn over
                    // the whole section they came out of.
                    range = exact || decoded == nil ? mapped : nil
                    answer["exact"] = .bool(exact)
                    fromPart = .object(answer)
                } else {
                    // A part of something never saved stays on the part.
                    pane = place.pane
                    decoded = nil
                }
            }
            guard let document = pane.document else { throw AgentToolError("\(place.named) holds no bytes.") }
            file = pane.isUntitled ? .document(WeakDocument(document)) : .disk(document.url, document.identity)
            size = pane.fileSize
        }
        if let range, let size, range.upperBound > size {
            throw AgentToolError("The range \(AgentHostTools.hexText(range.lowerBound))–\(AgentHostTools.hexText(range.upperBound)) "
                + "runs past the end of the file, which is \(AgentHostTools.hexText(size)) bytes long.")
        }
        guard range != nil || node != nil || decoded != nil || file.url != nil else {
            throw AgentToolError("Give the place: `offset`, or `node`.")
        }
        // Bytes of the file inside a LENV block stored encoded are read
        // decoded, however the place was given: by a node, or — as a
        // survey's answers give it — by its addresses.
        if decoded == nil, let range, case .disk(_, let identity) = file,
           let place = desk.places().first(where: { place in
               !place.pane.isUntitled && place.pane.origin == nil && place.pane.document?.identity == identity
           }) {
            decoded = await encodedPlace(range, in: place)
        }

        let site = await self.site(of: file, range: range, node: node, decoded: decoded)
        let annotation = AgentAnnotation(id: "a\(nextID)", file: file, range: range, node: node, title: title,
                                         note: note, decoded: decoded, relatedTo: related, site: site,
                                         author: author)
        nextID += 1
        add(annotation)
        if try arguments.bool("reveal", default: false) { show(annotation.id) }
        guard case .object(var members) = describe(annotation) else { return .json(describe(annotation)) }
        if let fromPart { members["from_part"] = fromPart }
        return .json(.object(members))
    }

    /// What the place is called on screen, read off the file's tree while the
    /// file is open somewhere: the node given — or the deepest node holding
    /// the place, in the file or in the decompressed bytes it is in — after
    /// its parent, as the UEFI Structure panel's Contents search results name
    /// a match. None for a file the tree reads as nothing but padding: the
    /// card says the addresses instead.
    private func site(of file: AgentAnnotation.File, range: Range<UInt64>?, node: String?,
                      decoded: AgentAnnotation.Decoded?) async -> AgentAnnotation.Site? {
        guard case .disk(_, let identity) = file, let place = desk.places().first(where: { place in
            place.pane.origin == nil && !place.pane.isUntitled && place.pane.document?.identity == identity
        }) else { return nil }
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        guard let tree = try? await UEFIAgentQueries.readyTree(host),
              tree.rootNodes.contains(where: { $0.kind != .padding }) else { return nil }
        var id: NodeID?
        if let node, let found = try? await UEFIAgentNodeData.bytes(host, node: node, part: .all) {
            id = found.node.id
        } else if let decoded, let space = decoded.space {
            let holder = (try? UEFIAgentQueries.nodeID(decoded.holder)).flatMap(tree.node)
            await UEFIContentSearch.openEverything(under: holder, in: tree)
            id = tree.image().allNodes
                .filter { $0.space == space && $0.range.lowerBound <= decoded.range.lowerBound
                    && decoded.range.upperBound <= $0.range.upperBound }
                .max { $0.id.path.count < $1.id.path.count }?.id
        } else if let range {
            let places = await locate(host, range)
            id = places.last(where: { $0["kind"] == "uefi" })?["id"]?.stringValue
                .flatMap { try? UEFIAgentQueries.nodeID($0) }
        }
        guard let id else { return nil }
        let catalogue = await UEFIToolModule.agentCatalogue()
        guard let label = UEFITreeDisplay.nameAfterParent(of: id, in: tree, catalogue: catalogue, image: tree.image(),
                                                          in: Localization.appLanguage),
              let agentLabel = UEFITreeDisplay.nameAfterParent(of: id, in: tree, catalogue: catalogue,
                                                               image: tree.image(), in: .english)
        else { return nil }
        return AgentAnnotation.Site(label: label, agentLabel: agentLabel, node: id.description)
    }

    /// Where node `id` of `place` is — or the stretch `within` of its
    /// bytes, from its first: in the file, or, for a node inside a
    /// compressed section, in what the section decompresses to. A node of a
    /// LENV block that is stored encoded is in the file and also decoded.
    private func nodePlace(_ id: String, within: Range<UInt64>?,
                           in place: AgentDesk.Place) async throws -> (Range<UInt64>?, AgentAnnotation.Decoded?) {
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let found = try await UEFIAgentNodeData.bytes(host, node: id, part: .all)
        var range = found.range
        if let within {
            guard within.upperBound <= UInt64(found.range.count) else {
                throw AgentToolError("\(AgentHostTools.hexText(within.lowerBound))–\(AgentHostTools.hexText(within.upperBound)) "
                    + "runs past the end of node \(id), which is \(AgentHostTools.hexText(UInt64(found.range.count))) bytes long.")
            }
            range = (found.range.lowerBound + within.lowerBound)..<(found.range.lowerBound + within.upperBound)
        }
        let image = found.tree.image()
        guard found.space == .file else {
            guard let holder = UEFIPresenter.holder(of: found.space, in: image),
                  let source = UEFIPresenter.fileSource(of: holder, in: image) else {
                throw AgentToolError("Node \(id) has no place in the file to annotate.")
            }
            return (nil, AgentAnnotation.Decoded(
                holder: holder.id.description, source: source, space: found.space, range: range,
                codecs: UEFIPresenter.codecTexts(of: found.space, in: image)))
        }
        guard let reader = found.tree.spaceReaders.reader(for: .file),
              let block = UEFILenovoDMIDetail.decodableBlock(for: found.node, image: image, reader: reader),
              let badge = LenovoDMIBlockCodec(block: block.block).badge,
              LenovoDMIBlockCodec(block: block.block).encodes else { return (range, nil) }
        let source = block.block.range
        return (range, AgentAnnotation.Decoded(
            holder: id, source: source, space: nil,
            range: (range.lowerBound - source.lowerBound)..<(range.upperBound - source.lowerBound),
            codecs: [badge.text], xorKey: block.block.xorKey))
    }

    /// The place `range` of the file is in a LENV block stored encoded: the
    /// block decoded, at the deepest node holding the range.
    private func encodedPlace(_ range: Range<UInt64>, in place: AgentDesk.Place) async -> AgentAnnotation.Decoded? {
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        guard let tree = try? await UEFIAgentQueries.readyTree(host),
              let reader = tree.spaceReaders.reader(for: .file) else { return nil }
        let chain = await withCheckedContinuation { continuation in
            tree.materialize(containing: range.lowerBound) { continuation.resume(returning: $0) }
        }
        let image = tree.image()
        let holding = chain.filter { $0.space == .file && $0.range.lowerBound <= range.lowerBound
            && range.upperBound <= $0.range.upperBound }
        guard let deepest = holding.last,
              let found = holding.lazy.reversed().compactMap({
                  UEFILenovoDMIDetail.decodableBlock(for: $0, image: image, reader: reader)
              }).first else { return nil }
        let codec = LenovoDMIBlockCodec(block: found.block)
        let source = found.block.range
        guard codec.encodes, let badge = codec.badge,
              source.lowerBound <= range.lowerBound, range.upperBound <= source.upperBound else { return nil }
        return AgentAnnotation.Decoded(
            holder: deepest.id.description, source: source, space: nil,
            range: (range.lowerBound - source.lowerBound)..<(range.upperBound - source.lowerBound),
            codecs: [badge.text], xorKey: found.block.xorKey)
    }

    /// The place `range` of part `place` is in its own bytes, when the part
    /// is bytes of a file decoded — a compressed section's body, a LENV
    /// block — opened from the file's own tab: what reopens it there.
    private func partPlace(_ range: Range<UInt64>, of place: AgentDesk.Place) async -> AgentAnnotation.Decoded? {
        guard let origin = place.pane.origin, let parent = origin.parent, parent.origin == nil,
              !parent.isUntitled else { return nil }
        let holderPlace = desk.places().first { $0.pane === parent }
        let host = PaneToolHost(pane: parent, owner: holderPlace?.controller ?? place.controller, tools: nil)
        guard let tree = try? await UEFIAgentQueries.readyTree(host) else { return nil }
        let image = tree.image()
        if let codec = origin.codec as? UEFIPartCodec, codec.target.space != .file {
            guard let holder = UEFIPresenter.holder(of: codec.target.space, in: image) else { return nil }
            let start = codec.target.range?.lowerBound ?? 0
            return AgentAnnotation.Decoded(
                holder: holder.id.description, source: origin.sourceRange, space: codec.target.space,
                range: (start + range.lowerBound)..<(start + range.upperBound),
                codecs: UEFIPresenter.codecTexts(of: codec.target.space, in: image))
        }
        guard let codec = origin.codec as? LenovoDMIBlockCodec, codec.encodes, let badge = codec.badge else { return nil }
        let source = origin.sourceRange
        let chain = await withCheckedContinuation { continuation in
            tree.materialize(containing: source.lowerBound) { continuation.resume(returning: $0) }
        }
        guard let block = chain.last(where: { $0.fileRange == source }) else { return nil }
        return AgentAnnotation.Decoded(holder: block.id.description, source: source, space: nil,
                                       range: range, codecs: [badge.text], xorKey: codec.key)
    }

    // MARK: - remove_annotations

    private nonisolated var removeTool: AgentTool {
        AgentTool(
            name: "remove_annotations",
            title: "Remove annotations",
            description: """
                Removes annotations: the ones named in `ids`, or every one on a `document` or a file `path`, \
                or — with `all` — every one. Relations to a removed annotation go with it.
                """,
            inputSchema: AgentSchema.object([
                "ids": AgentSchema.strings("The annotations to remove, e.g. [\"a2\", \"a3\"]."),
                "document": AgentSchema.string("Remove every annotation on this document's file."),
                "path": AgentSchema.string("Remove every annotation on this file."),
                "all": AgentSchema.boolean("Remove every annotation.")
            ]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: true)
        ) { call in
            try await self.removeTool(call.arguments)
        }
    }

    private func removeTool(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let ids = Set(try arguments.strings("ids"))
        let everything = try arguments.bool("all", default: false)
        let file = try fileFilter(arguments)
        guard !ids.isEmpty || everything || file != nil else {
            throw AgentToolError("Name the annotations in `ids`, a `document` or a `path`, or pass `all: true`.")
        }
        let removed = remove { annotation in
            everything || ids.contains(annotation.id) || (file?(annotation) ?? false)
        }
        if !ids.isEmpty, removed.count < ids.count {
            let unknown = ids.subtracting(removed).sorted()
            return .json(["removed": .array(removed.map { .string($0) }),
                          "not_found": .array(unknown.map { .string($0) })])
        }
        return .json(["removed": .array(removed.map { .string($0) })])
    }

    /// Removes the annotations `doomed` picks, drops relations to them, and
    /// returns their ids. What the Annotations panel calls as well.
    @discardableResult
    func remove(where doomed: (AgentAnnotation) -> Bool) -> [String] {
        let removed = all().filter(doomed).map(\.id)
        guard !removed.isEmpty else { return [] }
        let gone = Set(removed)
        items = items.filter { !gone.contains($0.id) }.map { $0.dropping(gone) }
        unseen.subtract(gone)
        changed()
        return removed
    }

    /// Brings the annotation's file forward — the tab that has it, or a new
    /// one — and goes to its place: what a double-click on its card in the
    /// Annotations panel does, and `reveal`. A step of the navigation history.
    ///
    /// A place the UEFI tree knows is gone to the way the UEFI Structure
    /// panel's Contents search results go to a match: in the file's own bytes
    /// as a click on a row does — the tree open to the node, the bytes
    /// selected; in decompressed or decoded bytes as a double-click does — a
    /// fragment panel of them, the place selected and its tree open to it.
    func show(_ id: String) {
        guard let annotation = all().first(where: { $0.id == id }) else { return }
        var place = self.place(of: annotation)
        if place == nil, let url = annotation.file.url {
            openInNewTab(url)
            place = self.place(of: annotation)
        }
        guard let place, let controller = place.controller else { return }
        desk.bringForward(place)
        controller.view.window?.makeKeyAndOrderFront(nil)
        if let range = annotation.range, range.upperBound > place.pane.fileSize { return }
        controller.recordJump(in: place.pane)
        // A file just opened has its tree still to read, and whether the
        // place is a node — and how to open it — is the tree's to say: the
        // place is gone to once it is read.
        let needsTree = annotation.site != nil || annotation.decoded != nil
        if needsTree, place.pane.uefiState.tree?.isReady != true {
            let host = PaneToolHost(pane: place.pane, owner: controller, tools: nil)
            Task { @MainActor [weak self] in
                _ = try? await UEFIAgentQueries.readyTree(host)
                self?.go(to: annotation, at: place, in: controller)
            }
            return
        }
        go(to: annotation, at: place, in: controller)
    }

    /// Goes to the annotation's place in `place`, its tree read where it has one.
    private func go(to annotation: AgentAnnotation, at place: AgentDesk.Place, in controller: MainViewController) {
        // A file the tree reads as nothing but padding is no firmware: its
        // place is shown in the dump alone.
        let isFirmware = place.pane.uefiState.tree.map { tree in
            tree.isReady && tree.image().allNodes.contains { $0.kind != .padding }
        } ?? false
        if isFirmware || annotation.decoded != nil, let match = Self.match(of: annotation) {
            let tools = controller.tools(reading: place.pane)
            if tools.activeIdentifier != ToolRegistry.uefiStructure {
                tools.activate(ToolRegistry.uefiStructure, animated: false)
            }
            if let session = tools.session as? UEFIToolSession {
                if annotation.decoded != nil {
                    session.openContentMatch(match)
                } else {
                    // The place is in the tab's own panes: a fragment panel
                    // up over them is folded, or the selection lands behind it.
                    if controller.fragments.expanded != nil { controller.fragments.collapse() }
                    session.goTo(match)
                }
                return
            }
        }
        guard let range = annotation.range else { return }
        if controller.fragments.expanded != nil { controller.fragments.collapse() }
        controller.revealForTool(range, in: place.pane, select: !range.isEmpty)
    }

    /// The annotation's place as a Contents search match, for UEFI Structure
    /// to go to; nil for a place the tree does not name.
    private static func match(of annotation: AgentAnnotation) -> UEFIContentSearch.Match? {
        let node = (annotation.node ?? annotation.site?.node).flatMap { try? UEFIAgentQueries.nodeID($0) }
        guard let decoded = annotation.decoded else {
            guard let node, let range = annotation.range else { return nil }
            return UEFIContentSearch.Match(space: .file, range: range, node: node)
        }
        let holder = try? UEFIAgentQueries.nodeID(decoded.holder)
        if let space = decoded.space {
            return UEFIContentSearch.Match(space: space, range: decoded.range, node: node, section: holder)
        }
        guard let range = annotation.range, let key = decoded.xorKey else { return nil }
        return UEFIContentSearch.Match(space: .file, range: range, decodedXORKey: key, node: holder)
    }

    /// The pane on screen that shows the annotation's file as a whole.
    func place(of annotation: AgentAnnotation) -> AgentDesk.Place? {
        desk.places().first { place in
            guard place.isOnScreen, place.pane.origin == nil, let document = place.pane.document else { return false }
            switch annotation.file {
            case .disk(_, let identity): return !place.pane.isUntitled && document.identity == identity
            case .document(let held): return held.holds(document)
            }
        }
    }

    // MARK: - annotations

    private nonisolated var annotationsTool: AgentTool {
        AgentTool(
            name: "annotations",
            title: "List annotations",
            description: """
                The annotations made so far, oldest first — on every file, or on a `document` or a file \
                `path`: id, the file's `path` (and its `document` id while it is open), `range` and/or `node`, \
                `decoded` for a place in decompressed or decoded bytes, `title`, `note`, `related_to`, and `author: "person"` for one the person made by hand. Pages: `limit` is a ceiling — a page also stops before the \
                answer passes the size bound and then says `truncated: "size"`; pass `next` back as `after` \
                until it is null. A page asked for after the list changed is refused.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("Only the annotations on this document's file."),
                "path": AgentSchema.string("Only the annotations on this file."),
                "limit": AgentSchema.limit(default: 50, maximum: 200),
                "after": AgentSchema.after
            ])
        ) { call in
            try await self.list(call.arguments)
        }
    }

    private func list(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let filter = try fileFilter(arguments)
        let chosen = all().filter { filter?($0) ?? true }
        let limit = try arguments.limit(default: 50, maximum: 200)
        let described = chosen.map(describe)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([described.map(\.jsonText)]),
                                   changed: "The annotations changed since that page; ask again without `after`.")
        return .json(try paging.answer(["total": .count(chosen.count)], key: "annotations",
                                       items: Array(described.dropFirst(paging.first).prefix(limit)),
                                       total: chosen.count, bound: arguments.answerBound))
    }

    /// The annotations on the file a `document` or a `path` names.
    private func fileFilter(_ arguments: AgentArguments) throws -> ((AgentAnnotation) -> Bool)? {
        if let path = try arguments.optionalString("path") {
            let identity = FileIdentity(url: try AgentDumpTools.fileURL(path))
            return { annotation in
                if case .disk(_, let held) = annotation.file { return held == identity }
                return false
            }
        }
        guard let id = try arguments.optionalString("document") else { return nil }
        guard let document = try resolve(id).pane.document else { return { _ in false } }
        let identity = document.identity
        return { annotation in
            switch annotation.file {
            case .disk(_, let held): return held == identity
            case .document(let held): return held.holds(document)
            }
        }
    }

    // MARK: - Shapes

    func describe(_ annotation: AgentAnnotation) -> JSONValue {
        var entry: [String: JSONValue] = ["id": .string(annotation.id), "title": .string(annotation.title)]
        if let url = annotation.file.url { entry["path"] = .string(url.path) }
        if let place = place(of: annotation) { entry["document"] = .string(place.id) }
        if let range = annotation.range { entry["range"] = AgentHostTools.range(range) }
        if let node = annotation.node { entry["node"] = .string(node) }
        if let decoded = annotation.decoded {
            entry["decoded"] = ["node": .string(decoded.holder), "range": AgentHostTools.range(decoded.range),
                                "codecs": .array(decoded.codecs.map { .string($0.text(in: .english)) })]
        }
        if let site = annotation.site { entry["label"] = .string(site.agentLabel) }
        if !annotation.note.isEmpty { entry["note"] = .string(annotation.note) }
        if annotation.author == .person { entry["author"] = "person" }
        if !annotation.relatedTo.isEmpty { entry["related_to"] = .array(annotation.relatedTo.map { .string($0) }) }
        return .object(entry)
    }

    /// The annotations' titles by id, for naming the ends of a relation.
    func titles() -> [String: String] {
        Dictionary(all().map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    private func resolve(_ id: String?) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: id)
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }
}
