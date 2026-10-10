import AgentKit
import Foundation
import Localization
import ToolModuleKit
import UEFIImage

/// The changes the UEFI Structure works out for an agent
/// (`Design/AGENT_PLAN.md`, "Edits"): a node's checksum put right, by the code
/// the panel's Fix Checksum runs. The module only computes the writes; the app
/// applies them, if the person's edit switch allows it.
@MainActor
public enum UEFIAgentEdits {
    nonisolated public static var all: [ToolAgentEdit] { [fixChecksum] }

    nonisolated static let fixChecksum = ToolAgentEdit(
        name: "uefi_fix_checksum",
        title: "Fix UEFI checksums",
        description: """
            Puts checksums right — a volume's header checksum, a file's header and data checksums, a \
            microcode's, an AMD PSP or BIOS directory's — computed by the code the UEFI Structure panel's Fix \
            Checksum runs, and writes them as one undo step. Give `node` for one node, or `all: true` for \
            every wrong checksum in the image (or under `node`) that can be written in place: a file that \
            holds a volume is put right after the files inside it, over their fixed bytes. `uefi_checksums` \
            lists the wrong ones, `uefi_node` marks one with `problem`. A node inside a compressed section \
            is never written (the file holds those bytes compressed): refused by itself, left out of `all` \
            and counted in `skipped_compressed`. Refused when nothing is wrong, and without the person's \
            permission to edit.
            """,
        properties: [
            "node": AgentSchema.string("The node's id, e.g. \"0.2.5\". With `all`, only under it."),
            "all": AgentSchema.boolean("Every wrong checksum in the image, or under `node`. Default false.")
        ],
        undoName: L("Fix Checksum")
    ) { host, arguments in
        let tree = try await UEFIAgentQueries.readyTree(host)
        let id = try UEFIAgentQueries.nodeID(arguments.optionalString("node"))
        if try arguments.bool("all", default: false) {
            if id != .root {
                _ = await UEFIAgentQueries.reachable(id, in: tree)
                guard tree.node(id) != nil else { throw UEFIAgentQueries.unknownNode(id) }
            }
            let scan = await UEFIAgentChecksums.scan(tree, under: id)
            let compressed = scan.wrong.filter { $0.node.space != .file }.count
            let (writes, fixed) = await UEFIAgentChecksums.fixAll(tree, under: id)
            guard !writes.isEmpty else {
                throw AgentToolError(compressed == 0
                    ? "Every checksum checks out; nothing to write."
                    : "The only wrong checksums are inside compressed sections (\(compressed)), which cannot be written in place.")
            }
            return ToolAgentEdit.Change(
                ToolTransaction(name: "Fix Checksum", writes: writes),
                report: [
                    "fixed": .array(fixed.map { node in
                        ["id": .string(node.id.description),
                         "name": .string(UEFITreeDisplay.ownName(of: node) ?? node.name)]
                    }),
                    "skipped_compressed": .count(compressed)
                ])
        }
        guard id != .root else { throw AgentToolError("Give `node`, or `all: true` for every wrong checksum.") }
        _ = await UEFIAgentQueries.reachable(id, in: tree)
        guard let node = tree.node(id) else { throw UEFIAgentQueries.unknownNode(id) }
        guard node.space == .file else {
            throw AgentToolError("\(id.description) is inside a compressed section, which the file holds compressed; "
                + "its checksum cannot be written in place.")
        }
        let image = tree.image()
        let reader = tree.imageReader
        let revision = UEFIChecksumCheck.volumeRevision(of: node, in: image)
        let polarity = UEFIChecksumCheck.volumeErasePolarity(of: node, in: image, reader: reader)
        let repairs = await Task.detached(priority: .userInitiated) {
            UEFIChecksumCheck.repairs(for: node, volumeRevision: revision,
                                      volumeErasePolarity: polarity, in: reader)
        }.value
        guard !repairs.isEmpty else {
            throw AgentToolError("The checksums of \(id.description) already check out; nothing to write.")
        }
        return ToolAgentEdit.Change(ToolTransaction(name: "Fix Checksum",
                                                    writes: repairs.map { ToolTransaction.Write(offset: $0.offset, bytes: $0.bytes) }))
    }
}
