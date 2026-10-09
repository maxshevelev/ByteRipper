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
        title: "Fix a UEFI checksum",
        description: """
            Puts a node's checksums right — a volume's header checksum, a file's header and data \
            checksums, a microcode's — computed by the code the UEFI Structure panel's Fix Checksum runs, \
            and writes them as one undo step. `uefi_node` marks a wrong checksum with `problem`. Refused \
            for a node inside a compressed section (the file holds those bytes compressed), for one whose \
            checksums already check out, and without the person's permission to edit.
            """,
        properties: ["node": AgentSchema.string("The node's id, e.g. \"0.2.5\".")],
        required: ["node"],
        undoName: { L("Fix Checksum") }
    ) { host, arguments in
        let tree = try await UEFIAgentQueries.readyTree(host)
        let id = try UEFIAgentQueries.nodeID(arguments.string("node"))
        _ = await UEFIAgentQueries.reachable(id, in: tree)
        guard id != .root, let node = tree.node(id) else { throw UEFIAgentQueries.unknownNode(id) }
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
        return ToolTransaction(name: "Fix Checksum",
                               writes: repairs.map { ToolTransaction.Write(offset: $0.offset, bytes: $0.bytes) })
    }
}
