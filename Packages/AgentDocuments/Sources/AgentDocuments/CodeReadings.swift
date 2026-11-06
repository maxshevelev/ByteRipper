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
        public internal(set) var artifact: CodeArtifact
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

    /// `code_query`, `code_modules`, then `library_registry`.
    public nonisolated func tools() -> [AgentTool] { [queryTool, modulesTool, libraryTool] }

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
        properties["level"] = AgentSchema.choice(ReviewLevel.allCases.map(\.rawValue),
                                                 "With `what: \"functions\"`: only functions at this review level.")
        properties["search"] = AgentSchema.string("A word to narrow functions, strings or symbols by; with `what: \"c\"` and no `function`, text to find in every function's stored C, any case, as written.")
        properties["limit"] = AgentSchema.limit(default: 200, maximum: 500)
        properties["after"] = AgentSchema.string("The `next` of the page before; a list too long for one answer says one.")
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

    /// The shared registry of library functions (`Design/LIBRARY_REGISTRY_PLAN.md`):
    /// its entries, or one entry with its review and its versions.
    public nonisolated var libraryTool: AgentTool {
        AgentTool(
            name: "library_registry",
            title: "Read the library function registry",
            description: """
                The shared registry of library functions: one entry per function body (its Function ID \
                hashes), holding the review of an EDK2, AGESA (`amd`) or Intel FSP/RC (`intel`) library \
                routine as one module published it, for every module whose function has the same body. \
                Without `id`: the entries — `id`, `name`, `kind`, `version`, where the current version came \
                from (`source`: module, address, revision) and how many bodies it covers (`variants`, which is not how many modules hold it) — \
                narrowed by `search` (a part of the name) and `kind`, sorted by name. `show` lists instead \
                `taken_out`, the bodies given back to their modules and why, or `sources`, the citations by \
                body, narrowed the same way. Every list is paged by `limit` and `after`, and every answer \
                says `total`, `taken_out_total` and `sources_total`. With `id`: that entry, or a taken-out one, its `review` (signature, parameters and \
                locals by storage, plate, step comments by offset from the entry) and its `history` of \
                versions, each with the module that published it and, for a version taken over another \
                module's, the reason. A recorded function comes with its C but without `instructions`, \
                `c_spans` and `c_fields`; `function_parts` says how large each is, and `part` reads one, \
                paged. `review.body.size`, in hex at the head of the `id`, is Function ID's count of code \
                units, not bytes: in practice the instructions without the calls. A name on a decompiler \
                temporary (`HASH:`, `unique:` storage) stays the module's and does not reach `review.locals`. \
                `show: "modules"` counts, across the whole store, how each stored analysis holds library \
                functions, read from its bytes: `links`; `own_bodies_in_registry`, functions with text the \
                store would make links — an entry holds the body, its code is the entry's, its callees are \
                links (the same bytes calling a function of the module are the module's, and not counted); \
                `out_of_format`, a link with a field no link has or a function with a \
                word of an older form. `totals` adds them up; the last two are zero in a clean store. \
                `libraries` says which library depends on which; a function calls only functions of its own library or of one it depends on. \
                A publish takes a review's `ghidra_library_candidate` functions here, and a module then holds a link.
                """,
            inputSchema: AgentSchema.object([
                "id": AgentSchema.string("An entry's id, as the list gives it, for the entry itself."),
                "search": AgentSchema.string("Only entries whose name holds this text, any case."),
                "kind": AgentSchema.choice(["edk2", "amd", "intel"], "Only entries of this kind."),
                "show": AgentSchema.choice(["entries", "taken_out", "sources", "modules"], "Which list. Default: entries."),
                "part": AgentSchema.choice(LibraryEntryParts.names, "With `id`: one part of the recorded function. `instructions` is the registry's code: each at its offset in the function, what it calls by the name that function has now."),
                "body": AgentSchema.string("With `part: instructions`: which of the entry's bodies. The first when not given."),
                "limit": AgentSchema.limit(default: 200, maximum: 1000),
                "after": AgentSchema.string("The `next` of the page before.")
            ])
        ) { call in
            .json(try await self.library(call.arguments))
        }
    }

    private func library(_ arguments: AgentArguments) async throws -> JSONValue {
        let root = store()
        let id = try arguments.optionalString("id")
        let search = try arguments.optionalString("search")?.lowercased()
        let kind = try arguments.optionalString("kind")
        let limit = try arguments.limit(default: 200, maximum: 1000)
        let show = try arguments.choice("show", from: ["entries", "taken_out", "sources", "modules"], default: "entries")
        let part = try arguments.optionalString("part")
        if let part, !LibraryEntryParts.names.contains(part) {
            throw AgentToolError("`part` is one of \(LibraryEntryParts.names.joined(separator: ", ")).")
        }
        if part != nil, id == nil { throw AgentToolError("`part` reads one entry: give its `id`.") }
        return try await Task.detached(priority: .userInitiated) { () throws -> JSONValue in
            guard let store = try? ContentStore(root: root, create: false) else {
                return .object(["entries": .array([]), "total": .int(0)])
            }
            if show == "modules" {
                let rows = try store.libraryHoldings()
                return .object([
                    "modules": .array(rows.map { row in
                        .object(["module": .string(row.module.hex), "name": .string(row.name),
                                 "recipe": .string(row.recipe), "links": .count(row.links),
                                 "own_bodies_in_registry": .count(row.ownBodiesInRegistry),
                                 "out_of_format": .count(row.outOfFormat)])
                    }),
                    "totals": .object([
                        "analyses": .count(rows.count),
                        "links": .count(rows.reduce(0) { $0 + $1.links }),
                        "own_bodies_in_registry": .count(rows.reduce(0) { $0 + $1.ownBodiesInRegistry }),
                        "out_of_format": .count(rows.reduce(0) { $0 + $1.outOfFormat })
                    ])
                ])
            }
            let index = try store.libraryIndex()
            func source(_ source: LibrarySource) -> JSONValue {
                .object(["module": .string(source.module.hex), "address": .string(source.address),
                         "rev": source.rev.map { JSONValue.int(Int64($0)) } ?? .null,
                         "by": source.by.map(JSONValue.string) ?? .null])
            }
            func oneCitation(_ cited: LibraryCitation) -> JSONValue {
                .object(["file": .string(cited.file), "line": .int(Int64(cited.line)),
                         "note": cited.note.map(JSONValue.string) ?? .null,
                         "by": cited.by.map(JSONValue.string) ?? .null, "at": .string(cited.at)])
            }
            /// A body's citations, and those later calls replaced or removed.
            func citations(_ body: String) -> [String: JSONValue] {
                var row: [String: JSONValue] = [
                    "citations": .array((index.sources?[body]?.all ?? []).map(oneCitation))
                ]
                if let changes = index.sourceChanges?[body] {
                    row["citation_changes"] = .array(changes.map { change in
                        .object(["action": .string(change.action), "old": oneCitation(change.old),
                                 "by": change.by.map(JSONValue.string) ?? .null, "at": .string(change.at)])
                    })
                }
                return row
            }
            func takenOut(_ body: String, _ out: LibraryTakenOut) -> JSONValue {
                .object(["body": .string(body), "id": .string(out.id), "name": .string(out.name),
                         "kind": .string(out.kind), "version": .int(Int64(out.version)),
                         "reason": .string(out.reason), "by": out.by.map(JSONValue.string) ?? .null,
                         "at": .string(out.at)])
            }
            func history(_ id: String) throws -> JSONValue? {
                // A mirror copies the index only: the history is the server's.
                try store.libraryHistory(id: id).map { history in
                    .array(history.versions.map { version in
                        var row: [String: JSONValue] = [
                            "version": .int(Int64(version.version)), "source": source(version.source),
                            "reason": version.reason.map(JSONValue.string) ?? .null,
                            "recorded_at": .string(version.recordedAt)]
                        if let module = version.changedFrom { row["changed_from"] = .string(module.hex) }
                        return .object(row)
                    })
                }
            }
            /// One page of a part of the recorded function.
            func page(of part: String, id: String, version: Int, review: SHA256Digest,
                      variants: [LibraryVariant]) throws -> JSONValue {
                let items: [JSONValue]
                // The code a body has in the registry: by place in the function,
                // and what it calls by the name it has now.
                let wanted = try arguments.optionalString("body")
                if let wanted, !variants.contains(where: { $0.body.key == wanted }) {
                    throw AgentToolError("The entry \(id) has no body \(wanted).")
                }
                if part == "instructions",
                   let digest = variants.first(where: { wanted == nil || $0.body.key == wanted })?.code,
                   let listing = LibraryCode.listing(code: try store.object(digest), name: { index.entries[$0]?.name }),
                   case .array(let rows) = try JSONDecoder().decode(
                    JSONValue.self, from: JSONSerialization.data(withJSONObject: listing)) {
                    items = rows
                } else {
                    let data = try store.object(review)
                    guard let text = LibraryEntryParts.part(part, of: data),
                          case .array(let rows) = try JSONDecoder().decode(JSONValue.self, from: text) else {
                        throw AgentToolError("The entry \(id) has no `\(part)`: no function is recorded in it.")
                    }
                    items = rows
                }
                let page = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([id, version, part]),
                                         changed: "The entry changed since that page; ask again without `after`.")
                return try page.answer(["id": .string(id), "version": .int(Int64(version)),
                                        "part": .string(part), "total": .int(Int64(items.count))],
                                       key: "items", items: Array(items.dropFirst(page.first).prefix(limit)),
                                       total: items.count, bound: arguments.answerBound)
            }
            /// The review for an entry's answer, and what was left out of it.
            func put(review digest: SHA256Digest, in answer: inout [String: JSONValue]) {
                guard let data = try? store.object(digest) else { return }
                let (lighter, parts) = LibraryEntryParts.lighter(data)
                if let review = try? JSONDecoder().decode(JSONValue.self, from: lighter) {
                    answer["review"] = review
                }
                if !parts.isEmpty {
                    answer["function_parts"] = .object(parts.mapValues {
                        .object(["items": .int(Int64($0.items)), "bytes": .int(Int64($0.bytes))])
                    })
                }
            }
            let allTakenOut = (index.takenOut ?? [:]).sorted { $0.key < $1.key }
            if let id, index.entries[id] == nil {
                let bodies = allTakenOut.filter { $0.value.id == id }
                guard let last = bodies.first?.value else {
                    throw AgentToolError("The registry has no entry \(id): `library_registry` without `id` lists them.")
                }
                if let part {
                    return try page(of: part, id: id, version: last.version, review: last.entry,
                                    variants: bodies.map(\.value.variant))
                }
                var answer: [String: JSONValue] = [
                    "id": .string(id), "name": .string(last.name), "kind": .string(last.kind),
                    "version": .int(Int64(last.version)),
                    "taken_out": .array(bodies.map { takenOut($0.key, $0.value) })
                ]
                put(review: last.entry, in: &answer)
                answer["history"] = try history(id)
                return .object(answer)
            }
            if let id {
                guard let entry = index.entries[id] else {
                    throw AgentToolError("The registry has no entry \(id): `library_registry` without `id` lists them.")
                }
                if let part {
                    return try page(of: part, id: id, version: entry.version, review: entry.entry, variants: entry.variants)
                }
                var answer: [String: JSONValue] = [:]
                answer["id"] = .string(id)
                answer["name"] = .string(entry.name)
                answer["kind"] = .string(entry.kind)
                answer["version"] = .int(Int64(entry.version))
                answer["source"] = source(entry.source)
                answer["variants"] = .array(entry.variants.map {
                    .object(citations($0.body.key).merging(
                        ["body": .string($0.body.key), "module": .string($0.module.hex)]) { $1 })
                })
                put(review: entry.entry, in: &answer)
                answer["history"] = try history(id)
                return .object(answer)
            }
            func matches(name: String, kind held: String) -> Bool {
                (kind == nil || held == kind) && (search == nil || name.lowercased().contains(search!))
            }
            let matching = index.entries
                .filter { matches(name: $0.value.name, kind: $0.value.kind) }
                .sorted { ($0.value.name, $0.key) < ($1.value.name, $1.key) }
            let takenOutRows = allTakenOut.filter { matches(name: $0.value.name, kind: $0.value.kind) }
            // Narrowed, a citation goes with the body it is for; one for a body
            // the registry has not met yet has no name to match.
            let narrowed = search != nil || kind != nil
            let bodies = Set(matching.flatMap { $0.value.variants.map(\.body.key) } + takenOutRows.map(\.key))
            let citationRows = (index.sources ?? [:]).sorted { $0.key < $1.key }
                .filter { !narrowed || bodies.contains($0.key) }
            let rows: [JSONValue]
            switch show {
            case "taken_out": rows = takenOutRows.map { takenOut($0.key, $0.value) }
            case "sources":
                rows = citationRows.map { body, _ in
                    .object(citations(body).merging(["body": .string(body)]) { $1 })
                }
            default:
                rows = matching.map { id, entry in
                    .object(["id": .string(id), "name": .string(entry.name), "kind": .string(entry.kind),
                             "version": .int(Int64(entry.version)), "source": source(entry.source),
                             "variants": .int(Int64(entry.variants.count))])
                }
            }
            let page = try AgentPage(arguments, fingerprint: AgentPage.fingerprint([show, search, kind, rows.count]),
                                     changed: "The registry changed since that page, or the question did; ask again without `after`.")
            let libraries = index.declaredLibraries.mapValues { definition -> JSONValue in
                .object(["depends_on": .array(definition.dependsOn.sorted().map(JSONValue.string))])
            }
            return try page.answer(["libraries": .object(libraries),
                                    "total": .int(Int64(matching.count)),
                                    "taken_out_total": .int(Int64(takenOutRows.count)),
                                    "sources_total": .int(Int64(citationRows.count))],
                                   key: show, items: Array(rows.dropFirst(page.first).prefix(limit)),
                                   total: rows.count, bound: arguments.answerBound)
        }.value
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
        if let code = screen(document) { return try await whole(code) }
        guard let node = try arguments.optionalString("node") else {
            throw AgentToolError(wording.missingNode(document.named))
        }
        let opening = try await opening(node, in: document)
        return try await whole(Source(manifest: opening.manifest, artifact: opening.artifact, bytes: Data(opening.bytes),
                                      document: document.id, node: node, disk: document.disk))
    }

    /// A source with all its code: what a panel shows may be an artifact's index,
    /// and an agent's question can be about any function.
    private func whole(_ source: Source) async throws -> Source {
        guard source.artifact.functions.contains(where: \.codeIsPending) else { return source }
        let root = store()
        let manifest = source.manifest
        let artifact = await Task.detached(priority: .userInitiated) {
            try? ContentStore(root: root, create: false).artifact(for: manifest)
        }.value
        guard let artifact else {
            throw AgentToolError("The store cannot give the code of module \(manifest.module.sha256.hex).")
        }
        var source = source
        source.artifact = artifact
        return source
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
            if let index = model.function(named: name) { return model.functions[index] }
            // An address inside a body means the function around it, as `ghidra_function` takes it.
            if let address = CodeAddress(hex: name.trimmingCharacters(in: .whitespacesAndNewlines)),
               let holder = model.functions.first(where: { $0.instructions.contains { $0.address == address } }) {
                return holder
            }
            throw AgentToolError("No function \"\(name)\" in this analysis.")
        }

        /// Every list goes by pages: one too long for an answer says `next`
        /// instead of being refused, and a `limit` short of `total` too.
        func page(_ key: String, _ items: [JSONValue], _ question: [AnyHashable?]) throws -> (key: String, page: AgentPage, total: Int, items: [JSONValue]) {
            let page = try AgentPage(arguments, fingerprint: AgentPage.fingerprint(
                [source.manifest.artifact.sha256.hex, what] + question),
                changed: "The analysis changed since that page, or the question did; ask again without `after`.")
            return (key, page, items.count, Array(items.dropFirst(page.first).prefix(limit)))
        }
        var listed: (key: String, page: AgentPage, total: Int, items: [JSONValue])?
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
            let matching = model.functions(matching: search ?? "").map { model.functions[$0] }
            var functions = matching
            if let text = try arguments.optionalString("level") {
                guard let level = ReviewLevel(rawValue: text) else {
                    throw AgentToolError("`level` is one of "
                        + ReviewLevel.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                }
                functions = matching.filter { $0.reviewLevel == level }
            }
            body["total"] = .int(Int64(functions.count))
            // Over every match, not the page: the list itself can be too long to read.
            var levels: [String: Int64] = Dictionary(uniqueKeysWithValues:
                ReviewLevel.allCases.map { ($0.rawValue, 0) })
            var unrecorded: Int64 = 0
            for function in matching {
                if let level = function.reviewLevel { levels[level.rawValue, default: 0] += 1 } else { unrecorded += 1 }
            }
            if unrecorded > 0 { levels["unrecorded"] = unrecorded }
            body["review_levels"] = .object(levels.mapValues(JSONValue.int))
            let level = try arguments.optionalString("level")
            let items: [JSONValue] = functions.map { functionItem($0, offsetText) }
            listed = try page("functions", items, [search, level])

        case "instructions":
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["entry"] = .string(function.entry.description)
            // `search`, as the other lists take it: the text of the instruction, any case.
            var held = function.instructions
            if let search, !search.isEmpty {
                held = held.filter { $0.text.lowercased().contains(search) }
                body["search"] = .string(search)
                body["instructions_in_function"] = .int(Int64(function.instructions.count))
            }
            let items: [JSONValue] = held.map { instruction in
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
            }
            listed = try page("instructions", items, [function.entry.description, search])

        case "c":
            // Across the module: the lines of stored C holding the text.
            if let search, !search.isEmpty, try arguments.optionalString("function") == nil {
                var matches: [JSONValue] = []
                var holding = 0
                for function in model.functions {
                    guard let c = function.c else { continue }
                    var held = false
                    for (number, line) in c.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    where line.lowercased().contains(search) {
                        held = true
                        matches.append(.object([
                            "function": .string(function.name),
                            "entry": .string(function.entry.description),
                            "line": .int(Int64(number + 1)),
                            "text": .string(String(line.trimmingCharacters(in: .whitespaces).prefix(300)))
                        ]))
                    }
                    if held { holding += 1 }
                }
                body["search"] = .string(search)
                body["functions_matched"] = .int(Int64(holding))
                listed = try page("matches", matches, [search])
                break
            }
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["entry"] = .string(function.entry.description)
            body["signature"] = function.signature.map(JSONValue.string) ?? .null
            body["c"] = function.c.map(JSONValue.string) ?? .null
            if function.textFromRegistry { body["text"] = .string("registry") }
            if !function.entryEquates.isEmpty {
                body["equates"] = .array(function.entryEquates.map { equate in
                    var row: [String: JSONValue] = ["name": .string(equate.name), "value": .string(CodeAddress(equate.value).description)]
                    if let name = equate.enumName { row["enum"] = .string(name) }
                    if let comment = equate.comment { row["comment"] = .string(comment) }
                    return .object(row)
                })
            }
            if function.textUnavailable { body["text_unavailable"] = .string("the registry entry could not be read") }
            if !function.publisherAddresses.isEmpty {
                body["publisher_addresses"] = .array(function.publisherAddresses.map(JSONValue.string))
            }
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
            listed = try page("uses", uses.map { use in
                .object([
                    "from": .string(use.from.description),
                    "offset": offsetText(use.from),
                    "type": .string(use.type),
                    "function": .string(model.functions[use.function].name),
                    "text": .string(model.lines[use.line].instruction.text)
                ])
            }, [address.description])

        case "symbols":
            let symbols = source.artifact.symbols.filter { symbol in
                guard let search, !search.isEmpty else { return true }
                return symbol.name.lowercased().contains(search)
                    || (symbol.type?.lowercased().contains(search) ?? false)
            }
            listed = try page("symbols", symbols.map { symbol in
                .object([
                    "address": .string(symbol.address.description),
                    "offset": offsetText(symbol.address),
                    "name": .string(symbol.name),
                    "type": symbol.type.map(JSONValue.string) ?? .null,
                    "source": symbol.source.map(JSONValue.string) ?? .null,
                    "reason": symbol.reason.map(JSONValue.string) ?? .null,
                    "comment": symbol.comment.map(JSONValue.string) ?? .null
                ])
            }, [search])

        case "strings":
            let strings = source.artifact.strings.filter { entry in
                guard let search, !search.isEmpty else { return true }
                return entry.value.lowercased().contains(search)
                    || entry.type.lowercased().contains(search)
                    || entry.address.description.lowercased().contains(search)
            }
            listed = try page("strings", strings.map { entry in
                .object([
                    "address": .string(entry.address.description),
                    "offset": offsetText(entry.address),
                    "type": .string(entry.type),
                    "value": .string(entry.value)
                ])
            }, [search])

        case "post_codes":
            // By value, the places that send one together, what could not
            // be told last — as the panel's POST list shows them.
            let wanted = search.flatMap { UInt64($0.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }
            let codes = source.artifact.postCodes
                .filter { wanted == nil || $0.value == wanted }
                .sorted { ($0.value ?? .max, $0.address.value) < ($1.value ?? .max, $1.address.value) }
            listed = try page("post_codes", codes.map { code in
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
            }, [search])

        default:
            let function = try namedFunction()
            body["function"] = .string(function.name)
            body["callers"] = .array(function.callers.map(reference))
            body["callees"] = .array(function.callees.map(reference))
        }
        // The registry's numbers for this module, counted from the analysis
        // and the store's index — a Review status written from one call,
        // rather than from the answer of a publish.
        if what == "functions" {
            body["library"] = await libraryBlock(for: source)
        }
        // The stored analysis is not the live program: say when an owner has
        // one open, and whether it holds writes this answer has not got.
        // A host that cannot be asked — an analysis server out of reach, or
        // one older than the question — leaves both out: unknown is not
        // "not open".
        // (`try?` would flatten the thrown and the nil into one nil.)
        let state: Bool??
        if let liveState {
            do { state = .some(try await liveState(source.manifest.module.sha256)) } catch { state = nil }
        } else {
            state = nil
        }
        if let state {
            if let unpublished = state {
                body["live"] = .bool(true)
                body["unpublished_writes"] = .bool(unpublished)
                if unpublished {
                    body["unpublished_note"] = .string("This answer is the last publish; the writes since are not in it. `ghidra_function` reads the live C.")
                }
            } else {
                body["live"] = .bool(false)
            }
        }
        if let listed {
            body["total"] = .int(Int64(listed.total))
            return .json(try listed.page.answer(body, key: listed.key, items: listed.items,
                                                total: listed.total, bound: arguments.answerBound))
        }
        return .json(.object(body))
    }

    /// What the module links to in the registry: how many links, of whose
    /// library, and how many entries hold this module's body as their source.
    private func libraryBlock(for source: Source) async -> JSONValue {
        let root = store()
        let index = await Task.detached(priority: .userInitiated) {
            (try? ContentStore(root: root, create: false).libraryIndex()) ?? LibraryIndex()
        }.value
        let module = source.manifest.module.sha256
        var kinds: [String: Int] = [:]
        var links = 0
        var withTemporaries = 0
        for function in source.artifact.functions where function.libraryEntry != nil {
            links += 1
            if let kind = function.libraryKind { kinds[kind.rawValue, default: 0] += 1 }
            if !LibraryEntryReview.temporaries(in: function).isEmpty { withTemporaries += 1 }
        }
        return .object([
            "edk2": .count(kinds["edk2"] ?? 0),
            "amd": .count(kinds["amd"] ?? 0),
            "intel": .count(kinds["intel"] ?? 0),
            "links": .count(links),
            "installed": .count(index.entries.values.filter { $0.source.module == module }.count),
            "with_temporaries": .count(withTemporaries)
        ])
    }

    /// Whether a prototype's return type is Ghidra's placeholder — `undefined`
    /// or `undefined8` — which no review filled in. The analysis keeps the
    /// whole prototype, so its first word is the return type.
    static func hasPlaceholderReturn(_ signature: String?) -> Bool {
        guard let signature else { return false }
        let returnType = signature.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return returnType.hasPrefix("undefined")
    }


    /// Whether the module has an owner open, and whether that program holds
    /// writes the store has not got — what `code_query` answers as `live` and
    /// `unpublished_writes`: nil when no owner has it open, which answers
    /// `live: false`. No closure, or one that throws, leaves both out; a
    /// host with no Ghidra of its own has nothing to ask.
    public var liveState: (@Sendable (SHA256Digest) async throws -> Bool?)?

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

/// A function's place in the library registry, as `code_query` answers it.
private func libraryEntryItem(_ entry: CodeArtifact.LibraryEntry?) -> JSONValue {
    guard let entry else { return .null }
    var item: [String: JSONValue] = ["id": .string(entry.id), "version": .int(Int64(entry.version))]
    if !entry.codes.isEmpty { item["codes"] = .array(entry.codes.map(JSONValue.string)) }
    return .object(item)
}

/// One function of a `functions` list. Built field by field rather than as
/// one dictionary literal: a literal of this many optional fields takes the
/// type checker of Xcode 26.3 past its time limit.
private func functionItem(_ function: CodeArtifact.Function,
                          _ offsetText: (CodeAddress) -> JSONValue) -> JSONValue {
    func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    var item: [String: JSONValue] = [:]
    item["name"] = .string(function.name)
    item["entry"] = .string(function.entry.description)
    item["offset"] = offsetText(function.entry)
    item["size"] = function.size.map { .int(Int64($0)) } ?? .null
    item["external"] = .bool(function.external)
    item["thunk"] = .bool(function.thunk)
    item["signature"] = text(function.signature)
    item["name_source"] = text(function.nameSource)
    item["name_reason"] = text(function.nameReason)
    item["signature_reason"] = text(function.signatureReason)
    if function.customStorage == true { item["custom_storage"] = .bool(true) }
    item["review_level"] = text(function.reviewLevel?.rawValue)
    item["review_gaps"] = .array(function.reviewGaps.map(JSONValue.string))
    item["temporaries"] = .array(LibraryEntryReview.temporaries(in: function).map(JSONValue.string))
    item["body"] = text(function.body)
    item["library_kind"] = text(function.libraryKind?.rawValue)
    item["library_entry"] = libraryEntryItem(function.libraryEntry)
    if function.textFromRegistry { item["text"] = .string("registry") }
    if function.textUnavailable { item["text_unavailable"] = .string("the registry entry could not be read") }
    if !function.publisherAddresses.isEmpty {
        item["publisher_addresses"] = .array(function.publisherAddresses.map(JSONValue.string))
    }
    item["callers"] = .array(function.callers.map { .string($0.description) })
    item["callees"] = .array(function.callees.map { .string($0.description) })
    return .object(item)
}
