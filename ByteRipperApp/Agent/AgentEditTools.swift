import Cocoa
import AgentKit
import Localization
import ToolModuleKit

/// The one door an agent's change to a file goes through
/// (`Design/AGENT_PLAN.md`, "Edits"): `write`, and every edit a tool-module
/// works out (`ToolAgentEdit`), applied here and nowhere else.
///
/// Only with the person's edit switch on, only to a document in a tab — a
/// file opened by path is read, never changed — and never to one opened
/// read-only. Each change is one undo step named after what the agent said
/// it is, shows red like a hand edit, and is brought on screen, so the person
/// sees what changed and takes it back with ⌘Z. Nothing here saves.
@MainActor
final class AgentEditTools {
    let desk: AgentDesk
    /// The edit switch, read at each call.
    var isAllowed: () -> Bool = { false }
    /// Where a range lies in the firmware, as `diff` names it — set by the
    /// service, which has the locators.
    var locate: (PaneToolHost, Range<UInt64>) async -> [JSONValue] = { _, _ in [] }

    /// The most bytes one `write` carries: a patch, not an image.
    static let writeLimit = 0x1_0000

    init(desk: AgentDesk) {
        self.desk = desk
    }

    nonisolated func tools() -> [AgentTool] { [writeTool, copyTool] }

    // MARK: - write

    private nonisolated var writeTool: AgentTool {
        AgentTool(
            name: "write",
            title: "Write bytes",
            description: """
                Overwrites bytes in a document open in a tab, as one step of its undo named by `label` — \
                write the label in the person's language, it is what their Edit menu offers to undo. The \
                bytes replace as many as they are, never inserting or deleting: a write past the end of \
                the file is refused. The written bytes show red until the person saves, and the dump \
                scrolls to them. `expect` makes the write conditional: the bytes there now must be these, \
                or nothing is written and the answer says what is there. Needs the person's permission \
                — Settings ▸ Agent, "Let agents edit open files"; without it the write is refused. Never \
                saves; checksums are not updated — use a module's fix, such as `uefi_fix_checksum`.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The document's id from `documents`. Default: the focused one."),
                "offset": AgentSchema.offset("Where the bytes go, e.g. \"0x7F3000\"."),
                "bytes": AgentSchema.string("The bytes as hex, e.g. \"DE AD BE EF\" or \"deadbeef\"; at most 64 KiB."),
                "label": AgentSchema.string("What the change is, for the undo step: \"Enable the debug option\"."),
                "expect": AgentSchema.string("The bytes that must be at `offset` now, as hex. Optional.")
            ], required: ["offset", "bytes", "label"]),
            annotations: .edit
        ) { call in
            try await self.write(call.arguments)
        }
    }

    private func write(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try resolve(arguments.optionalString("document"))
        try checkEditable(place)
        let offset = try arguments.offset("offset")
        let bytes = try Self.hexBytes(arguments.string("bytes"), name: "bytes")
        let label = try arguments.string("label").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw AgentToolError("`label` is empty; say what the change is.") }
        guard !bytes.isEmpty else { throw AgentToolError("`bytes` is empty.") }
        guard bytes.count <= Self.writeLimit else {
            throw AgentToolError("\(bytes.count) bytes is more than one write carries (\(Self.writeLimit)).")
        }
        if arguments.has("expect") {
            let expected = try Self.hexBytes(arguments.string("expect"), name: "expect")
            let end = offset &+ UInt64(expected.count)
            guard end <= place.pane.fileSize else {
                throw AgentToolError("`expect` runs past the end of \(place.id).")
            }
            let actual = try place.pane.byteStorage?.read(at: offset, length: expected.count) ?? []
            guard actual == expected else {
                throw AgentToolError("Nothing written: the bytes at \(AgentHostTools.hexText(offset)) are "
                    + "\(Self.hexText(actual)), not \(Self.hexText(expected)).")
            }
        }
        let undoName = Self.inAppLanguage { L("Agent: %1$@", label) }
        return .json(try apply(ToolTransaction(name: undoName, offset: offset, bytes: bytes), to: place))
    }

    // MARK: - copy_to_other_pane

    private nonisolated var copyTool: AgentTool {
        AgentTool(
            name: "copy_to_other_pane",
            title: "Copy bytes to the other pane",
            description: """
                Copies a range of one of a tab's two files over the same addresses in the other — what \
                Edit ▸ Copy to Other Pane (⌥⌘C) does with the selection. The bytes go from file to file \
                inside ByteRipper and never through you, so there is no size limit: a whole region or \
                volume is one call. Overwrites only: a range past the end of the other file is refused, \
                never grown. One undo step in the receiving file, named by `label`; the copied bytes show \
                red until the person saves, and its pane scrolls to them. The answer says how many bytes \
                actually changed and where in the firmware the range lies. Needs the person's permission \
                — Settings ▸ Agent, "Let agents edit open files". Never saves; checksums are not updated.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string(
                    "The file to copy from: one of a tab's two files, by its id from `documents`. "
                    + "Default: the focused one."),
                "offset": AgentSchema.offset("The first byte, e.g. \"0x7F3000\"."),
                "length": AgentSchema.offset("How many bytes, at least 1."),
                "label": AgentSchema.string(
                    "What the copy is, for the undo step, in the person's language. Default: Copy to Other Pane.")
            ], required: ["offset", "length"]),
            annotations: .edit
        ) { call in
            try await self.copyToOtherPane(call.arguments)
        }
    }

    private func copyToOtherPane(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let source = try resolve(arguments.optionalString("document"))
        let controller = try source.onScreen()
        let model = controller.windowModel
        guard source.slot == "A" || source.slot == "B" else {
            throw AgentToolError("\(source.id) is a part over a file, not one of a tab's two files; it has no "
                + "pane beside it. Use `write`, or copy in the tab's own files.")
        }
        let other = source.pane === model.pane1 ? model.pane2 : model.pane1
        guard let otherDocument = other.document,
              let destination = desk.places().first(where: { $0.pane === other && $0.pane.document === otherDocument })
        else {
            throw AgentToolError("\(source.id) is alone in its tab; there is no other pane to copy into. "
                + "`compare` puts a second file beside it.")
        }
        let offset = try arguments.offset("offset")
        let length = try arguments.offset("length")
        guard length > 0 else { throw AgentToolError("Argument `length` must be at least 1.") }
        guard offset < source.pane.fileSize, length <= source.pane.fileSize - offset else {
            throw AgentToolError("The range \(AgentHostTools.hexText(offset))+\(AgentHostTools.hexText(length)) "
                + "runs past the end of \(source.id), which is \(AgentHostTools.hexText(source.pane.fileSize)) bytes long.")
        }
        guard length <= UInt64(Int.max) else { throw AgentToolError("The range is too long.") }
        try checkEditable(destination)
        let range = offset..<(offset + length)
        guard range.upperBound <= destination.pane.fileSize else {
            throw AgentToolError("The range ends at \(AgentHostTools.hexText(range.upperBound)), past the end of "
                + "\(destination.id), which is \(AgentHostTools.hexText(destination.pane.fileSize)) bytes long. "
                + "Nothing was copied; a copy overwrites, it does not grow the file.")
        }
        let bytes = try source.pane.byteStorage?.read(at: offset, length: Int(length)) ?? []
        let there = try destination.pane.byteStorage?.read(at: offset, length: Int(length)) ?? []
        guard bytes.count == Int(length), there.count == Int(length) else {
            throw AgentToolError("Could not read \(AgentHostTools.hexText(length)) bytes at \(AgentHostTools.hexText(offset)).")
        }
        let changed = zip(bytes, there).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        let label = (try arguments.optionalString("label") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let undoName = Self.inAppLanguage {
            L("Agent: %1$@", label.isEmpty ? L("Copy to Other Pane") : label)
        }
        var answer: [String: JSONValue] = [
            "from": .string(source.id),
            "to": .string(destination.id),
            "start": AgentHostTools.hex(range.lowerBound),
            "end": AgentHostTools.hex(range.upperBound),
            "length": AgentHostTools.hex(length),
            "changed": .int(Int64(changed))
        ]
        let host = PaneToolHost(pane: source.pane, owner: controller, tools: nil)
        let places = await locate(host, range)
        if !places.isEmpty { answer["where"] = .array(places) }
        guard changed > 0 else {
            // Nothing to undo: the other file holds these bytes already.
            answer["undo"] = .null
            answer["note"] = "The other file already holds these bytes; nothing was written."
            return .json(.object(answer))
        }
        guard case .object(let applied) = try apply(ToolTransaction(name: undoName, offset: offset, bytes: bytes),
                                                    to: destination) else { return .json(.object(answer)) }
        answer["undo"] = applied["undo"]
        answer["saved"] = false
        return .json(.object(answer))
    }

    // MARK: - Applying

    /// Refuses unless the switch is on and `place` can be changed: the
    /// sentence the model is given says what would make it possible.
    func checkEditable(_ place: AgentDesk.Place) throws {
        guard isAllowed() else {
            throw AgentToolError("Editing is switched off. The person allows it in ByteRipper's Settings ▸ Agent, "
                + "\"Let agents edit open files\". Say what you would change instead.")
        }
        _ = try place.onScreen()
        guard !place.pane.status.isReadOnly else {
            throw AgentToolError("\(place.id) is open read-only; nothing in it can be changed.")
        }
    }

    /// Writes `transaction` into `place` as one undo step, brings the change
    /// on screen as a step of the navigation history, and answers what was
    /// there before.
    func apply(_ transaction: ToolTransaction, to place: AgentDesk.Place) throws -> JSONValue {
        try checkEditable(place)
        let controller = try place.onScreen()
        let checked: ToolTransaction
        do {
            checked = try transaction.validated()
        } catch {
            throw AgentToolError("The change cannot be made: \(error).")
        }
        let size = place.pane.fileSize
        if let past = checked.writes.first(where: { $0.range.upperBound > size }) {
            throw AgentToolError("A write at \(AgentHostTools.hexText(past.offset)) runs past the end of \(place.id), "
                + "which is \(AgentHostTools.hexText(size)) bytes long. Writes overwrite; they do not grow the file.")
        }
        let before = try checked.writes.map { write in
            try place.pane.byteStorage?.read(at: write.offset, length: min(write.bytes.count, Self.beforeLimit)) ?? []
        }
        let host = PaneToolHost(pane: place.pane, owner: controller, tools: nil)
        do {
            try host.apply(checked)
        } catch {
            throw AgentToolError("Could not write into \(place.id): \(error).")
        }
        let covered = checked.writes.first!.offset..<checked.writes.last!.range.upperBound
        desk.bringForward(place)
        controller.recordJump(in: place.pane)
        controller.revealForTool(covered, in: place.pane, select: false)
        return [
            "document": .string(place.id),
            "written": .array(zip(checked.writes, before).map { write, before in
                var members: [String: JSONValue] = [
                    "start": AgentHostTools.hex(write.offset),
                    "end": AgentHostTools.hex(write.range.upperBound),
                    "before": .string(Self.hexText(before))
                ]
                if before.count < write.bytes.count { members["before_cut"] = true }
                return .object(members)
            }),
            "undo": .string(checked.name),
            "saved": false
        ]
    }

    /// The most bytes of what was there an answer repeats.
    static let beforeLimit = 64

    // MARK: - Helpers

    /// `body` in the app's own language rather than the English the agent is
    /// answered in: for words the person reads, such as the undo step.
    static func inAppLanguage<T>(_ body: () -> T) -> T {
        Localization.$override.withValue(nil) { body() }
    }

    /// Hex text as bytes: pairs of digits, spaces and `0x` prefixes ignored.
    nonisolated static func hexBytes(_ text: String, name: String) throws -> [UInt8] {
        let digits = text.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")
            .filter { !$0.isWhitespace && $0 != "," }
        guard digits.count.isMultiple(of: 2), digits.allSatisfy(\.isHexDigit) else {
            throw AgentToolError("`\(name)` is not hex bytes. Give pairs of hex digits, e.g. \"DE AD BE EF\".")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    nonisolated static func hexText(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func resolve(_ id: String?) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: id)
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }
}
