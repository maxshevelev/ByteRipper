import AgentKit
import CodeAnalysis
import Foundation
import GhidraHost
import UEFITool

/// The review tools of Ghidra on the app's own MCP server
/// (`Design/SERVER_PLAN.md` §6.4): the list `byteripper-server` serves at
/// `/mcp`, relayed to the server Settings ▸ Code Analysis names, so an agent
/// goes from a UEFI node to a rename on one connection. `ghidra_open` here
/// takes a node of an open dump and sends its bytes; the server alone takes
/// them as base64.
///
/// The list is fixed while the app runs, like every list here; which host
/// answers is decided at each call, so a change of the setting needs no
/// restart. With the analyses on this Mac there is no host yet — the call
/// says so.
@MainActor
final class AgentGhidraTools {
    private let desk: AgentDesk

    init(desk: AgentDesk) {
        self.desk = desk
    }

    nonisolated func tools() -> [AgentTool] {
        let backend = CurrentGhidraBackend()
        let shared = GhidraTools.tools(backend: backend, includeOpenByImage: false)
        return shared.map { $0.name == "ghidra_open" ? openTool(backend) : $0 }
    }

    /// `ghidra_open` by a node of an open dump, or by `module` for one with a
    /// project already.
    private nonisolated func openTool(_ backend: CurrentGhidraBackend) -> AgentTool {
        AgentTool(
            name: "ghidra_open",
            title: "Open a module in Ghidra",
            description: """
                Opens a module for a review in Ghidra and answers its owner's `hello`: program, functions, \
                unpublished changes. Give the PE32/TE image `node` of a dump (`uefi_find` with \
                `name: "PE32 image"` or `"TE image"` lists them) and its `document`: its bytes go to the \
                analysis server, whose project is made the first time — seconds for a PEIM, a minute for a \
                large DXE driver. A module seen before opens by `module`, the SHA-256 the answer gives. \
                Needs an analysis server in Settings ▸ Code Analysis. Then read, rename, type and comment \
                with the other `ghidra_` tools and `ghidra_publish`: every ByteRipper reading that server \
                shows the result. A review aims at C that reads like source — enums for constants, \
                structures for pointer walks, comments a source would have; the server's own MCP \
                instructions spell the rules out.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The dump the node is in. Default: the focused one."),
                "node": AgentSchema.string("The PE32 or TE image node, e.g. \"0.6.4.0.0.199.3\"."),
                "name": AgentSchema.string("What to call the module. Default: the file it is in."),
                "module": AgentSchema.string("Or a module already opened, by its SHA-256.")
            ]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: true)
        ) { call in
            let arguments = call.arguments
            if let node = try arguments.optionalString("node") {
                let (image, name, document) = try await self.image(node: node, document: try arguments.optionalString("document"))
                let chosen = try arguments.optionalString("name") ?? name
                return try await GhidraTools.answer {
                    try await backend.openImage(image, name: chosen, document: document, node: node)
                }
            }
            return try await GhidraTools.answer {
                try await backend.openModule(try GhidraTools.module(arguments))
            }
        }
    }

    /// The node's image bytes, a name for the module — the file it is in —
    /// and the dump's name.
    private func image(node text: String, document: String?) async throws -> (Data, String, String) {
        let place: AgentDesk.Place
        do {
            place = try desk.place(named: document)
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let found = try await UEFIAgentNodeData.bytes(host, node: text, part: .body)
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
        return (image, name.isEmpty ? "module" : name, place.label.isEmpty ? place.id : place.label)
    }
}

/// Whether bytes start as an image Ghidra can be given.
enum TEImageSignature {
    static func isImage(_ data: Data) -> Bool {
        data.count > 2 && (data.prefix(2) == Data("MZ".utf8) || data.prefix(2) == Data("VZ".utf8))
    }
}

/// The host the setting names, at the moment of each call.
struct CurrentGhidraBackend: GhidraBackend {
    private func resolve() async throws -> GhidraBackend {
        let server = await MainActor.run { () -> (URL, String?)? in
            let location = CodeAnalysisLocation.shared
            guard location.mode == .server, let url = CodeAnalysisLocation.serverURL(location.serverAddress) else {
                return nil
            }
            return (url, try? location.readToken())
        }
        guard let (url, token) = server else {
            throw GhidraHostError(.install, "Ghidra is reached through an analysis server, and none is set: "
                + "the person chooses one in Settings ▸ Code Analysis.")
        }
        return GhidraRemote(base: url, token: token)
    }

    func listModules() async throws -> Data { try await resolve().listModules() }
    func openImage(_ image: Data, name: String, document: String?, node: String?) async throws -> Data {
        try await resolve().openImage(image, name: name, document: document, node: node)
    }
    func openModule(_ module: SHA256Digest) async throws -> Data { try await resolve().openModule(module) }
    func readCall(_ module: SHA256Digest, _ call: String, query: [String: String]) async throws -> Data {
        try await resolve().readCall(module, call, query: query)
    }
    func writeCall(_ module: SHA256Digest, _ call: String, body: Data) async throws -> Data {
        try await resolve().writeCall(module, call, body: body)
    }
    func publishModule(_ module: SHA256Digest, by: String) async throws -> Data {
        try await resolve().publishModule(module, by: by)
    }
    func releaseModule(_ module: SHA256Digest, by: String) async throws -> Data {
        try await resolve().releaseModule(module, by: by)
    }
}
