import Foundation

/// The store as a command line: what `byteripper-cas` runs, and what the
/// skill's Python calls instead of a store of its own.
///
/// Every answer is JSON on standard output — an object's bytes are the one
/// exception. What the store refused is `{"error": "…"}` on standard error with
/// status 1, for the skill's Python to read. A command line it cannot read is
/// a person's mistake: plain text on standard error with status 2, and the
/// usage when the command itself is wrong. An argument the store does not
/// know is refused, never dropped, so a field the Python side adds cannot
/// vanish from a manifest unseen. `help` prints the usage.
///
///     byteripper-cas [--store <root>] [--no-create] <command> …
///
/// The default root is `CodeAnalysisPaths.defaultRoot`, the app's own.
public enum CASCommand {
    /// The protocol a client checks with `hello` before it relies on an
    /// answer's shape. Raised when an answer changes, never for an addition.
    public static let protocolVersion = 1

    public struct Output {
        public var stdout = Data()
        public var stderr = Data()
        public var status: Int32 = 0
    }

    struct Usage: Error, CustomStringConvertible {
        let description: String
        /// The command itself is missing or unknown: the whole usage helps.
        /// A wrong argument of a known command is said in one line.
        var showsUsage = false
    }

    static let usage = """
        usage: byteripper-cas [--store <root> | --server <url> [--token-file <file>]]
                              [--no-create] <command>
          hello
          library-holdings
          library-evidence --edk2 <checkout of the pinned tag>
          relink-modules [--apply]
          recount-stats [--apply]
          drop-earlier-projects [--apply]
          library-source-rev --module <sha256> --from <rev> --to <rev> [--apply]
          library-take-out <id> [--body <key>] --reason <text> [--apply]
          library-restore <body> --reason <text> [--apply]
          library-split <id> <body> <name> --reason <text> [--apply]
          put-object <file>
          has-object <sha256>
          get-object <sha256> [--out <file>]
          put-analysis --module <json> --recipe <json> --artifact <file>
                       [--source <json>] [--reading <json>] [--replace] [--discard-reading]
          analysis <module-sha> [--recipe <id>]
          recipes <module-sha>
          list
          conflicts
          record-revision <module-sha> --reading <json> [--artifact <sha>] [--by <who>]
          review-history <module-sha>
          set-ref <name> <module-sha>/<recipe>...
          refs
          remove-ref <name>
          verify
          gc [--apply] [--analyses]
          export --out <file> <module-sha>/<recipe>...
          import <file>
        """

    public static func run(_ arguments: [String]) -> Output {
        var output = Output()
        do {
            var parser = Arguments(arguments)
            let storeOption = parser.option("--store")
            let server = parser.option("--server")
            let tokenFile = parser.option("--token-file")
            let create = !parser.flag("--no-create")
            let operations: StoreOperations
            if let server {
                guard storeOption == nil else {
                    throw Usage(description: "name a --store or a --server, not both")
                }
                operations = RemoteOperations(remote: try remote(server, tokenFile: tokenFile))
            } else {
                operations = LocalOperations(
                    root: storeOption.map { URL(fileURLWithPath: $0) } ?? CodeAnalysisPaths.defaultRoot,
                    create: create)
            }
            guard let command = parser.next() else { throw Usage(description: "name a command", showsUsage: true) }
            if ["help", "--help", "-h"].contains(command) {
                output.stdout = Data((usage + "\n").utf8)
                return output
            }
            try execute(command, &parser, operations, into: &output)
        } catch let refusal as Usage {
            output.stdout = Data()
            var text = "byteripper-cas: \(refusal.description)\n"
            if refusal.showsUsage { text += "\n" + usage + "\n" }
            output.stderr = Data(text.utf8)
            output.status = 2
        } catch {
            output.stdout = Data()
            output.stderr = errorJSON("\(error)")
            output.status = 1
        }
        return output
    }

    // MARK: - Commands

    /// The served store's client. The token is the file named, or the one
    /// `BYTERIPPER_SERVER_TOKEN_FILE` names, or the server's default
    /// (`…/ByteRipper/Server/token`) when it exists — the place a laptop keeps
    /// the token it was given, too.
    static func remote(_ server: String, tokenFile: String?) throws -> RemoteStore {
        guard let url = URL(string: server), let scheme = url.scheme,
              ["http", "https"].contains(scheme), url.host != nil else {
            throw Usage(description: "--server takes http://<host>:<port>, not \(server)")
        }
        let file = tokenFile.map { URL(fileURLWithPath: $0) }
            ?? ProcessInfo.processInfo.environment["BYTERIPPER_SERVER_TOKEN_FILE"].map { URL(fileURLWithPath: $0) }
            ?? CodeAnalysisPaths.defaultRoot.deletingLastPathComponent()
                .appendingPathComponent("Server/token")
        var token: String?
        if FileManager.default.fileExists(atPath: file.path) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                throw CodeAnalysisError.io("\(file.path): cannot be read")
            }
            token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if tokenFile != nil {
            throw CodeAnalysisError.io("\(file.path): no such token file")
        }
        return RemoteStore(base: url, token: token)
    }

    private static func execute(_ command: String, _ parser: inout Arguments,
                                _ store: StoreOperations, into output: inout Output) throws {
        switch command {
        case "hello":
            try parser.end()
            output.stdout = try json(try store.hello())
        case "put-object":
            let file = try parser.required("a file")
            try parser.end()
            let data = try read(file)
            let digest = try store.putObject(data)
            output.stdout = try json(["sha256": digest.hex, "size": data.count] as [String: Any])
        case "has-object":
            let digest = try digestArgument(&parser)
            try parser.end()
            output.stdout = try json(["present": try store.hasObject(digest)])
        case "get-object":
            let digest = try digestArgument(&parser)
            let out = parser.option("--out")
            try parser.end()
            let data = try store.object(digest)
            if let out {
                try write(data, to: out)
                output.stdout = try json(["sha256": digest.hex, "size": data.count] as [String: Any])
            } else {
                output.stdout = data
            }
        case "put-analysis":
            let module: ModuleIdentity = try decode(
                parser.option("--module"), "--module",
                keys: ["sha256", "size", "name", "kind", "language", "image_base", "phase"])
            let recipe: AnalysisRecipe = try decode(
                parser.option("--recipe"), "--recipe",
                keys: ["id", "exporter", "ghidra", "script", "types", "passes"])
            guard let artifact = parser.option("--artifact") else {
                throw Usage(description: "put-analysis: --artifact is required")
            }
            let source: SourceIdentity = try parser.option("--source").map {
                try decode($0, "--source", keys: ["path", "document", "node"])
            } ?? SourceIdentity()
            let reading: AnalysisReading? = try parser.option("--reading").map {
                try decode($0, "--reading", keys: ["project", "rev", "review", "description"])
            }
            let replace = parser.flag("--replace")
            let discardReading = parser.flag("--discard-reading")
            try parser.end()
            let manifest = try store.putAnalysis(
                module: module, recipe: recipe, artifact: try read(artifact), source: source,
                reading: reading, replace: replace, discardReading: discardReading)
            output.stdout = try encode(manifest)
        case "analysis":
            let module = try digestArgument(&parser)
            let recipe = parser.option("--recipe")
            try parser.end()
            let manifest = try store.analysis(module: module, recipe: recipe)
            output.stdout = try manifest.map(encode) ?? Data("null\n".utf8)
        case "recipes":
            let module = try digestArgument(&parser)
            try parser.end()
            output.stdout = try encode(try store.recipes(ofModule: module))
        case "list":
            try parser.end()
            output.stdout = try encode(try store.analyses())
        case "conflicts":
            try parser.end()
            output.stdout = try encode(try store.conflicts())
        case "record-revision":
            let module = try digestArgument(&parser)
            let reading: AnalysisReading = try decode(
                parser.option("--reading"), "--reading", keys: ["project", "rev", "review", "description"])
            let artifact = try parser.option("--artifact").map { text -> SHA256Digest in
                guard let digest = SHA256Digest(hex: text) else { throw CodeAnalysisError.invalidDigest(text) }
                return digest
            }
            let by = parser.option("--by")
            try parser.end()
            output.stdout = try encode(try store.recordRevision(module: module, reading: reading,
                                                                artifact: artifact, by: by))
        case "review-history":
            let module = try digestArgument(&parser)
            try parser.end()
            output.stdout = try store.reviewHistory(module: module).map(encode) ?? Data("null\n".utf8)
        case "set-ref":
            let name = try parser.required("a reference name")
            let keys = try parser.rest().map(keyArgument)
            guard !keys.isEmpty else { throw Usage(description: "set-ref: name at least one analysis") }
            output.stdout = try encode(try store.setRef(name, analyses: keys))
        case "refs":
            try parser.end()
            output.stdout = try encode(try store.refs())
        case "remove-ref":
            let name = try parser.required("a reference name")
            try parser.end()
            output.stdout = try json(["removed": try store.removeRef(name)])
        case "library-holdings":
            try parser.end()
            guard let local = store as? LocalOperations else {
                throw CodeAnalysisError.analysisMismatch("library-holdings runs on a store directory, not on a server")
            }
            let rows = try ContentStore(root: local.root, create: local.create).libraryHoldings()
            output.stdout = try json([
                "analyses": rows.count, "links": rows.reduce(0) { $0 + $1.links },
                "own_bodies_in_registry": rows.reduce(0) { $0 + $1.ownBodiesInRegistry },
                "out_of_format": rows.reduce(0) { $0 + $1.outOfFormat }
            ])
        case "library-evidence":
            guard let tree = parser.option("--edk2") else {
                throw Usage(description: "library-evidence: --edk2 <checkout of the pinned tag> is required")
            }
            try parser.end()
            let checkout = URL(fileURLWithPath: tree, isDirectory: true)
            guard FileManager.default.fileExists(atPath: checkout.appendingPathComponent("MdePkg").path) else {
                throw CodeAnalysisError.io("\(checkout.path): no MdePkg, not an EDK2 checkout")
            }
            let audit = try EDK2Evidence.audit(try store.libraryIndex(), object: { try store.object($0) },
                                               checkout: checkout)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            output.stdout = try encoder.encode(audit) + Data("\n".utf8)
        case "drop-earlier-projects":
            let apply = parser.flag("--apply")
            try parser.end()
            guard let local = store as? LocalOperations else {
                throw CodeAnalysisError.analysisMismatch("drop-earlier-projects runs on a store directory, not on a server")
            }
            output.stdout = try encode(try ContentStore(root: local.root, create: local.create)
                .dropEarlierProjects(apply: apply))
        case "library-source-rev":
            let apply = parser.flag("--apply")
            guard let text = parser.option("--module"), let module = SHA256Digest(hex: text),
                  let from = parser.option("--from").flatMap({ Int($0) }),
                  let to = parser.option("--to").flatMap({ Int($0) }) else {
                throw Usage(description: "library-source-rev: --module <sha256> --from <rev> --to <rev> are required")
            }
            try parser.end()
            guard let local = store as? LocalOperations else {
                throw CodeAnalysisError.analysisMismatch("library-source-rev runs on a store directory, not on a server")
            }
            let store = try ContentStore(root: local.root, create: local.create)
            // Only onto a revision the module has: the point is a source that names one.
            guard (try store.reviewHistory(module: module))?.revisions.contains(where: { $0.rev == to }) == true else {
                throw CodeAnalysisError.analysisMismatch("\(module.hex) has no revision \(to)")
            }
            let count = try store.renumberLibrarySources(module: module, from: from, to: to, dryRun: !apply)
            output.stdout = try json(["sources": count, "applied": apply] as [String: Any])
        case "relink-modules":
            let apply = parser.flag("--apply")
            try parser.end()
            guard let local = store as? LocalOperations else {
                throw CodeAnalysisError.analysisMismatch("relink-modules runs on a store directory, not on a server")
            }
            output.stdout = try encode(try ContentStore(root: local.root, create: local.create)
                .relinkModules(dryRun: !apply))
        case "recount-stats":
            // The manifests written before the review levels were counted get
            // them from their own artifacts; a dry run lists them.
            let apply = parser.flag("--apply")
            try parser.end()
            guard let local = store as? LocalOperations else {
                throw CodeAnalysisError.analysisMismatch("recount-stats runs on a store directory, not on a server")
            }
            output.stdout = try encode(try ContentStore(root: local.root, create: local.create)
                .recountStats(dryRun: !apply))
        case "library-take-out", "library-restore", "library-split":
            // Changing what the registry says is an administrator's: whoever holds
            // the store's directory, or a token with the `admin` right.
            let apply = parser.flag("--apply")
            guard let reason = parser.option("--reason") else {
                throw CodeAnalysisError.analysisMismatch("\(command) needs --reason")
            }
            let bodyOption = command == "library-take-out" ? parser.option("--body") : nil
            guard let local = store as? LocalOperations else {
                throw CodeAnalysisError.analysisMismatch("\(command) runs on a store directory, not on a server")
            }
            let held = try ContentStore(root: local.root, create: local.create)
            switch command {
            case "library-take-out":
                let id = try parser.required("an entry id")
                try parser.end()
                output.stdout = try encode(try held.changeLibrary(
                    LibraryChange(action: .takeOut, id: id, body: bodyOption, reason: reason),
                    by: "administrator", changedFrom: nil, dryRun: !apply))
            case "library-restore":
                let body = try parser.required("the body's key")
                try parser.end()
                output.stdout = try encode(try held.changeLibrary(
                    LibraryChange(action: .restore, body: body, reason: reason),
                    by: "administrator", changedFrom: nil, dryRun: !apply))
            default:
                let id = try parser.required("an entry id")
                let body = try parser.required("the body to split off")
                let name = try parser.required("its name")
                try parser.end()
                output.stdout = try encode(try held.changeLibrary(
                    LibraryChange(action: .split, id: id, body: body, name: name, reason: reason),
                    by: "administrator", changedFrom: nil, dryRun: !apply))
            }
        case "library-rebody":
            let apply = parser.flag("--apply")
            guard let reason = parser.option("--reason") else {
                throw CodeAnalysisError.analysisMismatch("library-rebody needs --reason")
            }
            let id = try parser.required("an entry id")
            let body = try parser.required("the body to keep")
            try parser.end()
            guard let local = store as? LocalOperations else {
                throw CodeAnalysisError.analysisMismatch("library-rebody runs on a store directory, not on a server")
            }
            output.stdout = try encode(try ContentStore(root: local.root, create: local.create).rebodyLibraryEntry(id: id, bodyKey: body, reason: reason,
                                                                    dryRun: !apply))
        case "verify":
            try parser.end()
            output.stdout = try json(["problems": try store.verify()])
        case "gc":
            let apply = parser.flag("--apply")
            let analyses = parser.flag("--analyses")
            try parser.end()
            output.stdout = try encode(try store.collectGarbage(
                dryRun: !apply, deleteUnreferencedAnalyses: analyses))
        case "export":
            guard let out = parser.option("--out") else {
                throw Usage(description: "export: --out is required")
            }
            let keys = try parser.rest().map(keyArgument)
            guard !keys.isEmpty else { throw Usage(description: "export: name at least one analysis") }
            output.stdout = try encode(try store.exportBundle(keys, to: URL(fileURLWithPath: out)))
        case "import":
            let file = try parser.required("a bundle")
            try parser.end()
            output.stdout = try encode(try store.importBundle(from: URL(fileURLWithPath: file)))
        default:
            throw Usage(description: "unknown command \(command)", showsUsage: true)
        }
    }

    // MARK: - Arguments

    struct Arguments {
        private var items: [String]

        init(_ items: [String]) { self.items = items }

        /// `--name value` anywhere, removed from what is left.
        mutating func option(_ name: String) -> String? {
            guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
            let value = items[index + 1]
            items.removeSubrange(index...index + 1)
            return value
        }

        mutating func flag(_ name: String) -> Bool {
            guard let index = items.firstIndex(of: name) else { return false }
            items.remove(at: index)
            return true
        }

        mutating func next() -> String? {
            items.isEmpty ? nil : items.removeFirst()
        }

        mutating func required(_ what: String) throws -> String {
            guard let value = next(), !value.hasPrefix("--") else {
                throw Usage(description: "expected \(what)")
            }
            return value
        }

        mutating func rest() throws -> [String] {
            if let option = items.first(where: { $0.hasPrefix("--") }) {
                throw Usage(description: "unknown option \(option)")
            }
            defer { items = [] }
            return items
        }

        func end() throws {
            if let extra = items.first {
                throw Usage(description: "unexpected argument \(extra)")
            }
        }
    }

    private static func digestArgument(_ parser: inout Arguments) throws -> SHA256Digest {
        let text = try parser.required("a SHA-256")
        guard let digest = SHA256Digest(hex: text) else { throw CodeAnalysisError.invalidDigest(text) }
        return digest
    }

    private static func keyArgument(_ text: String) throws -> AnalysisKey {
        guard let key = AnalysisKey(text) else {
            throw CodeAnalysisError.invalidName("\(text) is not <module-sha>/<recipe>;")
        }
        return key
    }

    /// A JSON argument, refused if it names a field the store does not know.
    private static func decode<T: Decodable>(_ text: String?, _ name: String,
                                             keys: Set<String>) throws -> T {
        guard let text else { throw Usage(description: "\(name) is required") }
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Usage(description: "\(name) is not a JSON object")
        }
        let unknown = Set(object.keys).subtracting(keys).sorted()
        guard unknown.isEmpty else {
            throw Usage(description: "\(name): unknown field \(unknown.joined(separator: ", "))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Usage(description: "\(name): \(error)")
        }
    }

    // MARK: - Files and JSON

    private static func read(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CodeAnalysisError.io("\(path): cannot be read")
        }
    }

    private static func write(_ data: Data, to path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw CodeAnalysisError.io("\(path): cannot be written")
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value,
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    private static func errorJSON(_ message: String) -> Data {
        (try? json(["error": message])) ?? Data(message.utf8)
    }
}
