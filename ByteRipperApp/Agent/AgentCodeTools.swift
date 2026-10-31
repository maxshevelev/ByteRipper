import AgentDocuments
import AgentKit
import CodeAnalysis
import CodeView
import Foundation
import UEFIImage
import UEFITool
import UEFIToolUI

/// A module's stored code analysis, as an agent's questions
/// (`Design/CODE_PANEL_PLAN.md`, stage 5): what to read, which modules of a
/// dump have one, and a Code panel opened where the agent is pointing.
///
/// The analysis is read from the local store, keyed by the module's bytes —
/// a Code panel need not be open. The same typed artifact the panel reads: no
/// second parse, and no Ghidra on the agent's side.
@MainActor
final class AgentCodeTools {
    private let desk: AgentDesk
    /// `code_query` and `code_modules`, shared with `byteripper-server`
    /// (`Packages/AgentDocuments`); the app adds its Code panels as
    /// documents of their own, and the words that name them.
    let readings: CodeReadings

    init(desk: AgentDesk) {
        self.desk = desk
        readings = CodeReadings(
            documents: desk, wording: Self.wording,
            store: { CodeAnalysisStore.root },
            catalogue: { await UEFIToolModule.agentCatalogue() },
            screen: { document in
                guard let place = document as? AgentDesk.Place,
                      let screen = place.controller?.codeScreen(for: place.pane) else { return nil }
                return CodeReadings.Source(manifest: screen.manifest, artifact: screen.artifact, bytes: screen.bytes,
                                           document: place.id, node: nil)
            })
    }

    nonisolated func tools() -> [AgentTool] { readings.tools() + [openTool] }

    private nonisolated static let wording = CodeReadings.Wording(
        query: """
            Read a module's stored code analysis. The module is the Code panel or tab given as \
            `document`; or a PE32/TE image `node` of a dump (`code_modules` lists the ones with an \
            analysis), its bytes hashed to find the analysis; or a `module` SHA-256, read from the store \
            alone. No panel needs to be open. `what` picks the list (default "functions"): \
            "functions"; one function's "instructions" or decompiled "c"; a function's callers and \
            callees ("references"); the instructions that "uses" an address — who calls a function, \
            jumps to a label, or reads a global or a string; "strings"; "symbols", the named data — \
            GUIDs, service tables, interfaces; or "post_codes", the values written to port 0x80 (what a \
            POST card shows), each at the call that supplies it, with the functions it passes through \
            (`via`) — `search` narrows by value — and, last, the writes whose value or port the code does \
            not say (`unresolved`). A function's `name_source` says where its name came \
            from: DEFAULT is Ghidra's FUN_ placeholder, ANALYSIS a name the UEFI pass read from the \
            module (`name_reason` says from what), IMPORTED the image's own. `review_level` is how far the review has got — full, partial, \
            decompiled, library or no_body; null in an analysis made before it was recorded — and \
            `review_gaps` what keeps it from full: name, plate, comments, params, locals; a library \
            function's `library_kind` whose library it is — edk2, amd (AGESA) or intel (FSP/RC). Addresses come twice: \
            `entry`/`address` is Ghidra's virtual address, `offset` the same byte's offset in the \
            module, the number the hex view shows (none when read by `module` alone). To show the \
            person a function, `open_code`; to leave a note on it, `annotate` with `function`. These \
            are stored observations, not a live disassembly; the C is Ghidra's reading of the \
            instructions, not the source.
            """,
        modules: """
            The PE32/TE modules of a dump that have a stored code analysis: their image `node`, name, \
            the analyses (`recipes`, newest first) and how many functions the newest found. The modules \
            are found by their bytes — the same module in another dump has the same analysis — \
            including those inside compressed sections, which are opened for it: seconds on a large \
            image the first time. Read one with `code_query`, show it with `open_code`.
            """,
        queryDocument: "A Code panel or tab, or the dump the module is in. Default: the focused one.",
        modulesDocument: "The dump. Default: the focused one.",
        missingNode: { named in
            "\(named) is not a Code panel. Give the module's image `node` in it — "
                + "`code_modules` lists the ones with an analysis — or a `module` SHA-256."
        })

    private nonisolated var openTool: AgentTool {
        AgentTool(
            name: "open_code",
            title: "Open a module's code",
            description: """
                Opens the Code panel of a module — its functions, ASM and C beside its bytes — over the \
                dump, at a `function` or an instruction `address` when given, and brings it forward: what \
                the person's Open with Code does. Give the dump `document` and the image `node` \
                (`code_modules`), or a Code panel as `document` to move it to another place. `view` \
                chooses the side the reader lands on: `c` for the decompiled listing, `asm` for the \
                assembly. A panel of the same module already open is raised rather than opened twice. \
                Answers the panel's `document` id, which `code_query` reads.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The dump, or a Code panel. Default: the focused one."),
                "node": AgentSchema.string("The module's PE32/TE image node in the dump."),
                "function": AgentSchema.string("A function name or Ghidra entry address to open at."),
                "address": AgentSchema.string("Or an instruction's Ghidra address to open at."),
                "view": AgentSchema.string("Which side to show: \"c\" for the decompiled listing, "
                    + "\"asm\" for the assembly. Default: the panel keeps the side it has.")
            ]),
            annotations: AgentTool.Annotations(readOnly: false, idempotent: true)
        ) { call in
            try await self.open(call.arguments)
        }
    }

    /// The analysis a call is about: `CodeReadings.source`, which
    /// `annotate` on code reads too.
    func source(_ arguments: AgentArguments) async throws -> CodeReadings.Source {
        try await readings.source(arguments)
    }

    /// The image node in `tree` whose bytes are the module `manifest` was
    /// made from.
    func imageNode(of manifest: AnalysisManifest, in tree: LazyUEFITree, fileName: String) async -> NodeID? {
        await readings.imageNode(of: manifest, in: tree, fileName: fileName)
    }

    private func place(_ arguments: AgentArguments) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: try arguments.optionalString("document"))
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }

    // MARK: - open_code

    private func open(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try place(arguments)
        let controller = try place.onScreen()
        let showingC = try wantedC(arguments)
        // A Code panel already: move it.
        if let screen = controller.codeScreen(for: place.pane), let view = controller.codePaneView(for: place.pane) {
            if let location = try location(arguments, in: screen.artifact) { view.go(to: location) }
            if let showingC { view.showDecompiledC(showingC) }
            desk.bringForward(place)
            var answer = openAnswer(place.id, manifest: screen.manifest, view: view)
            answer["view"] = .string(view.showsDecompiledC ? "c" : "asm")
            return .json(.object(answer))
        }
        guard let node = try arguments.optionalString("node") else {
            throw AgentToolError("Give the module's image `node` in \(place.named) — `code_modules` lists them — "
                + "or a Code panel as `document`.")
        }
        let opening = try await readings.opening(node, in: place)
        let location = try location(arguments, in: opening.artifact)
        desk.bringForward(place)
        controller.view.window?.makeKeyAndOrderFront(nil)
        guard let panel = controller.openCode(named: opening.partName, from: place.pane, source: opening.source,
                                              manifest: opening.manifest, artifact: opening.artifact,
                                              recipes: opening.recipes, codec: opening.codec, at: location),
              let pane = controller.fragments.pane(panel),
              let opened = desk.places().first(where: { $0.pane === pane })
        else { throw AgentToolError("The Code panel could not be opened over \(place.named).") }
        let openedView = controller.fragments.codePane(panel)
        if let showingC { openedView?.showDecompiledC(showingC) }
        var answer = openAnswer(opened.id, manifest: opening.manifest, view: openedView)
        answer["node"] = .string(node)
        if let openedView { answer["view"] = .string(openedView.showsDecompiledC ? "c" : "asm") }
        return .json(.object(answer))
    }

    /// `view` as `true` for the decompiled C side, `false` for the assembly;
    /// nil when the call does not name one and the panel keeps its own.
    private func wantedC(_ arguments: AgentArguments) throws -> Bool? {
        guard let text = try arguments.optionalString("view") else { return nil }
        switch text.lowercased() {
        case "c": return true
        case "asm": return false
        default: throw AgentToolError("`view` is \"c\" or \"asm\", not \"\(text)\".")
        }
    }

    private func openAnswer(_ document: String, manifest: AnalysisManifest, view: CodePaneView?) -> [String: JSONValue] {
        var answer: [String: JSONValue] = [
            "document": .string(document),
            "module": .string(manifest.module.name),
            "recipe": .string(manifest.recipe.id)
        ]
        if let function = view?.selectedFunction {
            answer["function"] = .string(function.name)
            answer["entry"] = .string(function.entry.description)
        }
        if let instruction = view?.selectedInstruction { answer["address"] = .string(instruction.address.description) }
        return answer
    }

    /// The place `function` or `address` names in `artifact`; nil when
    /// neither is given. An unknown one is refused, not skipped.
    func location(_ arguments: AgentArguments, in artifact: CodeArtifact) throws -> CodeLocation? {
        var location = CodeLocation()
        if let name = try arguments.optionalString("function") {
            guard let function = artifact.function(named: name) else {
                throw AgentToolError("No function \"\(name)\" in this analysis. `code_query` lists them.")
            }
            location.function = function.entry
        }
        if let text = try arguments.optionalString("address") {
            guard let address = CodeAddress(hex: text), let function = artifact.function(containing: address) else {
                throw AgentToolError("No instruction at \(text) in this analysis: give an address `code_query` "
                    + "lists under \"instructions\".")
            }
            if let entry = location.function, entry != function.entry {
                throw AgentToolError("\(text) is in \(function.name), not in the function given.")
            }
            location.address = address
        }
        return location.isEmpty ? nil : location
    }
}
