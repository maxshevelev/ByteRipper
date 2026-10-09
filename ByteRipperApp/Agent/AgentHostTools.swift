import Cocoa
import AgentKit
import ByteRipperCore

/// The tools the app answers itself, as opposed to the ones a tool-module
/// contributes: what is open, where the reader is, the bytes, and moving the
/// view (`Design/AGENT_PLAN.md`, "The host's own tools").
///
/// Every name, description and answer here is read by a model and stays in
/// English without `L()` (`Design/LOCALIZATION.md`). Addresses and sizes are
/// answered as hex strings — `"0x7F3000"` — because that is how the dump, the
/// panels and every tool-module write them, and how a model hands them back.
@MainActor
final class AgentHostTools {
    let desk: AgentDesk

    /// The most a `read` returns.
    nonisolated static let maxRead = 4096

    init(desk: AgentDesk) {
        self.desk = desk
    }

    /// The tools, in the order `tools/list` gives them.
    nonisolated func tools() -> [AgentTool] {
        [documentsTool, focusTool, readTool, revealTool]
    }

    // MARK: - documents

    private nonisolated var documentsTool: AgentTool {
        AgentTool(
            name: "documents",
            title: "Open documents",
            description: """
                Lists every file open in ByteRipper: its id (pass it as `document` to the other tools), \
                name, path, size, whether it has unsaved edits, and where it is — pane A or B of a tab, \
                or a part opened over its parent file ("part", with the parent's id and the bytes of \
                the parent it came from). The document the reader is in comes first and is marked \
                `focused`. Ids last as long as the file stays open.
                """
        ) { _ in
            try await MainActor.run { [self] in try answer { documents() } }
        }
    }

    func documents() -> JSONValue {
        let focused = desk.focused()
        var tabs: [ObjectIdentifier: Int] = [:]
        let entries: [JSONValue] = desk.places().map { place in
            let pane = place.pane
            var entry: [String: JSONValue] = [
                "id": .string(place.id),
                "name": .string(pane.status.fileName),
                "size": Self.hex(pane.fileSize),
                "slot": .string(place.slot)
            ]
            if let controller = place.controller {
                let tab = tabs[ObjectIdentifier(controller)] ?? (tabs.count + 1)
                tabs[ObjectIdentifier(controller)] = tab
                entry["tab"] = .count(tab)
                entry["unsaved_edits"] = .bool(pane.status.isDirty)
                entry["read_only"] = .bool(pane.status.isReadOnly)
            }
            if !pane.isUntitled, let url = pane.document?.url { entry["path"] = .string(url.path) }
            if let origin = pane.origin, let parent = origin.parent?.document {
                entry["part_of"] = .string(desk.id(of: parent))
                entry["source"] = Self.range(origin.sourceRange)
            }
            if let focused, focused.pane === pane { entry["focused"] = true }
            return .object(entry)
        }
        return ["documents": .array(entries)]
    }

    // MARK: - focus

    private nonisolated var focusTool: AgentTool {
        AgentTool(
            name: "focus",
            title: "Where the reader is",
            description: """
                What the person at ByteRipper is looking at and pointing to: the document they are in, \
                the caret, the selection (null when there is only a caret), and the bytes on screen. \
                Call it when they say "this", "here" or "what I selected". In a comparison of two files \
                it also names the other one, which scrolls with this one.
                """
        ) { _ in
            try await MainActor.run { [self] in try answer { try focus() } }
        }
    }

    func focus() throws -> JSONValue {
        guard let place = desk.focused() else { throw AgentDeskError.nothingOpen }
        let pane = place.pane
        var answer: [String: JSONValue] = [
            "document": .string(place.id),
            "name": .string(pane.status.fileName),
            "caret": Self.hex(pane.caretOffset)
        ]
        let selection = pane.hexSelection()
        answer["selection"] = selection.isEmpty ? .null : Self.range(selection.start..<selection.end)
        let controller = try place.onScreen()
        if let view = controller.filePaneView(for: pane) {
            answer["on_screen"] = Self.range(view.visibleOffsets)
        }
        let model = controller.windowModel
        if controller.mode == .comparison, place.slot != "part" {
            let other = pane === model.pane1 ? model.pane2 : model.pane1
            if let document = other.document { answer["compared_with"] = .string(desk.id(of: document)) }
        }
        return .object(answer)
    }

    // MARK: - read

    private nonisolated var readTool: AgentTool {
        AgentTool(
            name: "read",
            title: "Read bytes",
            description: """
                Reads bytes of an open document as it is now, unsaved edits included. `format`: \
                "hex" (default) gives rows of 16 bytes with their address and text, as the dump shows them; \
                "ascii" a string with "." for bytes that are not printable; "utf16le" the bytes decoded as \
                UTF-16LE text; "u8", "u16", "u32", "u64" a list of unsigned integers in hex, \
                little-endian unless `endian` is "big". At most \(Self.maxRead) bytes; a range running past the \
                end of the file is cut there and says so.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "offset": AgentSchema.offset("Where to start, e.g. \"0x7F3000\"."),
                "length": AgentSchema.offset("How many bytes. Default 256, at most \(Self.maxRead)."),
                "format": AgentSchema.choice(["hex", "ascii", "utf16le", "u8", "u16", "u32", "u64"],
                                             "How to show them. Default \"hex\"."),
                "endian": AgentSchema.choice(["little", "big"], "For u16, u32 and u64. Default \"little\".")
            ], required: ["offset"])
        ) { call in
            try await MainActor.run { [self] in try answer { try read(call.arguments) } }
        }
    }

    func read(_ arguments: AgentArguments) throws -> JSONValue {
        let place = try desk.place(named: arguments.optionalString("document"))
        let offset = try arguments.offset("offset")
        let asked = try arguments.optionalOffset("length") ?? 256
        let format = try arguments.choice("format", from: ["hex", "ascii", "utf16le", "u8", "u16", "u32", "u64"],
                                          default: "hex")
        let bigEndian = try arguments.choice("endian", from: ["little", "big"], default: "little") == "big"
        guard asked > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
        guard asked <= UInt64(Self.maxRead) else {
            throw AgentToolError("Argument `length`: at most \(Self.maxRead) bytes in one read.")
        }
        let size = place.pane.fileSize
        guard offset < size else {
            throw AgentToolError("Offset \(Self.hexText(offset)) is past the end of \(place.id), "
                + "which is \(Self.hexText(size)) bytes long.")
        }
        let end = min(offset + asked, size)
        guard let storage = place.pane.byteStorage else { throw AgentDeskError.nothingOpen }
        let bytes = try storage.read(at: offset, length: Int(end - offset))

        var answer: [String: JSONValue] = [
            "document": .string(place.id),
            "offset": Self.hex(offset),
            "length": Self.hex(end - offset),
            "format": .string(format)
        ]
        if end - offset < asked { answer["cut_at_end_of_file"] = true }
        switch format {
        case "hex":
            answer["rows"] = .array(Self.hexRows(bytes, at: offset).map { .string($0) })
        case "ascii":
            answer["text"] = .string(Self.printable(bytes))
        case "utf16le":
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            answer["text"] = .string(String(decoding: units, as: UTF16.self))
        default:
            let width = ["u8": 1, "u16": 2, "u32": 4, "u64": 8][format] ?? 1
            answer["values"] = .array(Self.integers(bytes, width: width, bigEndian: bigEndian))
            if width > 1 { answer["endian"] = .string(bigEndian ? "big" : "little") }
        }
        return .object(answer)
    }

    // MARK: - reveal

    private nonisolated var revealTool: AgentTool {
        AgentTool(
            name: "reveal",
            title: "Show bytes to the reader",
            description: """
                Shows a place in a document to the person: brings its tab forward, scrolls the dump to \
                it and moves the caret there — selecting `length` bytes when `select` is true, which is \
                the default when a length is given. It is a step of the navigation history, so the \
                person's Back returns to where they were. Use it to point at what you are talking about.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "offset": AgentSchema.offset("The first byte to show."),
                "length": AgentSchema.offset("How many bytes the place is. Default 0: just the caret."),
                "select": AgentSchema.boolean("Select the bytes. Default: true when `length` is given.")
            ], required: ["offset"]),
            annotations: .view
        ) { call in
            try await MainActor.run { [self] in try answer { try reveal(call.arguments) } }
        }
    }

    func reveal(_ arguments: AgentArguments) throws -> JSONValue {
        let place = try desk.place(named: arguments.optionalString("document"))
        let offset = try arguments.offset("offset")
        let length = try arguments.optionalOffset("length") ?? 0
        let select = try arguments.bool("select", default: length > 0)
        let controller = try place.onScreen()
        let size = place.pane.fileSize
        guard offset < size || (offset == size && length == 0) else {
            throw AgentToolError("Offset \(Self.hexText(offset)) is past the end of \(place.id), "
                + "which is \(Self.hexText(size)) bytes long.")
        }
        let end = min(offset + length, size)
        desk.bringForward(place)
        // The place the reader is leaving goes into the history first, so
        // their Back undoes what the agent did.
        controller.recordJump(in: place.pane)
        controller.revealForTool(offset..<end, in: place.pane, select: select && end > offset)
        return [
            "document": .string(place.id),
            "shown": Self.range(offset..<end),
            "selected": .bool(select && end > offset)
        ]
    }

    // MARK: - Shapes

    /// Runs `body`, turning what the desk refuses into an answer the model
    /// can read.
    private func answer(_ body: () throws -> JSONValue) throws -> AgentAnswer {
        do {
            return .json(try body())
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }

    nonisolated static func hexText(_ value: UInt64) -> String { String(format: "0x%llX", value) }

    nonisolated static func hex(_ value: UInt64) -> JSONValue { .string(hexText(value)) }

    /// A half-open range, as the app keeps every range: `end` is the first
    /// byte after it.
    nonisolated static func range(_ range: Range<UInt64>) -> JSONValue {
        ["start": hex(range.lowerBound), "end": hex(range.upperBound), "length": hex(range.upperBound - range.lowerBound)]
    }

    nonisolated static func printable(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self)
    }

    /// Rows as the dump draws them — address, sixteen bytes, their text —
    /// counted from `offset` rather than from a row boundary, so the first row
    /// starts with the byte asked for.
    nonisolated static func hexRows(_ bytes: [UInt8], at offset: UInt64) -> [String] {
        stride(from: 0, to: bytes.count, by: 16).map { start in
            let row = Array(bytes[start..<min(start + 16, bytes.count)])
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            return String(format: "%08llX  ", offset + UInt64(start)) + padded + "  |" + printable(row) + "|"
        }
    }

    nonisolated static func integers(_ bytes: [UInt8], width: Int, bigEndian: Bool) -> [JSONValue] {
        stride(from: 0, through: bytes.count - width, by: width).map { start in
            var value: UInt64 = 0
            for index in 0..<width {
                let byte = UInt64(bytes[start + (bigEndian ? index : width - 1 - index)])
                value = value << 8 | byte
            }
            return .string(String(format: "0x%0*llX", width * 2, value))
        }
    }
}
