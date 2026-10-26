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

    init(desk: AgentDesk) {
        self.desk = desk
    }

    nonisolated func tools() -> [AgentTool] { [queryTool, modulesTool, openTool] }

    private static let lists = ["functions", "instructions", "c", "uses", "strings", "symbols", "references",
                                "post_codes"]

    private nonisolated static let whereProperties: [String: JSONValue] = [
        "document": AgentSchema.string("A Code panel or tab, or the dump the module is in. Default: the focused one."),
        "node": AgentSchema.string("The module's PE32/TE image node in the dump, e.g. \"0.6.4.0.0.205.2\" — from `code_modules`."),
        "module": AgentSchema.string("Or the module by its bytes' SHA-256, read from the store without a dump."),
        "recipe": AgentSchema.string("With `module`: which analysis, when there are several. Default: the newest.")
    ]

    private nonisolated var queryTool: AgentTool {
        var properties = Self.whereProperties
        properties["what"] = AgentSchema.choice(Self.lists, "The list to read. Default \"functions\".")
        properties["function"] = AgentSchema.string(
            "A function name or Ghidra entry address, for \"instructions\", \"c\" and \"references\".")
        properties["address"] = AgentSchema.string("A Ghidra address, for \"uses\".")
        properties["search"] = AgentSchema.string("A word to narrow functions, strings or symbols by.")
        properties["limit"] = AgentSchema.limit(default: 200, maximum: 500)
        return AgentTool(
            name: "code_query",
            title: "Read a module's code analysis",
            description: """
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
                module (`name_reason` says from what), IMPORTED the image's own. Addresses come twice: \
                `entry`/`address` is Ghidra's virtual address, `offset` the same byte's offset in the \
                module, the number the hex view shows (none when read by `module` alone). To show the \
                person a function, `open_code`; to leave a note on it, `annotate` with `function`. These \
                are stored observations, not a live disassembly; the C is Ghidra's reading of the \
                instructions, not the source.
                """,
            inputSchema: AgentSchema.object(properties)
        ) { call in
            try await self.answer(call.arguments)
        }
    }

    private nonisolated var modulesTool: AgentTool {
        AgentTool(
            name: "code_modules",
            title: "List a dump's analyzed modules",
            description: """
                The PE32/TE modules of a dump that have a stored code analysis: their image `node`, name, \
                the analyses (`recipes`, newest first) and how many functions the newest found. The modules \
                are found by their bytes — the same module in another dump has the same analysis — \
                including those inside compressed sections, which are opened for it: seconds on a large \
                image the first time. Read one with `code_query`, show it with `open_code`.
                """,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string("The dump. Default: the focused one.")
            ])
        ) { call in
            try await self.modules(call.arguments)
        }
    }

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

    // MARK: - Which analysis

    /// The analysis a call is about, and where it was found.
    struct Source {
        let manifest: AnalysisManifest
        let artifact: CodeArtifact
        /// The module's bytes, for module offsets; nil when read by SHA alone.
        let bytes: Data?
        /// The Code panel, or the dump, the agent named; nil for `module`.
        let document: String?
        let node: String?
    }

    /// A Code panel or tab; else an image node of a dump; else a module SHA
    /// read from the store alone.
    func source(_ arguments: AgentArguments) async throws -> Source {
        if let text = try arguments.optionalString("module") {
            guard let digest = SHA256Digest(hex: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AgentToolError("`module` is a SHA-256 of the module's bytes: 64 hex digits.")
            }
            let recipe = try arguments.optionalString("recipe")
            let root = CodeAnalysisStore.root
            let loaded = await Task.detached(priority: .userInitiated) { () -> (AnalysisManifest, CodeArtifact)? in
                let index = CodeAnalysisIndex.load(from: root)
                let manifests = index.manifests(for: digest)
                guard let manifest = recipe.map({ id in manifests.first { $0.recipe.id == id } })
                        ?? index.newest(for: digest),
                      let artifact = try? ContentStore(root: root, create: false).artifact(for: manifest)
                else { return nil }
                return (manifest, artifact)
            }.value
            guard let (manifest, artifact) = loaded else {
                throw AgentToolError("The store has no readable analysis of module \(digest.hex)"
                    + (recipe.map { " with recipe \($0)" } ?? "") + ".")
            }
            return Source(manifest: manifest, artifact: artifact, bytes: nil, document: nil, node: nil)
        }
        let place = try place(arguments)
        if let screen = place.controller?.codeScreen(for: place.pane) {
            return Source(manifest: screen.manifest, artifact: screen.artifact, bytes: screen.bytes,
                          document: place.id, node: nil)
        }
        guard let node = try arguments.optionalString("node") else {
            throw AgentToolError("\(place.named) is not a Code panel. Give the module's image `node` in it — "
                + "`code_modules` lists the ones with an analysis — or a `module` SHA-256.")
        }
        let opening = try await opening(node, in: place)
        return Source(manifest: opening.manifest, artifact: opening.artifact, bytes: Data(opening.bytes),
                      document: place.id, node: node)
    }

    /// Node `text` of `place`'s tree, read and matched with the store.
    private func opening(_ text: String, in place: AgentDesk.Place) async throws -> UEFICodeOpening {
        let id = try UEFIAgentQueries.nodeID(text)
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let tree = try await UEFIAgentQueries.readyTree(host)
        guard await UEFIAgentQueries.reachable(id, in: tree) else {
            throw AgentToolError("\(place.named) has no node \(text).")
        }
        do {
            return try await UEFICodeOpening.prepare(node: id, in: tree, store: CodeAnalysisStore.root)
        } catch let failure as UEFICodeOpening.Failure {
            switch failure {
            case .noAnalysis:
                throw AgentToolError("Node \(text) of \(place.named) is not a PE32/TE image with a stored code "
                    + "analysis. `code_modules` lists the ones that are; the ghidra-uefi skill makes one.")
            default:
                throw AgentToolError(failure.message)
            }
        }
    }

    /// The image node in `tree` whose bytes are the module `manifest` was
    /// made from: the node the analysis names first, when this is its file,
    /// then every node the tree has open, then — the last resort — the tree
    /// with every compressed section opened.
    func imageNode(of manifest: AnalysisManifest, in tree: LazyUEFITree, fileName: String) async -> NodeID? {
        let index = CodeAnalysisIndex(manifests: [manifest])
        for id in UEFICodeScan.sourceNodeIDs(in: index, document: fileName) {
            _ = await UEFIAgentQueries.reachable(id, in: tree)
        }
        for pass in 0..<2 {
            if pass == 1 { await UEFIContentSearch.openEverything(under: nil, in: tree) }
            let image = tree.image()
            let readers = tree.spaceReaders
            let found = await Task.detached(priority: .userInitiated) {
                UEFICodeScan.scan(in: image, index: index) { node in
                    guard let reader = readers.reader(for: node.space), let bytes = reader.bytes(node.body)
                    else { return nil }
                    return Data(bytes)
                }
            }.value
            if let id = found.keys.min(by: { $0.path.lexicographicallyPrecedes($1.path) }) { return id }
        }
        return nil
    }

    private func place(_ arguments: AgentArguments) throws -> AgentDesk.Place {
        do {
            return try desk.place(named: try arguments.optionalString("document"))
        } catch let error as AgentDeskError {
            throw AgentToolError(error.description)
        }
    }

    // MARK: - code_query

    private func answer(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let source = try await source(arguments)
        let what = try arguments.choice("what", from: Self.lists, default: "functions")
        let search = (try arguments.optionalString("search"))?.lowercased()
        let limit = try arguments.limit(default: 200, maximum: 500)
        let model = CodeModel(artifact: source.artifact, moduleBytes: source.bytes)

        func offsetText(_ address: CodeAddress) -> JSONValue {
            guard let offset = model.moduleOffset(of: address) else { return .null }
            return .string("0x" + String(offset, radix: 16, uppercase: true))
        }
        func reference(_ address: CodeAddress) -> JSONValue {
            var members: [String: JSONValue] = [
                "entry": .string(address.description),
                "offset": offsetText(address)
            ]
            if let index = model.function(at: address), !model.functions[index].name.isEmpty {
                members["name"] = .string(model.functions[index].name)
            }
            return .object(members)
        }
        func namedFunction() throws -> CodeArtifact.Function {
            guard let name = try arguments.optionalString("function") else {
                throw AgentToolError("Argument `function` is required for this `what`.")
            }
            guard let index = model.function(named: name) else {
                throw AgentToolError("No function \"\(name)\" in this analysis.")
            }
            return model.functions[index]
        }

        var body: [String: JSONValue] = [
            "what": .string(what),
            "module": .string(source.manifest.module.name),
            "sha256": .string(source.manifest.module.sha256.hex),
            "recipe": .string(source.manifest.recipe.id)
        ]
        if let document = source.document { body["document"] = .string(document) }
        if let node = source.node { body["node"] = .string(node) }

        switch what {
        case "functions":
            let functions = model.functions(matching: search ?? "").map { model.functions[$0] }
            body["total"] = .int(Int64(functions.count))
            body["functions"] = .array(functions.prefix(limit).map { function in
                .object([
                    "name": .string(function.name),
                    "entry": .string(function.entry.description),
                    "offset": offsetText(function.entry),
                    "size": function.size.map { JSONValue.int(Int64($0)) } ?? JSONValue.null,
                    "external": .bool(function.external),
                    "thunk": .bool(function.thunk),
                    "signature": function.signature.map(JSONValue.string) ?? .null,
                    "name_source": function.nameSource.map(JSONValue.string) ?? .null,
                    "name_reason": function.nameReason.map(JSONValue.string) ?? .null,
                    "callers": .array(function.callers.map { .string($0.description) }),
                    "callees": .array(function.callees.map { .string($0.description) })
                ])
            })

        case "instructions":
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["total"] = .int(Int64(function.instructions.count))
            body["instructions"] = .array(function.instructions.prefix(limit).map { instruction in
                .object([
                    "address": .string(instruction.address.description),
                    "offset": offsetText(instruction.address),
                    "bytes": .string(instruction.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")),
                    "mnemonic": instruction.mnemonic.map(JSONValue.string) ?? .null,
                    "text": .string(instruction.text),
                    "references": .array(instruction.references.map {
                        .object(["to": .string($0.to.description), "type": .string($0.type)])
                    })
                ])
            })

        case "c":
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["entry"] = .string(function.entry.description)
            body["signature"] = function.signature.map(JSONValue.string) ?? .null
            body["c"] = function.c.map(JSONValue.string) ?? .null
            if function.c == nil {
                body["note"] = .string("Ghidra left no C for this function: it is external, a thunk, or did not decompile.")
            }

        case "uses":
            guard let text = try arguments.optionalString("address"),
                  let address = CodeAddress(hex: text) else {
                throw AgentToolError("Argument `address` is required for \"uses\": a Ghidra address such as 0x4BF.")
            }
            let uses = model.uses(of: address)
            body["address"] = .string(address.description)
            body["offset"] = offsetText(address)
            body["total"] = .int(Int64(uses.count))
            body["uses"] = .array(uses.prefix(limit).map { use in
                .object([
                    "from": .string(use.from.description),
                    "offset": offsetText(use.from),
                    "type": .string(use.type),
                    "function": .string(model.functions[use.function].name),
                    "text": .string(model.lines[use.line].instruction.text)
                ])
            })

        case "symbols":
            let symbols = source.artifact.symbols.filter { symbol in
                guard let search, !search.isEmpty else { return true }
                return symbol.name.lowercased().contains(search)
                    || (symbol.type?.lowercased().contains(search) ?? false)
            }
            body["total"] = .int(Int64(symbols.count))
            body["symbols"] = .array(symbols.prefix(limit).map { symbol in
                .object([
                    "address": .string(symbol.address.description),
                    "offset": offsetText(symbol.address),
                    "name": .string(symbol.name),
                    "type": symbol.type.map(JSONValue.string) ?? .null,
                    "source": symbol.source.map(JSONValue.string) ?? .null,
                    "reason": symbol.reason.map(JSONValue.string) ?? .null
                ])
            })

        case "strings":
            let strings = source.artifact.strings.filter { entry in
                guard let search, !search.isEmpty else { return true }
                return entry.value.lowercased().contains(search)
                    || entry.type.lowercased().contains(search)
                    || entry.address.description.lowercased().contains(search)
            }
            body["total"] = .int(Int64(strings.count))
            body["strings"] = .array(strings.prefix(limit).map { entry in
                .object([
                    "address": .string(entry.address.description),
                    "offset": offsetText(entry.address),
                    "type": .string(entry.type),
                    "value": .string(entry.value)
                ])
            })

        case "post_codes":
            // By value, the places that send one together, what could not
            // be told last — as the panel's POST list shows them.
            let wanted = search.flatMap { UInt64($0.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }
            let codes = source.artifact.postCodes
                .filter { wanted == nil || $0.value == wanted }
                .sorted { ($0.value ?? .max, $0.address.value) < ($1.value ?? .max, $1.address.value) }
            body["total"] = .int(Int64(codes.count))
            body["post_codes"] = .array(codes.prefix(limit).map { code in
                var entry: [String: JSONValue] = [
                    "address": .string(code.address.description),
                    "offset": offsetText(code.address),
                    "function": code.function.flatMap(model.function(at:)).map { .string(model.functions[$0].name) } ?? .null,
                    "port": .string(code.port),
                    "value": code.value.map { .string(String(format: "0x%llX", $0)) } ?? .null,
                    "via": .array(code.via.map { .string($0.name ?? $0.function.description) }),
                    "text": .string(code.text)
                ]
                if let width = code.width { entry["width"] = .int(Int64(width)) }
                if let unresolved = code.unresolved { entry["unresolved"] = .string(unresolved.rawValue) }
                return .object(entry)
            })

        default:
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["callers"] = .array(function.callers.map(reference))
            body["callees"] = .array(function.callees.map(reference))
        }
        return .json(.object(body))
    }

    // MARK: - code_modules

    private func modules(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let place = try place(arguments)
        let host = PaneToolHost(pane: place.pane, owner: place.controller, tools: nil)
        let tree = try await UEFIAgentQueries.readyTree(host)
        let root = CodeAnalysisStore.root
        let index = await Task.detached(priority: .userInitiated) { CodeAnalysisIndex.load(from: root) }.value
        var body: [String: JSONValue] = ["document": .string(place.id)]
        guard !index.isEmpty else {
            body["modules"] = .array([])
            body["note"] = .string("The code store holds no analyses; the ghidra-uefi skill makes them.")
            return .json(.object(body))
        }
        // Every branch, compressed ones too: a module is wherever its bytes
        // are, and the tree reads lazily. What is opened stays open for the
        // panel; the bytes' hash decides which node is which module.
        await UEFIContentSearch.openEverything(under: nil, in: tree)
        let image = tree.image()
        let readers = tree.spaceReaders
        let found = await Task.detached(priority: .userInitiated) {
            UEFICodeScan.scan(in: image, index: index) { node in
                guard let reader = readers.reader(for: node.space), let bytes = reader.bytes(node.body)
                else { return nil }
                return Data(bytes)
            }
        }.value
        let catalogue = await UEFIToolModule.agentCatalogue()
        let rows: [JSONValue] = found.keys.sorted { $0.path.lexicographicallyPrecedes($1.path) }.map { id in
            let manifest = found[id]!
            let recipes = index.manifests(for: manifest.module.sha256)
                .sorted { $0.analyzedAt > $1.analyzedAt }
            var row: [String: JSONValue] = [
                "node": .string(id.description),
                "module": .string(manifest.module.name),
                "sha256": .string(manifest.module.sha256.hex),
                "recipes": .array(recipes.map { .string($0.recipe.id) }),
                "functions": .int(Int64(manifest.stats.functions))
            ]
            if let label = UEFITreeDisplay.nameAfterParent(of: id, in: tree, catalogue: catalogue,
                                                           image: image, in: .english) {
                row["label"] = .string(label)
            }
            if let node = image.node(id), node.space != .file { row["in_compressed"] = .bool(true) }
            return .object(row)
        }
        body["modules"] = .array(rows)
        if rows.isEmpty {
            body["note"] = .string("No PE32/TE module of this dump matches a stored analysis. "
                + "The ghidra-uefi skill makes one.")
        }
        return .json(.object(body))
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
        let opening = try await opening(node, in: place)
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
