import AgentKit
import Foundation
import Localization
import ToolModuleKit
import UEFIImage

/// Microcode for an agent: what the catalogue offers for the image, and the
/// three changes the FIT panel makes — add (or update in place), replace a
/// row's, take one out.
///
/// The changes are the panel's own (`FITEditor`), worked out from the file as
/// it is now, so every check the panel makes is made here too: a component
/// that is not a microcode or whose checksum is wrong, the same update already
/// in the table under another of the CPUIDs its extended signature table
/// names, a replacement that serves a processor another row already serves,
/// a table or a run that cannot grow, a write into a Boot Guard IBB, a Top
/// Swap backup that differs. Fetching from the catalogue is the panel's
/// source's; this is the part that needs no network.
@MainActor
public enum FITAgentMicrocode {
    // MARK: - The changes

    /// What a change starts from: the table read with its targets opened, the
    /// address mapping and the protected ranges, from the tree as it is now.
    struct Ground: Sendable {
        var table: FITTable
        var image: UEFIImage
        var reader: ImageReader
        var addressDiff: UInt64
        var protected: ProtectedRanges?
    }

    static func ground(_ tree: LazyUEFITree) async throws -> Ground {
        guard let table = await FITAgentQueries.read(tree).table else {
            throw AgentToolError("There is no FIT table here; `fit_table` says what was found.")
        }
        await withCheckedContinuation { continuation in tree.resolveProtectedRanges { continuation.resume() } }
        let reader = tree.imageReader
        let image = tree.image()
        return Ground(table: table, image: image, reader: reader,
                      addressDiff: image.addressDiff ?? (0x1_0000_0000 &- reader.count),
                      protected: tree.protectedRanges)
    }

    /// Adds `component`, or puts it in place of the row for the same
    /// processor — the panel's Add Microcode.
    public static func add(_ component: [UInt8], to host: any ToolReadHost) async throws -> ToolAgentEdit.Change {
        let ground = try await ground(FITAgentQueries.readyTree(host))
        let result = await Task.detached(priority: .userInitiated) {
            FITEditor.addOrReplaceMicrocode(component, in: ground.table, image: ground.image, reader: ground.reader,
                                            addressDiff: ground.addressDiff, protected: ground.protected)
        }.value
        let (transaction, outcome) = try result.get(orRefuse: ())
        return ToolAgentEdit.Change(transaction, undoDetail: cpuidText(component), report: report(outcome))
    }

    /// Puts `component` in the place of row `entry`'s — the panel's Replace
    /// Microcode.
    public static func replace(_ entry: Int, with component: [UInt8],
                               in host: any ToolReadHost) async throws -> ToolAgentEdit.Change {
        let ground = try await ground(FITAgentQueries.readyTree(host))
        try requireMicrocodeRow(entry, in: ground.table)
        let result = await Task.detached(priority: .userInitiated) {
            FITEditor.replaceMicrocode(at: entry, component, in: ground.table, image: ground.image,
                                       reader: ground.reader, addressDiff: ground.addressDiff,
                                       protected: ground.protected)
        }.value
        let (transaction, outcome) = try result.get(orRefuse: ())
        return ToolAgentEdit.Change(transaction, undoDetail: cpuidText(component), report: report(outcome))
    }

    /// Takes row `entry` and its component out — the panel's Remove
    /// Microcode.
    public static func remove(_ entry: Int, from host: any ToolReadHost) async throws -> ToolAgentEdit.Change {
        let ground = try await ground(FITAgentQueries.readyTree(host))
        try requireMicrocodeRow(entry, in: ground.table)
        let removed = ground.table.rows[entry]
        let result = await Task.detached(priority: .userInitiated) {
            FITEditor.removeMicrocode(entry, from: ground.table, image: ground.image, in: ground.reader,
                                      addressDiff: ground.addressDiff, protected: ground.protected)
        }.value
        let (transaction, outcome) = try result.get(orRefuse: ())
        var detail = ""
        if case .microcode(let header) = removed.target { detail = MicrocodeHeader.cpuid(header.processorSignature) }
        return ToolAgentEdit.Change(transaction, undoDetail: detail, report: report(outcome))
    }

    private static func requireMicrocodeRow(_ entry: Int, in table: FITTable) throws {
        guard entry > 0, entry < table.rows.count else {
            throw AgentToolError("The table has no row \(entry); its rows are 1 to \(table.rows.count - 1) after the header.")
        }
        guard case .microcode = table.rows[entry].target else {
            throw AgentToolError("Row \(entry) is not a microcode row; `fit_table` lists the rows.")
        }
    }

    private static func cpuidText(_ component: [UInt8]) -> String {
        (try? FITEditor.microcode(in: component).get()).map { MicrocodeHeader.cpuid($0.processorSignature) } ?? ""
    }

    // MARK: - What a change says

    static func report(_ outcome: FITEditOutcome) -> [String: JSONValue] {
        var members: [String: JSONValue] = [
            "change": .string(outcome.kind == .added ? "added" : "replaced"),
            "entry": .count(outcome.entryIndex),
            "component": range(outcome.range),
            "moved": .count(outcome.moved)
        ]
        if let replaced = outcome.replaced {
            members["replaced"] = [
                "cpuid": .string(MicrocodeHeader.cpuid(replaced.processorSignature)),
                "revision": .string(String(format: "0x%X", replaced.updateRevision)),
                "date": .string(replaced.date)
            ]
        }
        members.merge(caveats(outcome.protectionWarnings, outcome.topSwapBackup)) { own, _ in own }
        return members
    }

    static func report(_ outcome: FITRemovalOutcome) -> [String: JSONValue] {
        var members: [String: JSONValue] = [
            "change": "removed",
            "entry": .count(outcome.entryIndex),
            "moved": .count(outcome.moved)
        ]
        if let erased = outcome.erased { members["erased"] = range(erased) }
        members.merge(caveats(outcome.protectionWarnings, outcome.topSwapBackup)) { own, _ in own }
        return members
    }

    /// What every change says beside its writes: whether it was checked
    /// against the protected ranges and what it breaks there, and the Top
    /// Swap backup it was made in as well.
    private static func caveats(_ warnings: [String]?, _ backup: Range<UInt64>?) -> [String: JSONValue] {
        var members: [String: JSONValue] = [:]
        if let warnings {
            members["protected_ranges"] = warnings.isEmpty
                ? "nothing written inside a Boot Guard or vendor protected range"
                : .array(warnings.map { .string($0) })
        } else {
            members["protected_ranges"] = "not checked: the image's protected ranges could not be read"
        }
        if let backup { members["top_swap_backup"] = range(backup) }
        return members
    }

    private static func range(_ range: Range<UInt64>) -> JSONValue {
        ["start": .string(FITAgentQueries.hex(range.lowerBound)), "end": .string(FITAgentQueries.hex(range.upperBound))]
    }

    // MARK: - The catalogue against the image

    /// `microcode_catalogue`'s answer over `all`, the catalogue as listed.
    public static func catalogue(_ all: [MicrocodeCatalogueEntry], for host: any ToolReadHost,
                                 _ arguments: AgentArguments) async throws -> AgentAnswer {
        let cpuid = try arguments.optionalString("cpuid")?.uppercased()
            .replacingOccurrences(of: "0X", with: "")
        let inImage = try arguments.bool("in_image", default: false)
        let productionOnly = try arguments.bool("production_only", default: false)
        let latestOnly = try arguments.bool("latest_only", default: false)
        let limit = try arguments.limit(default: 50, maximum: 300)

        var envelope: [String: JSONValue] = [:]
        var installed: [FITRow] = []
        var served: Set<UInt32>?
        if inImage {
            let tree = try await FITAgentQueries.readyTree(host)
            guard let table = await FITAgentQueries.read(tree).table else {
                throw AgentToolError("There is no FIT table here; `fit_table` says what was found.")
            }
            installed = table.rows.filter { if case .microcode = $0.target { return true } else { return false } }
            served = Set(installed.flatMap { row -> [UInt32] in
                guard case .microcode(let header) = row.target else { return [] }
                return header.processorSignatures
            })
            envelope["installed"] = .array(Self.installed(table, catalogue: all))
        }
        let chosen = chosen(all, cpuid: cpuid, served: served, productionOnly: productionOnly, latestOnly: latestOnly)
        envelope["total"] = .count(chosen.count)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [all.count, all.first?.path, host.contentVersion, cpuid, inImage, productionOnly, latestOnly]),
            changed: "The catalogue or the image changed since that page; ask again without `after`.")
        let items = chosen.dropFirst(paging.first).prefix(limit).map { entry($0, installed: installed) }
        return .json(try paging.answer(envelope, key: "files", items: Array(items), total: chosen.count,
                                       bound: arguments.answerBound))
    }

    /// The image's microcode rows, each with the processors its update serves
    /// — its extended signature table's included — and how it stands against
    /// the catalogue.
    static func installed(_ table: FITTable, catalogue: [MicrocodeCatalogueEntry]) -> [JSONValue] {
        table.rows.compactMap { row -> JSONValue? in
            guard case .microcode(let header) = row.target else { return nil }
            var members: [String: JSONValue] = [
                "entry": .count(row.entry.index),
                "cpuids": .array(header.processorPlatforms.map { pair in
                    ["cpuid": .string(MicrocodeHeader.cpuid(pair.signature)),
                     "platforms": .string(String(format: "0x%02X", pair.platformIDs))]
                }),
                "revision": .string(String(format: "0x%X", header.updateRevision)),
                "date": .string(header.date)
            ]
            switch MicrocodeCatalogue.latest(of: header, in: catalogue) {
            case .latest:
                members["catalogue"] = "latest"
            case .outdated(let newest):
                members["catalogue"] = "outdated"
                members["newest_revision"] = .string(String(format: "0x%X", newest))
            case .undecided(let newest):
                members["catalogue"] = "undecided"
                members["newest_revision"] = .string(String(format: "0x%X", newest))
            case .notRated:
                members["catalogue"] = "not_rated"
            }
            return .object(members)
        }
    }

    /// A catalogue file, and — when the image is given — the rows whose
    /// update serves the same processor on a platform the file's mask meets.
    static func entry(_ entry: MicrocodeCatalogueEntry, installed: [FITRow]) -> JSONValue {
        var members: [String: JSONValue] = [
            "path": .string(entry.path),
            "cpuid": .string(entry.cpuidText),
            "platforms": .string("0x" + entry.platformText),
            "revision": .string("0x" + entry.revisionText),
            "date": .string(entry.date),
            "production": .bool(entry.isProduction),
            "size": .string(FITAgentQueries.hex(entry.size))
        ]
        let rows = installed.filter { row in
            guard case .microcode(let header) = row.target, let cpuid = entry.cpuid else { return false }
            let mask = entry.platformID ?? 0
            return header.processorPlatforms.contains { pair in
                pair.signature == cpuid && (mask == 0 || pair.platformIDs == 0 || pair.platformIDs & mask != 0)
            }
        }
        if !rows.isEmpty {
            members["serves_rows"] = .array(rows.map { .count($0.entry.index) })
            if let revision = entry.revision {
                let installedRevisions = rows.compactMap { row -> UInt32? in
                    guard case .microcode(let header) = row.target else { return nil }
                    return header.updateRevision
                }
                members["newer_than_installed"] = .bool(installedRevisions.allSatisfy { revision > $0 })
            }
        }
        return .object(members)
    }

    /// The Intel files to list: those whose CPUID starts with `cpuid`, only
    /// those for a processor the image's microcodes serve when `inImage`, and
    /// only the newest revision for each processor and platform mask when
    /// `latestOnly` — sorted by CPUID, then platform mask, newest first.
    static func chosen(_ catalogue: [MicrocodeCatalogueEntry], cpuid: String?, served: Set<UInt32>?,
                       productionOnly: Bool, latestOnly: Bool) -> [MicrocodeCatalogueEntry] {
        var entries = MicrocodeCatalogue.filter(catalogue, vendor: .intel, search: cpuid ?? "",
                                                cpuidsInTheImage: served)
        if productionOnly { entries = entries.filter(\.isProduction) }
        entries.sort { a, b in
            if a.cpuid != b.cpuid { return (a.cpuid ?? 0) < (b.cpuid ?? 0) }
            if a.platformID != b.platformID { return (a.platformID ?? 0) < (b.platformID ?? 0) }
            return (a.revision ?? 0) > (b.revision ?? 0)
        }
        guard latestOnly else { return entries }
        var seen = Set<String>()
        return entries.filter { seen.insert("\($0.cpuidText)/\($0.platformText)").inserted }
    }
}

extension Result where Failure == FITEditProblem {
    /// The change, or the panel's own sentence for why not.
    func get(orRefuse _: Void) throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let problem):
            // The panel numbers its rows from 1 with the header first; an
            // agent knows a row by its `entry` in `fit_table`, from 0.
            switch problem {
            case .alreadyInTheTable(let entry), .servedByAnotherRow(let entry, _):
                throw AgentToolError(problem.message + " In `fit_table` that row is entry \(entry).")
            default:
                throw AgentToolError(problem.message)
            }
        }
    }
}
