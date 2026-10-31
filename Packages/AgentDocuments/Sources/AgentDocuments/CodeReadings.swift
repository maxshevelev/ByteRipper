import AgentKit
import CodeAnalysis
import Foundation
import UEFIImage
import UEFITool

/// A module's stored code analysis, as an agent's questions
/// (`Design/CODE_PANEL_PLAN.md`, stage 5): `code_query` reads one, and
/// `code_modules` says which modules of a dump have one
/// (`Design/SERVER_HEADLESS_PLAN.md` §4.1).
///
/// The analysis is read from the store, keyed by the module's bytes — no
/// panel need be open. The same typed artifact the Code panel reads: no
/// second parse, and no Ghidra on the agent's side. What each host adds is
/// its own: the app's Code panel as a document of its own (`screen`), and the
/// words of the tools, which name the app's panels or none.
@MainActor
public final class CodeReadings {
    /// What the tools say: the app's name its panels and `open_code`, the
    /// server's name none.
    public struct Wording: Sendable {
        public var query: String
        public var modules: String
        /// The `document` argument of `code_query`.
        public var queryDocument: String
        /// The `document` argument of `code_modules`.
        public var modulesDocument: String
        /// The refusal of a document given without a `node`, by its name.
        public var missingNode: @Sendable (String) -> String

        public init(query: String, modules: String, queryDocument: String, modulesDocument: String,
                    missingNode: @escaping @Sendable (String) -> String) {
            self.query = query
            self.modules = modules
            self.queryDocument = queryDocument
            self.modulesDocument = modulesDocument
            self.missingNode = missingNode
        }
    }

    /// The analysis a call is about, and where it was found.
    public struct Source {
        public let manifest: AnalysisManifest
        public let artifact: CodeArtifact
        /// The module's bytes, for module offsets; nil when read by SHA alone.
        public let bytes: Data?
        /// The document the agent named; nil for `module`.
        public let document: String?
        public let node: String?
        /// The document's `disk` mark, when it has one (`AgentDocument.disk`).
        public let disk: String?

        public init(manifest: AnalysisManifest, artifact: CodeArtifact, bytes: Data?, document: String?,
                    node: String?, disk: String? = nil) {
            self.manifest = manifest
            self.artifact = artifact
            self.bytes = bytes
            self.document = document
            self.node = node
            self.disk = disk
        }
    }

    private let documents: any AgentDocumentSet
    private let wording: Wording
    /// The store's root at the moment of a call: the app's follows its
    /// setting.
    private let store: @MainActor () -> URL
    /// The GUID catalogue, for the name of a module's file.
    private let catalogue: @Sendable () async -> GuidsCatalogue
    /// A document that is itself a module's code — the app's Code panel —
    /// read as it is; nil for a document that is a dump.
    private let screen: @MainActor (any AgentDocument) -> Source?

    public init(documents: any AgentDocumentSet, wording: Wording,
                store: @escaping @MainActor () -> URL,
                catalogue: @escaping @Sendable () async -> GuidsCatalogue,
                screen: @escaping @MainActor (any AgentDocument) -> Source? = { _ in nil }) {
        self.documents = documents
        self.wording = wording
        self.store = store
        self.catalogue = catalogue
        self.screen = screen
    }

    /// `code_query`, then `code_modules`.
    public nonisolated func tools() -> [AgentTool] { [queryTool, modulesTool] }

    nonisolated static let lists = ["functions", "instructions", "c", "uses", "strings", "symbols", "references",
                                "post_codes"]

    nonisolated static let whereProperties: [String: JSONValue] = [
        "node": AgentSchema.string("The module's PE32/TE image node in the dump, e.g. \"0.6.4.0.0.205.2\" — from `code_modules`."),
        "module": AgentSchema.string("Or the module by its bytes' SHA-256, read from the store without a dump."),
        "recipe": AgentSchema.string("With `module`: which analysis, when there are several. Default: the newest.")
    ]

    public nonisolated var queryTool: AgentTool {
        var properties = Self.whereProperties
        properties["document"] = AgentSchema.string(wording.queryDocument)
        properties["what"] = AgentSchema.choice(Self.lists, "The list to read. Default \"functions\".")
        properties["function"] = AgentSchema.string(
            "A function name or Ghidra entry address, for \"instructions\", \"c\" and \"references\".")
        properties["address"] = AgentSchema.string("A Ghidra address, for \"uses\".")
        properties["search"] = AgentSchema.string("A word to narrow functions, strings or symbols by.")
        properties["limit"] = AgentSchema.limit(default: 200, maximum: 500)
        return AgentTool(
            name: "code_query",
            title: "Read a module's code analysis",
            description: wording.query,
            inputSchema: AgentSchema.object(properties)
        ) { call in
            try await self.answer(call.arguments)
        }
    }

    public nonisolated var modulesTool: AgentTool {
        AgentTool(
            name: "code_modules",
            title: "List a dump's analyzed modules",
            description: wording.modules,
            inputSchema: AgentSchema.object([
                "document": AgentSchema.string(wording.modulesDocument)
            ])
        ) { call in
            try await self.modules(call.arguments)
        }
    }

    // MARK: - Which analysis

    /// A document that is a module's code; else an image node of a dump;
    /// else a module SHA read from the store alone.
    public func source(_ arguments: AgentArguments) async throws -> Source {
        if let text = try arguments.optionalString("module") {
            guard let digest = SHA256Digest(hex: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AgentToolError("`module` is a SHA-256 of the module's bytes: 64 hex digits.")
            }
            let recipe = try arguments.optionalString("recipe")
            let root = store()
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
        let document = try documents.resolve(arguments.optionalString("document"))
        if let code = screen(document) { return code }
        guard let node = try arguments.optionalString("node") else {
            throw AgentToolError(wording.missingNode(document.named))
        }
        let opening = try await opening(node, in: document)
        return Source(manifest: opening.manifest, artifact: opening.artifact, bytes: Data(opening.bytes),
                      document: document.id, node: node, disk: document.disk)
    }

    /// Node `text` of `document`'s tree, read and matched with the store.
    public func opening(_ text: String, in document: any AgentDocument) async throws -> UEFICodeOpening {
        let id = try UEFIAgentQueries.nodeID(text)
        let tree = try await UEFIAgentQueries.readyTree(document.readHost())
        guard await UEFIAgentQueries.reachable(id, in: tree) else {
            throw AgentToolError("\(document.named) has no node \(text).")
        }
        do {
            return try await UEFICodeOpening.prepare(node: id, in: tree, store: store())
        } catch let failure as UEFICodeOpening.Failure {
            switch failure {
            case .noAnalysis:
                throw AgentToolError("Node \(text) of \(document.named) is not a PE32/TE image with a stored code "
                    + "analysis. `code_modules` lists the ones that are; the ghidra-uefi skill makes one.")
            default:
                throw AgentToolError(failure.text.text)
            }
        }
    }

    /// The image node in `tree` whose bytes are the module `manifest` was
    /// made from: the node the analysis names first, when this is its file,
    /// then every node the tree has open, then — the last resort — the tree
    /// with every compressed section opened.
    public func imageNode(of manifest: AnalysisManifest, in tree: LazyUEFITree, fileName: String) async -> NodeID? {
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

    // MARK: - code_query

    func answer(_ arguments: AgentArguments) async throws -> AgentAnswer {
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
        if let disk = source.disk { body["disk"] = .string(disk) }

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
                    "review_level": function.reviewLevel.map { JSONValue.string($0.rawValue) } ?? .null,
                    "review_gaps": .array(function.reviewGaps.map(JSONValue.string)),
                    "library_kind": function.libraryKind.map { JSONValue.string($0.rawValue) } ?? .null,
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
                    "reason": symbol.reason.map(JSONValue.string) ?? .null,
                    "comment": symbol.comment.map(JSONValue.string) ?? .null
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

    func modules(_ arguments: AgentArguments) async throws -> AgentAnswer {
        let document = try documents.resolve(arguments.optionalString("document"))
        let tree = try await UEFIAgentQueries.readyTree(document.readHost())
        let root = store()
        let index = await Task.detached(priority: .userInitiated) { CodeAnalysisIndex.load(from: root) }.value
        var body: [String: JSONValue] = ["document": .string(document.id)]
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
        let catalogue = await self.catalogue()
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
        return ToolQueryTools.stamped(.json(.object(body)), with: document)
    }
}
