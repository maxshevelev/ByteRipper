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
            The first call on a dump analyses its ME region, which takes a second or two.
            """
    ) { host, _ in
        let analysis = try await analysis(host)
        let blocks = MEASummary.build(analysis)
        return .json(["blocks": .array(blocks.map { block in
            var members: [String: JSONValue] = ["rows": .array(block.rows.map(row))]
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
            lines when the panel marks one.
            """,
        properties: [
            "node": AgentSchema.string("A node id such as \"2.0.3\" from an earlier answer. Default: the top."),
            "limit": AgentSchema.limit(default: 100, maximum: 400)
        ]
    ) { host, arguments in
        let path = try path(arguments.optionalString("node"))
        let limit = try arguments.limit(default: 100, maximum: 400)
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
                detail = .object(members)
            }
            answer["node"] = detail
            children = node.children
        }
        answer["children"] = .array(children.prefix(limit).map(summaryOf))
        if children.count > limit {
            answer["note"] = .string("\(children.count) children, cut at the limit. Raise `limit` for more.")
        }
        return .json(.object(answer))
    }

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
        guard MEReads.fileTableWanted(analysis) else { return MEACurator.present(analysis) }
        let volume = analysis.mfsVolume
        let names = await MEReads.fileNames(
            mfs: volume?.usesFTBL == true ? volume : nil, efs: analysis.efsVolume,
            configIDs: MEReads.configurationIDs(analysis),
            platform: volume?.ftblPlatform ?? -1, dictionary: volume?.ftblDictionary ?? -1)
        return MEACurator.present(analysis, mfsNames: names?.mfs ?? .none, efsNames: names?.efs ?? .none,
                                  configPaths: names?.config ?? .none)
    }

    // MARK: - Shapes

    private static func row(_ row: MEASummaryRow) -> JSONValue {
        var members: [String: JSONValue] = ["label": .string(row.label), "value": .string(row.value.text)]
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

    static func hex(_ value: UInt64) -> String { String(format: "0x%llX", value) }
}
