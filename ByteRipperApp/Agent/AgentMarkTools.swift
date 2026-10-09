import Cocoa
import AgentKit

/// `mark`, `unmark` and `marks`: an agent labelling bytes for the person and
/// saying how they hang together (`Design/AGENT_PLAN.md`, "Marks").
///
/// The marks live on the panes (`PaneViewModel.agentMarks`), so they are drawn
/// with the dump and go with the document. What is kept here is the counter
/// their ids come from — one for the whole app, so `m3` names one mark however
/// many documents are open.
@MainActor
final class AgentMarkTools {
    let desk: AgentDesk
    /// Told whenever the marks change, for the Agent window's list.
    var onChange: () -> Void = {}
    private var nextID = 1

    static let maxLabel = 80
    static let maxNote = 600

    init(desk: AgentDesk) {
        self.desk = desk
    }

    nonisolated func tools() -> [AgentTool] {
        [markTool, unmarkTool, marksTool]
    }

    // MARK: - What is marked

    struct Located {
        let mark: AgentMark
        let place: AgentDesk.Place
    }

    /// Every mark in every open document, documents in `documents` order and
    /// marks in the order they were made.
    func all() -> [Located] {
        desk.places().flatMap { place in place.pane.agentMarks.map { Located(mark: $0, place: place) } }
    }

    // MARK: - mark

    private nonisolated var markTool: AgentTool {
        AgentTool(
            name: "mark",
            title: "Mark bytes for the reader",
            description: """
                Marks a range of an open document with a short label and, optionally, a note — drawn over the \
                dump with a dashed outline in a colour of its own, the note shown when the person rests the \
                pointer on the bytes, and listed in the Agent window. Use it to show what bytes are while you \
                talk about them. `related_to` names marks this one is about (a pointer and its target, a \
                checksum and what it covers); the Agent window shows each pair. Does not move the view — \
                `reveal` does. Marks stay until removed with `unmark`, cleared by the person, or the document \
                closes.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "offset": AgentSchema.offset("The first byte."),
                "length": AgentSchema.offset("How many bytes, at least 1."),
                "label": AgentSchema.string("A few words: what the bytes are. At most \(Self.maxLabel) characters."),
                "note": AgentSchema.string("A sentence or two: why they matter. At most \(Self.maxNote) characters."),
                "related_to": AgentSchema.strings("Ids of marks this one is about, e.g. [\"m1\"].")
            ], required: ["offset", "length", "label"]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: false)
        ) { call in
            try await self.mark(call.arguments)
        }
    }

    private func mark(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments)
        // A mark is drawn on the dump; a file with no window has none to draw
        // it on, and would carry a mark nobody can see.
        _ = try place.onScreen()
        let offset = try arguments.offset("offset")
        let length = try arguments.offset("length")
        let label = try arguments.string("label").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (try arguments.optionalString("note") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let related = try arguments.strings("related_to")
        guard length > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
        guard !label.isEmpty else { throw AgentToolError("Argument `label` must say something.") }
        guard label.count <= Self.maxLabel else {
            throw AgentToolError("Argument `label`: at most \(Self.maxLabel) characters; put the rest in `note`.")
        }
        guard note.count <= Self.maxNote else { throw AgentToolError("Argument `note`: at most \(Self.maxNote) characters.") }
        let size = place.pane.fileSize
        guard offset < size, length <= size - offset else {
            throw AgentToolError("The range \(AgentHostTools.hexText(offset))+\(AgentHostTools.hexText(length)) "
                + "runs past the end of \(place.id), which is \(AgentHostTools.hexText(size)) bytes long.")
        }
        let known = Set(all().map(\.mark.id))
        if let missing = related.first(where: { !known.contains($0) }) {
            throw AgentToolError("No mark \(missing). Call `marks` for the ones there are.")
        }
        let mark = AgentMark(id: "m\(nextID)", range: offset..<(offset + length), label: label, note: note,
                             relatedTo: related)
        nextID += 1
        place.pane.setAgentMarks(place.pane.agentMarks + [mark])
        onChange()
        return .json(Self.describe(Located(mark: mark, place: place)))
    }

    // MARK: - unmark

    private nonisolated var unmarkTool: AgentTool {
        AgentTool(
            name: "unmark",
            title: "Remove marks",
            description: """
                Removes marks: the ones named in `ids`, or every mark in `document`, or — with `all` — every \
                mark in every document. Relations to a removed mark go with it.
                """,
            inputSchema: AgentSchema.object([
                "ids": AgentSchema.strings("The marks to remove, e.g. [\"m2\", \"m3\"]."),
                "document": AgentSchema.string("Remove every mark in this document."),
                "all": AgentSchema.boolean("Remove every mark in every document.")
            ]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: true)
        ) { call in
            try await self.unmark(call.arguments)
        }
    }

    private func unmark(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let ids = Set(try arguments.strings("ids"))
        let everything = try arguments.bool("all", default: false)
        let document = try arguments.optionalString("document")
        guard !ids.isEmpty || everything || document != nil else {
            throw AgentToolError("Name the marks in `ids`, a `document`, or pass `all: true`.")
        }
        let documentPane = try document.map { try resolve(AgentArguments(["document": .string($0)])).pane }
        let removed = remove { located in
            everything || ids.contains(located.mark.id) || located.place.pane === documentPane
        }
        if !ids.isEmpty, removed.count < ids.count {
            let gone = Set(removed)
            let unknown = ids.subtracting(gone).sorted()
            return .json(["removed": .array(removed.map { .string($0) }),
                          "not_found": .array(unknown.map { .string($0) })])
        }
        return .json(["removed": .array(removed.map { .string($0) })])
    }

    /// Removes the marks `doomed` picks, drops relations to them, and returns
    /// their ids. What the Agent window's buttons call as well.
    @discardableResult
    func remove(where doomed: (Located) -> Bool) -> [String] {
        let located = all()
        let removed = located.filter(doomed).map(\.mark.id)
        guard !removed.isEmpty else { return [] }
        let gone = Set(removed)
        var seen = Set<ObjectIdentifier>()
        for place in located.map(\.place) where seen.insert(ObjectIdentifier(place.pane)).inserted {
            let kept = place.pane.agentMarks.filter { !gone.contains($0.id) }.map { mark in
                AgentMark(id: mark.id, range: mark.range, label: mark.label, note: mark.note,
                          relatedTo: mark.relatedTo.filter { !gone.contains($0) })
            }
            place.pane.setAgentMarks(kept)
        }
        onChange()
        return removed
    }

    /// Brings the mark's document forward and selects its bytes — what a
    /// double-click on its row in the Agent window does. A step of the
    /// navigation history, like `reveal`.
    func show(_ id: String) {
        guard let located = all().first(where: { $0.mark.id == id }),
              let controller = located.place.controller else { return }
        let place = located.place
        desk.bringForward(place)
        controller.view.window?.makeKeyAndOrderFront(nil)
        controller.recordJump(in: place.pane)
        controller.revealForTool(located.mark.range, in: place.pane, select: true)
    }

    // MARK: - marks

    private nonisolated var marksTool: AgentTool {
        AgentTool(
            name: "marks",
            title: "List marks",
            description: "The marks in `document`, or in every open document: id, document, range, label, note, related marks.",
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("Only this document's marks. Default: every document's.")
            ])
        ) { call in
            try await self.list(call.arguments)
        }
    }

    private func list(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let document = try arguments.optionalString("document")
        let pane = try document.map { try resolve(AgentArguments(["document": .string($0)])).pane }
        let marks = all().filter { pane == nil || $0.place.pane === pane }
        return .json(["marks": .array(marks.map(Self.describe))])
    }

    // MARK: - Shapes

    static func describe(_ located: Located) -> JSONValue {
        var entry: [String: JSONValue] = [
            "id": .string(located.mark.id),
            "document": .string(located.place.id),
            "range": AgentHostTools.range(located.mark.range),
            "label": .string(located.mark.label)
        ]
        if !located.mark.note.isEmpty { entry["note"] = .string(located.mark.note) }
        if !located.mark.relatedTo.isEmpty { entry["related_to"] = .array(located.mark.relatedTo.map { .string($0) }) }
        return .object(entry)
    }

    private func resolve(_ arguments: AgentArguments) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: arguments.optionalString("document"))
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }
}
