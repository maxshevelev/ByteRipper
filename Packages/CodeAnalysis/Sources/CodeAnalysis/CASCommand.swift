import Foundation

/// The store as a command line: what `byteripper-cas` runs, and what the
/// skill's Python calls instead of a store of its own.
///
/// Every answer is JSON on standard output — an object's bytes are the one
/// exception — and every refusal is `{"error": "…"}` on standard error with a
/// non-zero status: 1 for what the store refused, 2 for a command it does not
/// know. An argument the store does not know is refused, never dropped, so a
/// field the Python side adds cannot vanish from a manifest unseen.
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
    }

    static let usage = """
        usage: byteripper-cas [--store <root>] [--no-create] <command>
          hello
          put-object <file>
          has-object <sha256>
          get-object <sha256> [--out <file>]
          put-analysis --module <json> --recipe <json> --artifact <file>
                       [--source <json>] [--reading <json>] [--replace] [--discard-reading]
          analysis <module-sha> [--recipe <id>]
          recipes <module-sha>
          list
          conflicts
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
            let root = parser.option("--store").map { URL(fileURLWithPath: $0) }
                ?? CodeAnalysisPaths.defaultRoot
            let create = !parser.flag("--no-create")
            guard let command = parser.next() else { throw Usage(description: usage) }
            try execute(command, &parser, root: root, create: create, into: &output)
        } catch let usage as Usage {
            output.stdout = Data()
            output.stderr = errorJSON(usage.description)
            output.status = 2
        } catch {
            output.stdout = Data()
            output.stderr = errorJSON("\(error)")
            output.status = 1
        }
        return output
    }

    // MARK: - Commands

    private static func execute(_ command: String, _ parser: inout Arguments, root: URL,
                                create: Bool, into output: inout Output) throws {
        func store() throws -> ContentStore { try ContentStore(root: root, create: create) }
        switch command {
        case "hello":
            try parser.end()
            output.stdout = try json([
                "protocol": protocolVersion,
                "schema": CodeAnalysisSchema.current,
                "store": root.standardizedFileURL.path
            ] as [String: Any])
        case "put-object":
            let file = try parser.required("a file")
            try parser.end()
            let data = try read(file)
            let digest = try store().putObject(data)
            output.stdout = try json(["sha256": digest.hex, "size": data.count] as [String: Any])
        case "has-object":
            let digest = try digestArgument(&parser)
            try parser.end()
            output.stdout = try json(["present": try store().hasObject(digest)])
        case "get-object":
            let digest = try digestArgument(&parser)
            let out = parser.option("--out")
            try parser.end()
            let data = try store().object(digest)
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
                try decode($0, "--reading", keys: ["project", "rev", "review"])
            }
            let replace = parser.flag("--replace")
            let discardReading = parser.flag("--discard-reading")
            try parser.end()
            let manifest = try store().putAnalysis(
                module: module, recipe: recipe, artifact: try read(artifact), source: source,
                reading: reading, replace: replace, discardReading: discardReading)
            output.stdout = try encode(manifest)
        case "analysis":
            let module = try digestArgument(&parser)
            let recipe = parser.option("--recipe")
            try parser.end()
            let store = try store()
            let manifest = try recipe.map { try store.analysis(module: module, recipe: $0) }
                ?? store.analysis(module: module)
            output.stdout = try manifest.map(encode) ?? Data("null\n".utf8)
        case "recipes":
            let module = try digestArgument(&parser)
            try parser.end()
            output.stdout = try encode(try store().recipes(ofModule: module))
        case "list":
            try parser.end()
            output.stdout = try encode(try store().analyses())
        case "conflicts":
            try parser.end()
            output.stdout = try encode(try store().conflicts())
        case "set-ref":
            let name = try parser.required("a reference name")
            let keys = try parser.rest().map(keyArgument)
            guard !keys.isEmpty else { throw Usage(description: "set-ref: name at least one analysis") }
            output.stdout = try encode(try store().setRef(name, analyses: keys))
        case "refs":
            try parser.end()
            output.stdout = try encode(try store().refs())
        case "remove-ref":
            let name = try parser.required("a reference name")
            try parser.end()
            output.stdout = try json(["removed": try store().removeRef(name)])
        case "verify":
            try parser.end()
            output.stdout = try json(["problems": try store().verify()])
        case "gc":
            let apply = parser.flag("--apply")
            let analyses = parser.flag("--analyses")
            try parser.end()
            output.stdout = try encode(try store().collectGarbage(
                dryRun: !apply, deleteUnreferencedAnalyses: analyses))
        case "export":
            guard let out = parser.option("--out") else {
                throw Usage(description: "export: --out is required")
            }
            let keys = try parser.rest().map(keyArgument)
            guard !keys.isEmpty else { throw Usage(description: "export: name at least one analysis") }
            output.stdout = try encode(try store().exportBundle(keys, to: URL(fileURLWithPath: out)))
        case "import":
            let file = try parser.required("a bundle")
            try parser.end()
            output.stdout = try encode(try store().importBundle(from: URL(fileURLWithPath: file)))
        default:
            throw Usage(description: "unknown command \(command)\n\(usage)")
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
