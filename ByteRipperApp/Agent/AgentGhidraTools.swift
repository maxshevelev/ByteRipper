import AgentDocuments
import AgentKit
import CodeAnalysis
import Foundation
import GhidraHost
import UEFITool
import UEFIToolUI

/// The review tools of Ghidra on the app's own MCP server
/// (`Design/SERVER_PLAN.md` §6.4), relayed to the server Settings ▸ Code
/// Analysis names, so an agent goes from a UEFI node to a rename on one
/// connection. `ghidra_open` takes a node of an open dump and sends its
/// bytes — `GhidraNodeOpen`, which `byteripper-server` serves too
/// (`Packages/AgentDocuments`).
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
        GhidraNodeOpen.tools(backend: CurrentGhidraBackend(), documents: desk,
                             description: Self.openDescription,
                             document: "The dump the node is in. Default: the focused one.")
    }

    /// `ghidra_open` by a node, in the app's words: Ghidra is the analysis
    /// server's or this Mac's, by the setting.
    private nonisolated static let openDescription = """
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
            """
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
