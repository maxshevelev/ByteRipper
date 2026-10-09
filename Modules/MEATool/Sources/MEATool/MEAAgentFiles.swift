import AgentKit
import Foundation
import MEFirmware
import MEPresentation
import MEReads
import ToolModuleKit

/// Two dumps' ME file systems compared file by file for an agent
/// (`Design/AGENT_PLAN.md`, stage 9). The comparison is `MEFileComparison`,
/// the value a panel will show; this only reads the two documents and words
/// the answer.
@MainActor
public enum MEAAgentFiles {
    nonisolated public static var comparisons: [ToolAgentComparison] { [compare] }

    nonisolated static let compare = ToolAgentComparison(
        name: "me_files_compare",
        title: "Compare ME files",
        description: """
            Sets the files of the ME file systems of two documents side by side — `document` and \
            `against` — by what each volume calls them (an MFS file's index, an EFS file's file ID) \
            and by what they hold, not by address. An MFS volume moves its pages to spread the wear, \
            so one machine's two dumps keep the same file in different places, and `diff` over the MFS \
            partition mostly finds pages moved; this says which files changed. Content is compared \
            without the Integrity table a protected file ends with; that table changes whenever the \
            engine writes the file again, so it is reported apart (`integrity_differs`). Answers \
            `counts` (same — and of those, `moved` and `rewritten` — different, only in one, \
            incomplete), the files that differ with both sizes and how many content bytes differ, and \
            the files only in one dump. `name` is the file table's path or name where it gives one. \
            A volume that could not be read on either side is under `not_compared` with the reason, \
            and its files are not listed as missing. `incomplete` is a file whose chain of chunks \
            broke off, so what it holds is not known whole. With `extents`, each listed file says \
            where it is stored in each dump: the stretches in the file's own order, which `read` \
            reads back. Pages: the lists are one sequence — `different`, `only_in_document`, \
            `only_in_against`, `incomplete` — and `limit` is the most items of it on one page, a \
            ceiling: a page also stops before the answer passes the size bound and then says \
            `truncated: "size"`. Pass `next` back as `after` until it is null; `counts` are of the whole \
            comparison. A file whose extents are too many for one answer lists the first of them, \
            marked `truncated: "item"`; `me_tree` on the file lists them. `encrypted` is the file table's flag: an encrypted file the engine wrote again \
            with a new nonce differs in nearly every byte, so for it `different` says it was written, \
            not that what it holds changed.
            """,
        properties: [
            "volume": AgentSchema.string("Only this volume: \"mfs\" or \"efs\". Default: both."),
            "name": AgentSchema.string("Only files whose name contains this, any case."),
            "extents": AgentSchema.boolean("Say where each listed file is stored in each dump. Default false."),
            "limit": AgentSchema.limit(default: 40, maximum: 200),
            "after": AgentSchema.after
        ]
    ) { host, otherHost, arguments in
        let volume = try arguments.optionalString("volume").map { text -> MEFileComparison.Volume in
            guard let volume = MEFileComparison.Volume(rawValue: text.lowercased()) else {
                throw AgentToolError("`volume` is \"mfs\" or \"efs\".")
            }
            return volume
        }
        let name = try arguments.optionalString("name")
        let withExtents = try arguments.bool("extents", default: false)
        let limit = try arguments.limit(default: 40, maximum: 200)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
            [host.contentVersion, otherHost.contentVersion, volume?.rawValue, name?.lowercased(), withExtents]))

        let mine = try await MEAAgentQueries.analysis(host)
        let theirs = try await MEAAgentQueries.analysis(otherHost)
        guard mine.mfsVolume != nil || mine.efsVolume != nil || theirs.mfsVolume != nil
            || theirs.efsVolume != nil || mine.regions.contains(where: isFileSystem)
            || theirs.regions.contains(where: isFileSystem)
        else {
            throw AgentToolError("Neither document has an MFS or EFS file system the ME engine could find.")
        }
        let comparison = MEFileComparison.compare(
            mine, theirs, names: (await names(mine), await names(theirs)),
            readA: reader(try host.snapshot()), readB: reader(try otherHost.snapshot()))
        return .json(try answer(comparison, volume: volume, name: name, extents: withExtents, limit: limit,
                                page: paging, bound: arguments.answerBound))
    }

    private nonisolated static func isFileSystem(_ region: FPTRegion) -> Bool {
        region.name == "MFS" || region.name == "EFS"
    }

    /// The file table's names for one dump's files, or none where the dump
    /// needs no table or it cannot be had.
    static func names(_ analysis: FirmwareAnalysis) async -> MEFileComparison.Names {
        guard MEReads.fileTableWanted(analysis) else { return .none }
        let volume = analysis.mfsVolume
        let names = await MEReads.fileNames(
            mfs: volume?.usesFTBL == true ? volume : nil, efs: analysis.efsVolume, configIDs: [],
            platform: volume?.ftblPlatform ?? -1, dictionary: volume?.ftblDictionary ?? -1)
        return MEFileComparison.Names(mfs: names?.mfs ?? .none, efs: names?.efs ?? .none)
    }

    private static func reader(_ snapshot: any ToolContentReader) -> (Range<Int>) -> Data? {
        { range in
            guard range.lowerBound >= 0 else { return nil }
            return try? Data(snapshot.read(at: UInt64(range.lowerBound), length: range.count))
        }
    }

    // MARK: - The answer

    nonisolated static func answer(_ comparison: MEFileComparison, volume: MEFileComparison.Volume?,
                                   name: String?, extents: Bool, limit: Int,
                                   page: AgentPage, bound: Int) throws -> JSONValue {
        let name = name?.lowercased()
        let rows = comparison.rows.filter { row in
            (volume.map { row.volume == $0 } ?? true)
                && (name.map { row.name?.lowercased().contains($0) == true } ?? true)
        }
        func of(_ status: MEFileComparison.Status) -> [MEFileComparison.Row] { rows.filter { $0.status == status } }
        let same = of(.same)
        let different = of(.different)
        let onlyHere = of(.onlyInA)
        let onlyThere = of(.onlyInB)
        let incomplete = of(.incomplete) + of(.unknown)

        var counts: [String: JSONValue] = [
            "same": .count(same.count),
            "moved": .count(same.filter(\.moved).count),
            "rewritten": .count(same.filter { $0.integrityDiffers == true }.count),
            "different": .count(different.count),
            "only_in_document": .count(onlyHere.count),
            "only_in_against": .count(onlyThere.count)
        ]
        if !incomplete.isEmpty { counts["incomplete"] = .count(incomplete.count) }

        var envelope: [String: JSONValue] = ["counts": .object(counts)]
        let gaps = comparison.gaps.filter { gap in volume.map { gap.volume == $0 } ?? true }
        if !gaps.isEmpty {
            envelope["not_compared"] = .array(gaps.map { gap in
                .object(["volume": .string(gap.volume.rawValue),
                         "in": .string(gap.inA ? "document" : "against"),
                         "reason": .string(reason(gap))])
            })
        }
        // One sequence, list by list; the page's items built only for the
        // stretch of it the page may hold.
        let lists: [(key: String, rows: [MEFileComparison.Row])] = [
            ("different", different), ("only_in_document", onlyHere),
            ("only_in_against", onlyThere), ("incomplete", incomplete)
        ]
        let sequence = lists.flatMap { list in list.rows.map { (key: list.key, row: $0) } }
        let items = sequence.dropFirst(page.first).prefix(limit).map { (key: $0.key, item: file($0.row, extents: extents)) }
        var keys = lists.map(\.key)
        if incomplete.isEmpty { keys.removeLast() }
        return try page.answer(envelope, keys: keys, items: items, total: sequence.count, bound: bound) { item in
            guard case .object(var members) = item, case .object(var stored)? = members["extents"] else { return nil }
            for (side, list) in stored {
                let all = list.arrayValue ?? []
                if all.count > Self.extentsShortened {
                    stored[side] = .array(Array(all.prefix(Self.extentsShortened)))
                    stored[side + "_total"] = .count(all.count)
                }
            }
            members["extents"] = .object(stored)
            members["truncated"] = "item"
            return .object(members)
        }
    }

    /// How many stretches a file too large for one answer keeps, per dump.
    nonisolated static let extentsShortened = 16

    private nonisolated static func file(_ row: MEFileComparison.Row, extents: Bool) -> JSONValue {
        var entry: [String: JSONValue] = [
            "volume": .string(row.volume.rawValue),
            row.volume == .mfs ? "index" : "file_id": .count(row.key)
        ]
        if let name = row.name { entry["name"] = .string(name) }
        if row.status == .incomplete { entry["why"] = "A chain of chunks broke off; the file is not known whole." }
        if row.status == .unknown { entry["why"] = "Neither the bytes nor a digest to compare." }
        var sizes: [String: JSONValue] = [:]
        if let a = row.a { sizes["document"] = .string(hex(a.contentSize)) }
        if let b = row.b { sizes["against"] = .string(hex(b.contentSize)) }
        entry["size"] = .object(sizes)
        if let differing = row.differingBytes { entry["differing_bytes"] = .count(differing) }
        if let integrity = row.integrityDiffers { entry["integrity_differs"] = .bool(integrity) }
        if let encrypted = row.encrypted { entry["encrypted"] = .bool(encrypted) }
        if extents {
            var stored: [String: JSONValue] = [:]
            if let a = row.a { stored["document"] = stretches(a.extents) }
            if let b = row.b { stored["against"] = stretches(b.extents) }
            entry["extents"] = .object(stored)
        }
        return .object(entry)
    }

    private nonisolated static func stretches(_ extents: [Range<Int>]) -> JSONValue {
        .array(extents.map { .object(["start": .string(hex($0.lowerBound)), "end": .string(hex($0.upperBound))]) })
    }

    nonisolated static func reason(_ gap: MEFileComparison.Gap) -> String {
        let volume = gap.volume.rawValue.uppercased()
        switch gap.reason {
        case .absent:
            return "This dump has no \(volume) volume."
        case .unreadable:
            return gap.volume == .efs
                ? "The EFS partition holds no volume that could be read; its System page may be erased."
                : "The MFS partition holds no volume that could be read."
        case .badSignature:
            return "The MFS volume header is missing or its signature is invalid."
        case .filesNotNamed:
            return "The EFS volume was read but not cut into files: that needs FileTable.dat, "
                + "which could not be had or does not describe this volume."
        }
    }

    private nonisolated static func hex(_ value: Int) -> String { String(format: "0x%lX", value) }
}
