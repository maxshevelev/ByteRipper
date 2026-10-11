import Cocoa
import AgentKit
import ByteRipperCore
import UEFITool

/// `annotate`, `annotations` and `remove_annotations`: an agent's statements
/// about places in files (`Design/AGENT_PLAN.md`, "Annotations"; issue #37).
///
/// One kind where there were two: a mark, drawn but gone with its document,
/// and a finding, kept but drawn nowhere. An annotation is kept here, for the
/// whole app and for as long as it runs, and a pane draws the ones for its
/// file whenever it shows it (`annotations(for:)`).
@MainActor
final class AgentAnnotationTools {
    let desk: AgentDesk
    /// Told whenever the annotations change, for the Agent window's list.
    var onChange: () -> Void = {}
    /// Opens a file in a tab of its own; the service hands `show`'s.
    var openInNewTab: (URL) -> Void = { _ in }
    /// The places a range of a document lies in, as `diff` names them — set
    /// by the service, which has the locators.
    var locate: (PaneToolHost, Range<UInt64>) async -> [JSONValue] = { _, _ in [] }
    private(set) var items: [AgentAnnotation] = []
    private var nextID = 1
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

    /// Tells every pane on screen its annotations may have changed.
    private func changed() {
        generation += 1
        PaneViewModel.annotationGeneration += 1
        for place in desk.places() { place.pane.annotationsChanged() }
        onChange()
    }

    // MARK: - annotate

    private nonisolated var annotateTool: AgentTool {
        AgentTool(
            name: "annotate",
            title: "Annotate a place",
            description: """
                Puts an annotation on a place in a file: a short `title` (what the bytes are), an optional \
                `note` (why they matter, or what you found there), and the place — a `document` or a file \
                `path`, with `offset` and `length` or a UEFI `node`. It is listed in the Agent window and \
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
                the part. Annotations go with `remove_annotations` or when the person clears them.
                """,
            inputSchema: AgentSchema.object([
                "title": AgentSchema.string("A few words: what the bytes are. At most \(Self.maxTitle) characters."),
                "note": AgentSchema.string("A sentence or two: why they matter, or what was found. At most \(Self.maxNote) characters."),
                "document": AgentSchema.string("The document it is in. Default: the focused one."),
                "path": AgentSchema.string("Or the file it is in, by path, open or not."),
                "offset": AgentSchema.offset("The first byte."),
                "length": AgentSchema.offset("How many bytes. Default 1."),
                "node": AgentSchema.string("Or the UEFI node it is about, e.g. \"0.2.5\"."),
                "related_to": AgentSchema.strings(
                    "Ids of annotations this one is about, e.g. [\"a1\"] for the target of a pointer. Give it "
                    + "whenever there is such an annotation."),
                "reveal": AgentSchema.boolean("Also bring the place on screen. Default false.")
            ], required: ["title"]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: false)
        ) { call in
            try await self.annotate(call.arguments)
        }
    }

    private func annotate(_ arguments: AgentArguments) async throws -> AgentAnswer {
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
        var range: Range<UInt64>?
        if let offset = try arguments.optionalOffset("offset") {
            let length = try arguments.optionalOffset("length") ?? 1
            guard length > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
            range = offset..<(offset + length)
        }
        var node = try arguments.optionalString("node")
        guard range == nil || node == nil else { throw AgentToolError("Give `offset` or `node`, not both.") }

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
                range = try await nodeRange(id, in: place)
            }
        } else {
            let place = try resolve(arguments.optionalString("document"))
            if let id = node {
                range = try await nodeRange(id, in: place)
                // A part's node is named by the part's own tree: it goes as
                // its bytes, which mean something in the file.
                if place.pane.origin != nil { node = nil }
            }
            var pane = place.pane
            size = pane.fileSize
            if let range, range.upperBound > pane.fileSize {
                throw AgentToolError("The range \(AgentHostTools.hexText(range.lowerBound))–\(AgentHostTools.hexText(range.upperBound)) "
                    + "runs past the end of \(place.id), which is \(AgentHostTools.hexText(pane.fileSize)) bytes long.")
            }
            if pane.origin != nil {
                var answer: [String: JSONValue] = ["document": .string(place.id)]
                if let range { answer["range"] = AgentHostTools.range(range) }
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
                    range = mapped
                    answer["exact"] = .bool(exact)
                    fromPart = .object(answer)
                } else {
                    // A part of something never saved stays on the part.
                    pane = place.pane
                }
            }
            guard let document = pane.document else { throw AgentToolError("\(place.id) holds no bytes.") }
            file = pane.isUntitled ? .document(WeakDocument(document)) : .disk(document.url, document.identity)
            size = pane.fileSize
        }
        if let range, let size, range.upperBound > size {
            throw AgentToolError("The range \(AgentHostTools.hexText(range.lowerBound))–\(AgentHostTools.hexText(range.upperBound)) "
                + "runs past the end of the file, which is \(AgentHostTools.hexText(size)) bytes long.")
        }
        guard range != nil || node != nil || file.url != nil else {
            throw AgentToolError("Give the place: `offset`, or `node`.")
        }

        let site = await self.site(of: file, range: range, node: node)
        let annotation = AgentAnnotation(id: "a\(nextID)", file: file, range: range, node: node, title: title,
                                         note: note, relatedTo: related, site: site)
        nextID += 1
        items.append(annotation)
        changed()
        if try arguments.bool("reveal", default: false) { show(annotation.id) }
        guard case .object(var members) = describe(annotation) else { return .json(describe(annotation)) }
        if let fromPart { members["from_part"] = fromPart }
        return .json(.object(members))
    }

    /// What the place is called on screen, read off the file's tree while the
    /// file is open somewhere: the node given, or the deepest node holding
    /// the range.
    private func site(of file: AgentAnnotation.File, range: Range<UInt64>?, node: String?) async -> AgentAnnotation.Site? {
        guard case .disk(_, let identity) = file, let place = desk.places().first(where: { place in
            place.pane.origin == nil && !place.pane.isUntitled && place.pane.document?.identity == identity
        }) else { return nil }
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        if let node, let found = try? await UEFIAgentNodeData.bytes(host, node: node, part: .all) {
            return AgentAnnotation.Site(label: UEFIAgentQueries.label(of: found.node, in: found.tree), node: node)
        }
        guard let range else { return nil }
        let places = await locate(host, range)
        guard let deepest = places.last(where: { $0["kind"] == "uefi" }),
              case .string(let id)? = deepest["id"] else { return nil }
        let label = deepest["label"]?.stringValue ?? deepest["name"]?.stringValue ?? id
        return AgentAnnotation.Site(label: label, node: id)
    }

    /// Where a UEFI node of `place` is in its bytes.
    private func nodeRange(_ id: String, in place: AgentDesk.Place) async throws -> Range<UInt64> {
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let found = try await UEFIAgentNodeData.bytes(host, node: id, part: .all)
        guard let range = found.fileRange ?? UEFIPresenter.fileSource(of: found.node, in: found.tree.image()) else {
            throw AgentToolError("Node \(id) has no place in the file to annotate.")
        }
        return range
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
    /// returns their ids. What the Agent window's buttons call as well.
    @discardableResult
    func remove(where doomed: (AgentAnnotation) -> Bool) -> [String] {
        let removed = all().filter(doomed).map(\.id)
        guard !removed.isEmpty else { return [] }
        let gone = Set(removed)
        items = items.filter { !gone.contains($0.id) }.map { $0.dropping(gone) }
        changed()
        return removed
    }

    /// Brings the annotation's file forward — the tab that has it, or a new
    /// one — and selects its place: what a double-click on its row in the
    /// Agent window does, and `reveal`. A step of the navigation history.
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
        guard let range = annotation.range, range.lowerBound <= place.pane.fileSize else { return }
        controller.recordJump(in: place.pane)
        let end = min(range.upperBound, place.pane.fileSize)
        controller.revealForTool(range.lowerBound..<end, in: place.pane, select: end > range.lowerBound)
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
                `title`, `note`, `related_to`. Pages: `limit` is a ceiling — a page also stops before the \
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
        if let site = annotation.site { entry["label"] = .string(site.label) }
        if !annotation.note.isEmpty { entry["note"] = .string(annotation.note) }
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
