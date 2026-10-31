import AgentKit
import CodeAnalysis
import Foundation
import GhidraHost
import UEFITool

/// `ghidra_open` by a node of an open dump, or by `module` for one with a
/// project already (`Design/SERVER_HEADLESS_PLAN.md` §4.1): the node's body
/// is read from the document's tree and its bytes go to Ghidra.
///
/// Both hosts serve the shared Ghidra tools without their `ghidra_open` by
/// base64 and with this one in its place — two tools of one name in one list
/// is a defect, so `tools` replaces rather than adds.
public enum GhidraNodeOpen {
    /// `GhidraTools`' list over `backend`, its `ghidra_open` this one.
    ///
    /// - Parameters:
    ///   - description: what the tool says — where Ghidra runs is the host's
    ///     to say.
    ///   - document: what the schema says of the `document` argument.
    public static func tools(backend: GhidraBackend, documents: any AgentDocumentSet,
                             description: String, document: String) -> [AgentTool] {
        GhidraTools.tools(backend: backend, includeOpenByImage: false).map { tool in
            tool.name == "ghidra_open"
                ? self.tool(backend: backend, documents: documents, description: description, document: document)
                : tool
        }
    }

    public static func tool(backend: GhidraBackend, documents: any AgentDocumentSet,
                            description: String, document: String) -> AgentTool {
        AgentTool(
            name: "ghidra_open",
            title: "Open a module in Ghidra",
            description: description,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string(document),
                "node": AgentSchema.string("The PE32 or TE image node, e.g. \"0.6.4.0.0.199.3\"."),
                "name": AgentSchema.string("What to call the module. Default: the file it is in."),
                "module": AgentSchema.string("Or a module already opened, by its SHA-256.")
            ]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: true)
        ) { call in
            let arguments = call.arguments
            if let node = try arguments.optionalString("node") {
                let found = try await self.image(node: node, document: try arguments.optionalString("document"),
                                                 in: documents)
                let chosen = try arguments.optionalString("name") ?? found.name
                let answer = try await GhidraTools.answer {
                    await GhidraTools.opened(
                        try await backend.openImage(found.image, name: chosen,
                                                    document: found.document.label.isEmpty
                                                        ? found.document.id : found.document.label,
                                                    node: node),
                        module: SHA256Digest(data: found.image), backend: backend)
                }
                // The answer says which document it read and carries its disk
                // mark, as a query's does: an agent calls `documents` once and
                // works in `uefi_tree`, `read` and `ghidra_open` after, so
                // that is where it has to see the mark
                // (`Design/SERVER_HEADLESS_PLAN.md` decision 9).
                return ToolQueryTools.stamped(answer, with: found.document)
            }
            let module = try GhidraTools.module(arguments)
            return try await GhidraTools.answer {
                await GhidraTools.opened(try await backend.openModule(module), module: module, backend: backend)
            }
        }
    }

    /// The node's image bytes, a name for the module — the file it is in —
    /// and the document they were read from.
    @MainActor
    static func image(node text: String, document id: String?,
                      in documents: any AgentDocumentSet) async throws -> (image: Data, name: String,
                                                                          document: any AgentDocument) {
        let document = try documents.resolve(id)
        let found = try await UEFIAgentNodeData.bytes(document.readHost(), node: text, part: .body)
        guard let bytes = found.reader.bytes(found.range), bytes.count == found.range.count else {
            throw AgentToolError("The bytes of node \(text) could not be read.")
        }
        let image = Data(bytes)
        guard TEImageSignature.isImage(image) else {
            throw AgentToolError("Node \(text) is not a PE32 or TE image: `uefi_find` with name \"PE32 image\" "
                + "or \"TE image\" lists those.")
        }
        let label = UEFIAgentQueries.label(of: found.node, in: found.tree)
        let file = label.components(separatedBy: " in ").last ?? label
        let name = String(file.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
                ? Character($0) : "-"
        })
        return (image, name.isEmpty ? "module" : name, document)
    }
}

/// Whether bytes start as an image Ghidra can be given.
public enum TEImageSignature {
    public static func isImage(_ data: Data) -> Bool {
        data.count > 2 && (data.prefix(2) == Data("MZ".utf8) || data.prefix(2) == Data("VZ".utf8))
    }
}
