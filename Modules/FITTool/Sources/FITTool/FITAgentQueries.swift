import AgentKit
import Foundation
import Localization
import ToolModuleKit
import UEFIImage

/// What the FIT panel answers an agent from the bytes alone, with the panel
/// open or not (`Design/AGENT_PLAN.md`, stage 6): the table with its rows and
/// its problems, and one row in full.
///
/// Read the way the panel reads it — off the pane's shared tree, with the
/// branches the rows point into opened so each row can say what it points at
/// — and put in the panel's own words (`FITPresenter`), so what the agent says
/// about a row is what the person sees on it.
@MainActor
public enum FITAgentQueries {
    nonisolated public static var all: [ToolAgentQuery] { [table] }

    nonisolated static let table = ToolAgentQuery(
        name: "fit_table",
        title: "FIT table",
        description: """
            The Firmware Interface Table as the FIT panel reads it: where the pointer at the top of the \
            image leads, the table's place and checksum, and its rows — type, address, size, version and \
            what the row points at (a microcode with its CPUID, revision and date; a region the tree \
            names). `problems` are the specification's rules the table breaks, each with its row and \
            address. The Top Swap backup's copy of the table follows under `backup` when the image keeps \
            one. With `entry` (the row's place, 0 is the header) that row's every field as well. Whether \
            a newer microcode exists is the panel's to say, not this answer's.
            """,
        properties: [
            "entry": AgentSchema.integer("A row's place in the table, 0 for the header: its fields in full.")
        ]
    ) { host, arguments in
        let entry = try arguments.has("entry") ? Int(arguments.integer("entry")) : nil
        let tree = try await readyTree(host)
        let report = await read(tree)
        let display = FITPresenter.display(report)

        var answer: [String: JSONValue] = [
            "summary": .string(display.summary),
            "problems": .array(report.problems.map(problem))
        ]
        if report.addressDiffIsAssumed {
            answer["address_mapping"] = "assumed: no Volume Top File, so the image is taken to end at 4 GiB"
        }
        if let table = report.table {
            answer["table"] = [
                "start": .string(hex(table.range.lowerBound)), "end": .string(hex(table.range.upperBound)),
                "pointer_at": .string(hex(table.pointerOffset)), "pointer": .string(hex(table.pointerAddress)),
                "checksum": .string(String(format: "0x%02X", table.storedChecksum)),
                "checksum_should_be": .string(String(format: "0x%02X", table.computedChecksum)),
                "checksum_checked": .bool(table.checksumIsChecked)
            ]
        } else if !report.candidates.isEmpty {
            answer["tables_found_elsewhere"] = .array(report.candidates.map { .string(hex($0)) })
        }
        let main = display.rows.filter { !$0.isBackup }
        let backup = display.rows.filter(\.isBackup)
        answer["rows"] = .array(main.map(row))
        if !backup.isEmpty {
            answer["backup"] = [
                "heading": .string(display.backupHeading ?? ""),
                "rows": .array(backup.map(row))
            ]
        }
        if let entry {
            guard let chosen = main.first(where: { $0.index == entry }) else {
                throw AgentToolError("The table has no row \(entry); its rows are 0 to \(max(0, main.count - 1)).")
            }
            let detail = FITPresenter.detail(for: chosen, problems: report.problems)
            answer["entry"] = [
                "title": .string(detail.title),
                "fields": .array(detail.fields.map { field in
                    var members: [String: JSONValue] = ["label": .string(field.label), "value": .string(field.value)]
                    if field.isProblem { members["problem"] = true }
                    return .object(members)
                })
            ]
        }
        return .json(.object(answer))
    }

    // MARK: - fit_fix_checksum

    nonisolated public static let fixChecksum = ToolAgentEdit(
        name: "fit_fix_checksum",
        title: "Fix the FIT checksum",
        description: """
            Writes the checksum the FIT table should have into its header row — and into the Top Swap \
            backup's copy when that copy is the same table — as the FIT panel's Fix Checksum does, as one \
            undo step. Refused when there is no table, when its checksum is not checked or already \
            correct, and without the person's permission to edit.
            """,
        undoName: { L("Fix FIT Checksum") }
    ) { host, _ in
        let tree = try await readyTree(host)
        let report = await read(tree)
        guard let table = report.table else {
            throw AgentToolError("There is no FIT table here to fix; `fit_table` says what was found.")
        }
        guard table.checksumIsChecked else {
            throw AgentToolError("The table's ChecksumValid bit is clear: its checksum is not checked, and nothing needs writing.")
        }
        guard let fix = FITPresenter.display(report).checksumFix else {
            throw AgentToolError("The FIT checksum is already correct; nothing to write.")
        }
        return fix
    }

    // MARK: - Reading

    /// The pane's shared tree, its top level built and its address mapping
    /// worked out — what a FIT read cannot start without.
    static func readyTree(_ host: any ToolReadHost) async throws -> LazyUEFITree {
        guard let tree = (host as? any UEFITreeProviding)?.uefiTree() else {
            throw AgentToolError("This document has no firmware image to read a FIT from.")
        }
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        await withCheckedContinuation { continuation in tree.resolveAddresses { continuation.resume() } }
        return tree
    }

    /// The table, read again once the branches its rows point into are open,
    /// as the panel does, so each row names what it points at.
    static func read(_ tree: LazyUEFITree) async -> FITReport {
        let first = await readDetached(tree)
        guard let table = first.table else { return first }
        let targets = Set(table.rows.compactMap { row -> UInt64? in
            if case .bytes(let offset, _) = row.target { return offset }
            return nil
        })
        guard !targets.isEmpty else { return first }
        for offset in targets.sorted() {
            await withCheckedContinuation { continuation in
                tree.materialize(containing: offset) { _ in continuation.resume() }
            }
        }
        return await readDetached(tree)
    }

    /// Off the main actor: a table the pointer does not lead to is answered
    /// by a scan of the whole image.
    private static func readDetached(_ tree: LazyUEFITree) async -> FITReport {
        let reader = tree.imageReader
        let image = tree.image()
        return await Task.detached(priority: .userInitiated) {
            FITReader.read(reader, image: image)
        }.value
    }

    // MARK: - Shapes

    private static func row(_ row: FITDisplayRow) -> JSONValue {
        var members: [String: JSONValue] = [
            "index": .count(row.index),
            "type": .string(row.typeText),
            "address": .string(row.addressText),
            "size": .string(row.sizeText),
            "version": .string(row.versionText),
            "row_start": .string(hex(row.rowRange.lowerBound))
        ]
        if !row.targetText.isEmpty { members["points_at"] = .string(row.targetText) }
        if let target = row.targetRange {
            members["target_start"] = .string(hex(target.lowerBound))
            members["target_end"] = .string(hex(target.upperBound))
        }
        if !row.cpuids.isEmpty {
            members["cpuids"] = .array(row.cpuids.map { .string(String(format: "%X", $0)) })
        }
        if row.hasProblem { members["problem"] = true }
        return .object(members)
    }

    private static func problem(_ problem: FITProblem) -> JSONValue {
        var members: [String: JSONValue] = [
            "message": .string(problem.message),
            "severity": .string(problem.severity == .error ? "error" : "warning")
        ]
        if let index = problem.entryIndex { members["entry"] = .count(index) }
        if let offset = problem.offset { members["offset"] = .string(hex(offset)) }
        if problem.inBackup { members["in_backup"] = true }
        return .object(members)
    }

    static func hex(_ value: UInt64) -> String { String(format: "0x%llX", value) }
}
