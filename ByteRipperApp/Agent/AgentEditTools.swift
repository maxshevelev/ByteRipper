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

    /// The most bytes one `write` carries: a patch, not an image.
    static let writeLimit = 0x1_0000

    init(desk: AgentDesk) {
        self.desk = desk
    }

    nonisolated func tools() -> [AgentTool] { [writeTool] }

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
