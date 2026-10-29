import AgentKit
import CodeAnalysis
import Foundation
import GhidraHost
import UEFITool
import UEFIToolUI

/// The review tools of Ghidra on the app's own MCP server
/// (`Design/SERVER_PLAN.md` §6.4): the list `byteripper-server` serves at
/// `/mcp`, relayed to the server Settings ▸ Code Analysis names, so an agent
/// goes from a UEFI node to a rename on one connection. `ghidra_open` here
/// takes a node of an open dump and sends its bytes; the server alone takes
/// them as base64.
///
/// The list is fixed while the app runs, like every list here; which host
/// answers is decided at each call, so a change of the setting needs no
/// restart: an analysis server when the setting names one, and — with the
/// analyses on this Mac — a `GhidraHost` in this process, over the same
/// `GhidraProjects` folder and publishing into the local store.
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
                `name: "PE32 image"` or `"TE image"` lists them) and its `document`: its bytes go to \
                Ghidra, whose project is made the first time — seconds for a PEIM, a minute for a large \
                DXE driver. A module seen before opens by `module`, the SHA-256 the answer gives. Ghidra is \
                the analysis server's when Settings ▸ Code Analysis names one, and this Mac's own \
                otherwise. Then read, rename, type and comment with the other `ghidra_` tools and \
                `ghidra_publish`: every ByteRipper reading shows the result. A review aims at C that reads \
                like source — enums for constants, structures for pointer walks, comments a source would \
                have; the MCP instructions spell the rules out.
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

/// The host the setting names, at the moment of each call: a
/// `byteripper-server`'s Ghidra role over the network, or the same
/// `GhidraHost` running inside this app when the analyses are on this Mac.
struct CurrentGhidraBackend: GhidraBackend {
    private func resolve() async throws -> GhidraBackend {
        let choice = await MainActor.run {
            () -> (mode: CodeAnalysisLocation.Mode, url: URL?, token: String?, storeRoot: URL) in
            let location = CodeAnalysisLocation.shared
            // The store every other reader uses: the local folder, or what a
            // test pointed the tree at. In local mode it is the same folder.
            return (location.mode, CodeAnalysisLocation.serverURL(location.serverAddress),
                    try? location.readToken(), UEFIToolModule.codeAnalysisRoot ?? location.localRoot)
        }
        switch choice.mode {
        case .server:
            guard let url = choice.url else {
                throw GhidraHostError(.install, "The analysis server's address is not of the form "
                    + "http://host:port: set it in Settings ▸ Code Analysis, or choose On this Mac.")
            }
            return GhidraRemote(base: url, token: choice.token)
        case .thisMac:
            return try await LocalGhidraHost.shared.backend(storeRoot: choice.storeRoot)
        }
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

/// The Ghidra host running inside the app when the analyses are on this Mac:
/// the same `GhidraHost` a `byteripper-server` runs, reached through the same
/// `GhidraBackend`, with no process and no port between them.
///
/// One host for the app's life, because it holds each module's owner and the
/// lease a review keeps between calls. Its projects are the
/// `GhidraProjects` folder a server on this Mac uses — the same projects, the
/// same Ghidra — and what it publishes goes into the local store, whose
/// FSEvents the app already follows.
actor LocalGhidraHost {
    static let shared = LocalGhidraHost()
    private var host: GhidraHost?
    private var storeRoot: URL?

    func backend(storeRoot root: URL) throws -> GhidraHost {
        if let host, storeRoot == root { return host }
        let store: ContentStore
        do {
            store = try ContentStore(root: root)
        } catch {
            throw GhidraHostError(.install, "The local store at \(root.path) could not be opened: \(error)")
        }
        let host = GhidraHost(
            configuration: .init(projectsRoot: GhidraHost.defaultProjectsRoot,
                                 holder: "\(NSUserName()) via ByteRipper"),
            writer: store)
        self.host = host
        self.storeRoot = root
        return host
    }
}
