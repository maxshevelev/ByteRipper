import AgentKit
import Foundation
import MEFirmware
import MEPresentation
import MEReads
import ToolModuleKit
import UEFIImage

/// What the ME Analyzer answers an agent from the bytes alone, with its panel
/// open or not (`Design/AGENT_PLAN.md`, stage 6): the summary, and the tree of
/// what the engine decoded, a node at a time.
///
/// The analysis is the pane's own (`MEAAnalysisProviding`): one the panel or
/// the UEFI Structure already made is answered from at once, and one made here
/// is kept for them — unless the bytes changed while it was being made. The
/// region is the one the descriptor names, from the pane's shared tree, as the
/// panel reads it.
@MainActor
public enum MEAAgentQueries {
    nonisolated public static var all: [ToolAgentQuery] { [summary, tree] }

    // MARK: - me_summary

    nonisolated static let summary = ToolAgentQuery(
        name: "me_summary",
        title: "ME summary",
        description: """
            The Intel ME / CSME / TXE / SPS firmware in the image, as the ME Analyzer panel's Summary tab \
            gives it: family, version, release, type, SKU, the platform, the security version (SVN), \
            whether the firmware database knows this build, and the analysis's messages (a corrupted \
            partition, a module whose hash fails, an update that will not apply). `tone` marks a verdict: \
            good, caution or bad. A value of "Coming soon" is a row this engine does not answer yet. \
            The File System State row carries `basis`: what each of the three steps that decide it found \
            (the reserved MFS files, whether the EFS volume holds files, the configuration partitions), \
            which step decided it, `complete: false` when a step that could have raised the state could \
            not be taken — an EFS partition that could not be read — and an `explanation`, which is the \
            row's own line: the state and, in brackets, the evidence it was read from. Say the evidence \
            when you report the state: Configured with an unreadable EFS is not the same fact as \
            Configured with an empty one. Three rows of our own answer what a bench asks of a dump it \
            is about to flash: "Manufacturing" (whether the platform closes End of Manufacturing on \
            the first boot of this image — "Will close on the EOM flag" or "Will close on the \
            descriptor's rights" (the two mechanisms: the flag only MFIT sets, and the access rights \
            a serial image relies on), "Will not close", "Will close on the EOM flag, with the \
            descriptor open", "Not readable from this image" or "No such switch in this firmware"), \
            which carries a `basis` of its own (the flag and which page it was read from, what End of \
            Manufacturing commits, and the descriptor's state — the last of those is `flexible`, \
            MFIT's `FlexibleEomSettings` in its four values, which the Configuration tab shows on \
            `/home/mca/eom_config`); \
            "Boot Guard", the profile the image is built for (0 - No_FVME, 3 - VM, 4 - FVE, 5 - FVME, \
            with `profile` and `profile_index` beside it, or "No profile record in this image"); and \
            "OEM Public Key Hash", the 48-byte SHA-384 the ME region carries, all zeros meaning OEM \
            signing is disabled. The first call on a dump analyses its ME region, which takes a \
            second or two.
            """
    ) { host, _ in
        let analysis = try await analysis(host)
        let blocks = MEASummary.build(analysis, in: .english)
        return .json(["blocks": .array(blocks.map { block in
            var members: [String: JSONValue] = ["rows": .array(block.rows.map { summaryRow in
                var entry = row(summaryRow)
                // The one verdict whose evidence is not in the row: what each
                // of its three steps found, and which decided it.
                if summaryRow.label == "File System State", summaryRow.value.isValue,
                   let state = analysis.mfsState, let basis = analysis.mfsStateBasis,
                   case .object(var fields) = entry {
                    fields["basis"] = basisJSON(state: state, basis: basis)
                    entry = .object(fields)
                }
                // The Manufacturing verdict's evidence likewise: the two pages
                // of the setting, and the descriptor's state — which a reader
                // (or an agent) must see before acting on "already closed".
                if summaryRow.label == "Manufacturing",
                   summaryRow.value.isValue,
                   let basis = analysis.manufacturingBasis,
                   let state = analysis.manufacturingState,
                   case .object(var fields) = entry {
                    fields["basis"] = manufacturingBasisJSON(state, basis)
                    entry = .object(fields)
                }
                if summaryRow.label == "Boot Guard",
                   summaryRow.value.isValue,
                   let profile = analysis.bootGuardProfile,
                   case .object(var fields) = entry {
                    fields["profile"] = .string(profile.rawValue)
                    fields["profile_index"] = .count(profile.index)
                    entry = .object(fields)
                }
                return entry
            })]
            if let title = block.title { members["title"] = .string(title) }
            return .object(members)
        })])
    }

    // MARK: - me_tree

    nonisolated static let tree = ToolAgentQuery(
        name: "me_tree",
        title: "ME structure",
        description: """
            The structure the ME engine decoded, as the ME Analyzer panel's Full Info tab shows it: the \
            partition table, partitions, code partition manifests and modules, the MFS or EFS file \
            system and its files, the configuration records, the checksums. Without `node`, the top \
            groups; with it, that node's fields and its children. Each node: `id` (pass it back as \
            `node`; ids are positions, so they hold for this dump only), `title`, `subtitle`, its bytes \
            (`start`, `end`) when it stands for some, `children` as a count, and `problem` with its \
            lines when the panel marks one. An MFS or EFS file has no one range: its bytes are scattered \
            over the volume's pages, so it says `stretches`, how many, and asked for as `node` lists \
            them as `extents`, in the file's own order. Pages: `limit` is the most children on one page, \
            a ceiling — a page also stops before the answer passes the size bound and then says \
            `truncated: "size"`; pass `next` back as `after` until it is null. `total` counts the children.
            """,
        properties: [
            "node": AgentSchema.string("A node id such as \"2.0.3\" from an earlier answer. Default: the top."),
            "limit": AgentSchema.limit(default: 100, maximum: 400),
            "after": AgentSchema.after
        ]
    ) { host, arguments in
        let path = try path(arguments.optionalString("node"))
        let limit = try arguments.limit(default: 100, maximum: 400)
        let paging = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([host.contentVersion, id(path)]))
        let analysis = try await analysis(host)
        let roots = await present(analysis)

        var answer: [String: JSONValue] = [:]
        let children: [MEANode]
        if path.isEmpty {
            children = roots
        } else {
            guard let node = MEATree.node(at: path, in: roots) else {
                throw AgentToolError("No ME node \(id(path)). Ids come from `me_tree` on the same document.")
            }
            var detail = summaryOf(node)
            if case .object(var members) = detail {
                members["fields"] = .array(node.fields.map { field in
                    var entry: [String: JSONValue] = ["label": .string(field.label), "value": .string(field.value)]
                    if field.tone.isStatus { entry["tone"] = .string(toneName(field.tone)) }
                    return .object(entry)
                })
                // A file's bytes are where the volume put them: the stretches
                // in the file's order, which `read` reads back.
                if let extents = node.extents, !extents.isEmpty {
                    members["extents"] = .array(extents.prefix(Self.extentsShown).map {
                        .object(["start": .string(hex($0.lowerBound)), "end": .string(hex($0.upperBound))])
                    })
                    if extents.count > Self.extentsShown {
                        members["extents_note"] = .string("\(extents.count) stretches; the first \(Self.extentsShown) are listed.")
                    }
                }
                detail = .object(members)
            }
            answer["node"] = detail
            children = node.children
        }
        answer["total"] = .count(children.count)
        return .json(try paging.answer(answer, key: "children",
                                       items: children.dropFirst(paging.first).prefix(limit).map(summaryOf),
                                       total: children.count, bound: arguments.answerBound))
    }

    /// How many of a file's stretches `me_tree` lists: a 12 KiB MFS file is
    /// some 190 chunks.
    nonisolated static let extentsShown = 64

    // MARK: - The analysis

    /// The pane's analysis of its ME region: the cached one, or one made now
    /// and kept for the panels when the bytes held still meanwhile.
    static func analysis(_ host: any ToolReadHost) async throws -> FirmwareAnalysis {
        let provider = host as? any MEAAnalysisProviding
        if let cached = provider?.cachedMEAnalysis() { return cached }
        let meRegion = await region(host)
        let version = host.contentVersion
        let snapshot = try host.snapshot()
        let source = MEReads.dataSource
        let result = await MEReads.read(
            snapshot, meRegion: meRegion, analyzer: MEFirmwareAnalyzer(data: source),
            source: source, provider: provider
        ) { _, _ in }
        switch result {
        case .success(let analysis):
            if let version, host.contentVersion == version, provider?.cachedMEAnalysis() == nil {
                provider?.setCachedMEAnalysis(analysis, meRegion: meRegion)
            }
            return analysis
        case .failure(let error):
            throw AgentToolError(MEReads.describe(error))
        }
    }

    /// The ME region the descriptor names, from the shared tree; nil when
    /// there is no descriptor and the engine has to find the firmware itself.
    static func region(_ host: any ToolReadHost) async -> Range<UInt64>? {
        guard let tree = (host as? any UEFITreeProviding)?.uefiTree() else { return nil }
        await withCheckedContinuation { continuation in tree.whenReady { continuation.resume() } }
        return tree.region(.me)
    }

    /// The panel's tree, with the files named from the firmware database's
    /// file table when the dump needs it and it can be had.
    static func present(_ analysis: FirmwareAnalysis) async -> [MEANode] {
        guard MEReads.fileTableWanted(analysis) else { return MEACurator.present(analysis, in: .english) }
        let volume = analysis.mfsVolume
        let names = await MEReads.fileNames(
            mfs: volume?.usesFTBL == true ? volume : nil, efs: analysis.efsVolume,
            configIDs: MEReads.configurationIDs(analysis),
            platform: volume?.ftblPlatform ?? -1, dictionary: volume?.ftblDictionary ?? -1)
        return MEACurator.present(analysis, mfsNames: names?.mfs ?? .none, efsNames: names?.efs ?? .none,
                                  configPaths: names?.config ?? .none, in: .english)
    }

    // MARK: - The Manufacturing verdict's basis

    /// The End of Manufacturing verdict's evidence, for the same reason the
    /// File System State carries its own: the row says "Already closed", and an
    /// agent that acts on it needs to see that it was the live `/home/mca/eom`
    /// record that said so and not a reading of the image's setting.
    static func manufacturingBasisJSON(_ state: ManufacturingState,
                                       _ basis: ManufacturingBasis) -> JSONValue {
        var members: [String: JSONValue] = [
            "flag": basis.flag.map { .bool($0) } ?? .null,
            "flexible_eom_settings": basis.flexible.map { .count($0) } ?? .null,
            "flag_page": .string(basis.page?.rawValue ?? "none"),
            "descriptor": .string(basis.descriptorOpen.map { $0 ? "open" : "locked" } ?? "not read"),
            "live_files": .string(basis.liveFilesResolved ? "read" : "not read")
        ]
        // What the row itself reads, brackets and all.
        let verdict = MEAText.manufacturingState(state, basis: basis, in: .english)
        let evidence = MEAText.manufacturingEvidence(state, basis: basis, in: .english)
        members["explanation"] = .string(
            evidence.isEmpty ? verdict : "\(verdict) (\(evidence))")
        return .object(members)
    }

    // MARK: - The File System State's basis

    static func basisJSON(state: MFSState, basis: MFSStateBasis) -> JSONValue {
        [
            "decided_by": .string(stepName(basis.decidedBy)),
            "reserved_files": .string(reservedText(basis.reservedFiles)),
            "efs": .string(efsText(basis.efs)),
            "configuration": .array(basis.configuration.map { .string($0) }),
            "complete": .bool(!basis.isIncomplete),
            "explanation": .string(explanation(state: state, basis: basis))
        ]
    }

    nonisolated static func stepName(_ step: MFSStateBasis.Step) -> String {
        switch step {
        case .reservedFiles: return "reserved_files"
        case .efs: return "efs"
        case .configuration: return "configuration"
        case .nothing: return "nothing"
        }
    }

    nonisolated static func reservedText(_ files: MFSStateBasis.ReservedFiles) -> String {
        switch files {
        case .notRead:
            return "not read: this volume names its files through its own tables (CSME 15/16), so no state is claimed from file indices"
        case .none:
            return "none of the reserved low-level files (0–5, 7, 8, 9) is present"
        case .initializing(let indices):
            return "present: \(list(indices)), which mean Initialized"
        case .configuring(let indices):
            return "present: \(list(indices)), which mean Configured"
        }
    }

    nonisolated static func efsText(_ efs: MFSStateBasis.EFS) -> String {
        switch efs {
        case .holdsFiles:
            return "the EFS volume holds file content, which means Initialized"
        case .noFileContent:
            return "the EFS volume was read and holds no file content"
        case .filesNotNamed:
            return "the EFS volume was read, but its files are known only from the firmware database's file table, which was not available"
        case .unreadable(let offset):
            return "unreadable: the partition table lists an EFS partition at \(hex(UInt64(offset))), but no EFS volume could be read there"
        case .noPartition:
            return "no EFS partition"
        }
    }

    /// What the row itself reads: the state, then its evidence in brackets —
    /// the panel's own words in the English every agent call is answered in.
    static func explanation(state: MFSState, basis: MFSStateBasis) -> String {
        MEAText.fileSystemState(state, basis: basis, in: .english)
    }

    private nonisolated static func list(_ indices: [Int]) -> String {
        indices.map { "file \($0)" }.joined(separator: ", ")
    }

    // MARK: - Shapes

    private static func row(_ row: MEASummaryRow) -> JSONValue {
        var members: [String: JSONValue] = ["label": .string(row.label), "value": .string(row.value.text(in: .english))]
        if row.value.isValue, row.tone.isStatus { members["tone"] = .string(toneName(row.tone)) }
        return .object(members)
    }

    private static func summaryOf(_ node: MEANode) -> JSONValue {
        var members: [String: JSONValue] = ["id": .string(id(node.path)), "title": .string(node.title)]
        if !node.subtitle.isEmpty { members["subtitle"] = .string(node.subtitle) }
        if let range = node.range {
            members["start"] = .string(hex(range.lowerBound))
            members["end"] = .string(hex(range.upperBound))
        }
        if let extents = node.extents, !extents.isEmpty { members["stretches"] = .count(extents.count) }
        if !node.children.isEmpty { members["children"] = .count(node.children.count) }
        if node.isEmptySection { members["empty"] = true }
        if let problem = node.marks.problem {
            members["problem"] = [
                "severity": .string(problem.isError ? "error" : "caution"),
                "lines": .array(problem.lines.map { .string($0) })
            ]
        }
        return .object(members)
    }

    private static func toneName(_ tone: ToolValueTone) -> String {
        switch tone {
        case .standard: return "standard"
        case .good: return "good"
        case .caution: return "caution"
        case .bad: return "bad"
        }
    }

    static func id(_ path: [Int]) -> String { path.map(String.init).joined(separator: ".") }

    static func path(_ text: String?) throws -> [Int] {
        guard let text, !text.isEmpty, text != "root" else { return [] }
        let parts = text.split(separator: ".").map { Int($0) }
        guard parts.allSatisfy({ ($0 ?? -1) >= 0 }) else {
            throw AgentToolError("`\(text)` is not an ME node id. Ids look like \"2.0.3\" and come from `me_tree`.")
        }
        return parts.compactMap { $0 }
    }

    nonisolated static func hex(_ value: UInt64) -> String { String(format: "0x%llX", value) }
}
