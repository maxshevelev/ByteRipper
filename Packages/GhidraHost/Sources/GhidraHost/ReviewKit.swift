import AgentKit
import CodeAnalysis
import Foundation

/// The review kit: what an agent on another Mac needs to review on this
/// server — the roles of a review pair and the review rules
/// (`Skills/review-roles`, `Skills/ghidra-uefi`) — served by the server that
/// runs the tools the rules describe, so the two never drift apart.
///
/// Only Markdown goes out: the two roles, `ghidra-uefi/SKILL.md` and its
/// `reference/`. A file is named by its path under the skills folder
/// (`ghidra-uefi/reference/description.md`), and the kit's version is a digest
/// of every path and its content, so a client knows by one string whether its
/// copy is current.
public struct ReviewKit: Equatable, Sendable {
    /// The roles, as prompts: the file under `review-roles/roles/` by the
    /// prompt's name.
    public static let roles: [(name: String, title: String, description: String)] = [
        ("reviewer", "Reviewer",
         "Start this session as the Reviewer of a review pair: review firmware modules through ByteRipper, publish them, report to the Verifier."),
        ("verifier", "Verifier",
         "Start this session as the Verifier of a review pair: check the Reviewer's results against the store, ask for fixes, report to the person.")
    ]
    /// Where the prompts' texts and the rules' files sit under the skills folder.
    static let roleFolder = "review-roles/roles"
    static let rulesFolder = "ghidra-uefi"
    /// The URI a file is offered at as an MCP resource.
    public static let resourceScheme = "byteripper://kit/"

    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let size: Int
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let version: String
        public let files: [File]

        public init(files: [File]) {
            let sorted = files.sorted { $0.path < $1.path }
            self.files = sorted
            let lines = sorted.map { "\($0.path) \($0.sha256)\n" }.joined()
            self.version = String(SHA256Digest(data: Data(lines.utf8)).hex.prefix(16))
        }
    }

    public let manifest: Manifest
    /// Each file's text, by its path.
    public let texts: [String: String]

    public init(texts: [String: String]) {
        self.texts = texts
        manifest = Manifest(files: texts.map { path, text in
            let data = Data(text.utf8)
            return File(path: path, sha256: SHA256Digest(data: data).hex, size: data.count)
        })
    }

    // MARK: - On the server

    /// The kit a skills folder holds. A folder without the roles or the rules
    /// is no kit: the server then answers 404, and a client offers nothing.
    public static func read(skills root: URL) throws -> ReviewKit {
        var texts: [String: String] = [:]
        let manager = FileManager.default
        func add(_ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            texts[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        for role in roles { try add("\(roleFolder)/\(role.name).md") }
        try add("\(rulesFolder)/SKILL.md")
        let reference = root.appendingPathComponent("\(rulesFolder)/reference", isDirectory: true)
        for name in (try? manager.contentsOfDirectory(atPath: reference.path)) ?? [] where name.hasSuffix(".md") {
            try add("\(rulesFolder)/reference/\(name)")
        }
        return ReviewKit(texts: texts)
    }

    /// The skills folder resolved when the server starts, in order:
    /// `$BYTERIPPER_SKILLS`, `skills/` beside the binary's folder (the
    /// distribution's layout), and the checkout this package was built from.
    public static func resolvedSkills() -> URL {
        if let named = ProcessInfo.processInfo.environment["BYTERIPPER_SKILLS"], !named.isEmpty {
            return URL(fileURLWithPath: named, isDirectory: true)
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let beside = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("skills", isDirectory: true)
            if FileManager.default.fileExists(atPath: beside.appendingPathComponent("\(roleFolder)/reviewer.md").path) {
                return beside
            }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GhidraHost
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // GhidraHost package
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // the repository
            .appendingPathComponent("Skills", isDirectory: true)
    }

    // MARK: - As an agent sees it

    /// A role's text for this Mac: `{{mac}}` is the Mac's name, so the pair's
    /// sessions are told apart on the server's console.
    public func prompt(named name: String, mac: String) -> AgentPromptText? {
        guard let role = Self.roles.first(where: { $0.name == name }),
              let text = texts["\(Self.roleFolder)/\(name).md"] else { return nil }
        return AgentPromptText(description: role.description, text: text.replacingOccurrences(of: "{{mac}}", with: mac))
    }

    /// The rules, as MCP resources.
    public var resources: [AgentResource] {
        manifest.files.filter { $0.path.hasPrefix("\(Self.rulesFolder)/") }.map { file in
            AgentResource(uri: Self.resourceScheme + file.path, name: (file.path as NSString).lastPathComponent,
                          title: file.path, description: Self.describe(file.path), size: file.size)
        }
    }

    public func resource(uri: String) -> AgentResourceText? {
        guard uri.hasPrefix(Self.resourceScheme) else { return nil }
        let path = String(uri.dropFirst(Self.resourceScheme.count))
        guard path.hasPrefix("\(Self.rulesFolder)/"), let text = texts[path] else { return nil }
        return AgentResourceText(uri: uri, text: text)
    }

    private static func describe(_ path: String) -> String {
        path == "\(rulesFolder)/SKILL.md"
            ? "The review rules: how a module is reviewed in Ghidra through ByteRipper. Read before the first review."
            : "Reference of the review rules: \((path as NSString).lastPathComponent)."
    }
}

/// The kit as the app keeps it: fetched from the analysis server, checked
/// file by file against the manifest, and kept on disk so a session started
/// while the server cannot be reached still has the last copy.
///
/// A fetch is tried at most once a minute; a failure leaves the copy as it
/// was. Nothing is fetched while no server is named.
public actor ReviewKitCache {
    /// Fetches the manifest and a file; nil when no analysis server is named.
    public struct Source: Sendable {
        public var manifest: @Sendable () async throws -> Data
        public var file: @Sendable (String) async throws -> Data

        public init(manifest: @escaping @Sendable () async throws -> Data,
                    file: @escaping @Sendable (String) async throws -> Data) {
            self.manifest = manifest
            self.file = file
        }
    }

    private let folder: URL
    private let source: @Sendable () async -> Source?
    private let interval: TimeInterval
    private var kit: ReviewKit?
    private var lastTry: Date?

    public init(folder: URL, interval: TimeInterval = 60, source: @escaping @Sendable () async -> Source?) {
        self.folder = folder
        self.interval = interval
        self.source = source
    }

    /// The kit to serve now: fetched again when it is time, otherwise the
    /// copy in memory or on disk. Nil when no server is named — a kit kept
    /// from an earlier server would describe tools that are not there.
    public func current(now: Date = Date()) async -> ReviewKit? {
        guard let source = await source() else { return nil }
        if kit == nil { kit = load() }
        if lastTry.map({ now.timeIntervalSince($0) >= interval }) ?? true {
            lastTry = now
            if let fetched = try? await fetch(source) { kit = fetched }
        }
        return kit
    }

    private func fetch(_ source: Source) async throws -> ReviewKit {
        let manifest = try JSONDecoder().decode(ReviewKit.Manifest.self, from: try await source.manifest())
        if let kit, kit.manifest.version == manifest.version { return kit }
        var texts: [String: String] = [:]
        for file in manifest.files {
            guard Self.safe(file.path) else { throw GhidraHostError(.refused, "\(file.path): not a path of the kit") }
            let reused = kit?.manifest.files.first { $0.path == file.path && $0.sha256 == file.sha256 }
                .flatMap { kit?.texts[$0.path] }
            let data: Data
            if let reused { data = Data(reused.utf8) } else { data = try await source.file(file.path) }
            guard SHA256Digest(data: data).hex == file.sha256, let text = String(data: data, encoding: .utf8) else {
                throw GhidraHostError(.refused, "\(file.path): the kit's file does not match its manifest")
            }
            texts[file.path] = text
        }
        let fetched = ReviewKit(texts: texts)
        guard fetched.manifest == manifest else { throw GhidraHostError(.refused, "the kit does not match its manifest") }
        try save(fetched)
        return fetched
    }

    /// A relative path of Markdown, with no way out of the folder.
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.hasSuffix(".md")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    private var manifestFile: URL { folder.appendingPathComponent("manifest.json") }

    private func save(_ kit: ReviewKit) throws {
        let manager = FileManager.default
        let staged = folder.deletingLastPathComponent()
            .appendingPathComponent(".\(folder.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staged, withIntermediateDirectories: true)
        for (path, text) in kit.texts {
            let url = staged.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(kit.manifest).write(to: staged.appendingPathComponent("manifest.json"))
        if manager.fileExists(atPath: folder.path) {
            _ = try manager.replaceItemAt(folder, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: folder)
        }
    }

    private func load() -> ReviewKit? {
        guard let data = try? Data(contentsOf: manifestFile),
              let manifest = try? JSONDecoder().decode(ReviewKit.Manifest.self, from: data) else { return nil }
        var texts: [String: String] = [:]
        for file in manifest.files where Self.safe(file.path) {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(file.path), encoding: .utf8) else { return nil }
            texts[file.path] = text
        }
        let kit = ReviewKit(texts: texts)
        return kit.manifest == manifest ? kit : nil
    }
}

/// The kit as an MCP server's prompts and resources: the roles for this Mac,
/// the rules of the server the app is connected to.
public struct ReviewKitContent: AgentContent {
    private let cache: ReviewKitCache
    private let mac: @Sendable () async -> String

    public init(cache: ReviewKitCache, mac: @escaping @Sendable () async -> String) {
        self.cache = cache
        self.mac = mac
    }

    public func prompts() async -> [AgentPrompt] {
        guard let kit = await cache.current() else { return [] }
        return ReviewKit.roles.filter { kit.texts["\(ReviewKit.roleFolder)/\($0.name).md"] != nil }
            .map { AgentPrompt(name: $0.name, title: $0.title, description: $0.description) }
    }

    public func prompt(named name: String, arguments: [String: String]) async throws -> AgentPromptText {
        guard let kit = await cache.current() else { throw AgentToolError(Self.noKit) }
        guard let text = kit.prompt(named: name, mac: await mac()) else {
            throw AgentToolError("No prompt named \(name). The analysis server's kit has: "
                + ReviewKit.roles.map(\.name).joined(separator: ", ") + ".")
        }
        return text
    }

    public func resources() async -> [AgentResource] {
        await cache.current()?.resources ?? []
    }

    public func resource(uri: String) async throws -> AgentResourceText {
        guard let kit = await cache.current() else { throw AgentToolError(Self.noKit) }
        guard let text = kit.resource(uri: uri) else {
            throw AgentToolError("No resource \(uri). resources/list names the review kit's files.")
        }
        return text
    }

    static let noKit = "The review kit comes from the analysis server, and Settings ▸ Code Analysis names none "
        + "or it has not been reached yet."
}
