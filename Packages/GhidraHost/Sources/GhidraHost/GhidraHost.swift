import CodeAnalysis
import Darwin
import Foundation

/// The owners of the modules' kept projects, hosted: started on demand,
/// called over loopback, written to under one lease per module, published
/// into a store (`Design/SERVER_PLAN.md` §6, the Swift side of
/// `ghidra_owner.py`).
///
/// The host holds the lease, not its client: it takes it on the first write
/// to a module, keeps it while writes come, and gives it back — publishing —
/// when the client is done. A client never sees a token (§7.3).
public actor GhidraHost {
    public struct Configuration: Sendable {
        public var projectsRoot: URL
        /// Nil: `GhidraInstall.find`'s choice.
        public var ghidraHome: URL?
        public var sources: OwnerSources
        /// Seconds without a call before an owner saves and exits; 0 never.
        public var idle: Int
        /// Who holds the leases the host takes, as the owner logs them.
        public var holder: String
        public var startTimeout: TimeInterval

        public init(projectsRoot: URL = GhidraHost.defaultProjectsRoot, ghidraHome: URL? = nil,
                    sources: OwnerSources = .checkout, idle: Int = 1800,
                    holder: String = "\(NSUserName()) via byteripper-server",
                    startTimeout: TimeInterval = 300) {
            self.projectsRoot = projectsRoot
            self.ghidraHome = ghidraHome
            self.sources = sources
            self.idle = idle
            self.holder = holder
            self.startTimeout = startTimeout
        }
    }

    public static var defaultProjectsRoot: URL {
        CodeAnalysisPaths.defaultRoot.deletingLastPathComponent()
            .appendingPathComponent("GhidraProjects", isDirectory: true)
    }

    /// What a publish stored, and the review types another review defines
    /// differently, which stayed in this program (§6.5).
    public struct Publication: Sendable {
        public var manifest: AnalysisManifest
        public var typeConflicts: [String]
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var module: String
        public var name: String
        public var running: Bool
        public var reviewed: Bool
        public var published: ProjectState.Published?
        public var leased: Bool
    }

    public let configuration: Configuration
    private let writer: AnalysisWriter
    private var install: GhidraInstall?
    private var leases: [SHA256Digest: String] = [:]
    private var starting: [SHA256Digest: Task<OwnerRecord, Error>] = [:]

    public init(configuration: Configuration = Configuration(), writer: AnalysisWriter) {
        self.configuration = configuration
        self.writer = writer
    }

    public func ghidra() throws -> GhidraInstall {
        if let install { return install }
        let found = try GhidraInstall.find(home: configuration.ghidraHome)
        install = found
        return found
    }

    public func project(_ module: SHA256Digest) -> GhidraProject {
        GhidraProject(root: configuration.projectsRoot, module: module)
    }

    // MARK: - The projects

    public func summaries() async -> [Summary] {
        var rows: [Summary] = []
        for project in GhidraProject.all(in: configuration.projectsRoot) {
            guard let state = try? project.state() else { continue }
            rows.append(Summary(module: project.module.hex, name: state.module.name,
                                running: await runningOwner(project) != nil, reviewed: state.reviewed,
                                published: state.published, leased: leases[project.module] != nil))
        }
        return rows
    }

    // MARK: - Calls

    /// A read call of the bridge (`/v1/hello`, `/v1/function/0x…`), starting
    /// the module's owner when none runs.
    public func read(_ module: SHA256Digest, _ path: String) async throws -> Data {
        let record = try await owner(of: module)
        return try await Self.call(record.port, "GET", path).data
    }

    /// A write call of the bridge, under the host's lease of the module.
    public func write(_ module: SHA256Digest, _ path: String, body: Data) async throws -> Data {
        let project = self.project(module)
        let record = try await owner(of: module)
        var token = try await lease(module, record)
        let answer: Data
        do {
            answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
        } catch let error as GhidraHostError where error.status == 403 {
            // The lease lapsed between two writes: take it again, once.
            leases[module] = nil
            token = try await lease(module, record)
            answer = try await Self.call(record.port, "POST", path, body: body, lease: token).data
        }
        var state = try project.state()
        if !state.reviewed {
            state.reviewed = true
            try project.write(state)
        }
        return answer
    }

    private func lease(_ module: SHA256Digest, _ record: OwnerRecord) async throws -> String {
        if let token = leases[module] { return token }
        let body = try JSONSerialization.data(withJSONObject: ["holder": configuration.holder, "ttl": 3600])
        let data = try await Self.call(record.port, "POST", "/v1/lease", body: body).data
        guard let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = answer["token"] as? String else {
            throw GhidraHostError(.owner, "the owner gave no lease token")
        }
        leases[module] = token
        return token
    }

    // MARK: - Publish

    /// The program's artifact, its review document and the module's
    /// description, from the owner, into the store — `ghidra_owner.publish`,
    /// step for step.
    ///
    /// A program nobody has reviewed publishes the mechanical reading. A
    /// reviewed one publishes a revision of this project's reading — one more
    /// than the last whenever the artifact, the document or the description
    /// changed — naming the document and the description, which are stored
    /// first, then recorded in the module's history with `by`. The recipe takes the exporter and the Ghidra from the
    /// artifact, the types and passes from what made the project (§5.2).
    public func publish(_ module: SHA256Digest, by: String?) async throws -> Publication {
        let project = self.project(module)
        let record = try await owner(of: module)
        var state = try project.state()
        let (raw, headers) = try await Self.call(record.port, "POST", "/v1/publish", timeout: 3600)
        let document = try await Self.call(record.port, "GET", "/v1/review").data
        let description = try await Self.call(record.port, "GET", "/v1/review/description").data
        guard let artifact = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw GhidraHostError(.owner, "the owner's artifact is not a JSON object")
        }
        let reviewed = headers["x-owner-reviewed"] == "true"
        let conflicts = (headers["x-owner-type-conflicts"] ?? "").split(separator: ",").map(String.init)
        let last = state.published
        var reading: AnalysisReading?
        var review: SHA256Digest?
        var described: SHA256Digest?
        if reviewed {
            let stored = try await writer.writeObject(document)
            review = stored
            if !description.isEmpty { described = try await writer.writeObject(description) }
            let changed = last?.artifact != SHA256Digest(data: raw).hex || last?.review != stored.hex
                || last?.description != described?.hex
            let rev = max(1, (last?.rev ?? 0) + (changed ? 1 : 0))
            let current = AnalysisReading(project: state.project, rev: rev, review: stored, description: described)
            reading = current
            try await writer.writeRevision(module: module, reading: current, by: by)
        }
        let recipe = Self.recipe(for: artifact, types: state.madeWith.types, passes: state.madeWith.passes)
        let program = artifact["program"] as? [String: Any] ?? [:]
        let identity = ModuleIdentity(sha256: module, size: state.module.size, name: state.module.name,
                                      kind: state.module.kind,
                                      language: program["language"] as? String ?? "unknown",
                                      imageBase: program["image_base"] as? String ?? "0x0",
                                      phase: state.module.phase)
        // A mechanical artifact never replaces another — except this project's
        // own last publish, which a new one of the same program supersedes.
        let stored = try await writer.storedAnalysis(module: module, recipe: recipe.id)
        let ours = stored != nil && last != nil && stored?.artifact.sha256.hex == last?.artifact
        let source = SourceIdentity(path: state.source?.path, document: state.source?.document,
                                    node: state.source?.node)
        let manifest = try await writer.writeAnalysis(module: identity, recipe: recipe, artifact: raw,
                                                      source: source, reading: reading, replace: ours)
        state.published = .init(artifact: manifest.artifact.sha256.hex, recipe: recipe.id, review: review?.hex,
                                description: described?.hex, rev: reading?.rev, at: Self.now())
        state.reviewed = reviewed
        try project.write(state)
        return Publication(manifest: manifest, typeConflicts: conflicts)
    }

    /// Publish what the lease changed and give the lease back; nil when the
    /// host holds no lease of the module.
    public func release(_ module: SHA256Digest, by: String?) async throws -> Publication? {
        guard let token = leases[module], let record = await runningOwner(project(module)) else {
            leases[module] = nil
            return nil
        }
        let publication = try await publish(module, by: by)
        leases[module] = nil
        _ = try? await Self.call(record.port, "DELETE", "/v1/lease", lease: token)
        return publication
    }

    /// Save and stop the module's owner.
    @discardableResult
    public func stop(_ module: SHA256Digest) async -> Bool {
        let project = self.project(module)
        guard let record = await runningOwner(project) else { return false }
        leases[module] = nil
        if (try? await Self.call(record.port, "POST", "/v1/stop", timeout: 30)) == nil {
            kill(record.pid, SIGTERM)
        }
        for _ in 0..<100 where Subprocess.isAlive(record.pid) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? FileManager.default.removeItem(at: project.ownerURL)
        return true
    }

    // MARK: - Owners

    /// The module's running owner, or a new one.
    func owner(of module: SHA256Digest) async throws -> OwnerRecord {
        let project = self.project(module)
        guard project.exists else {
            throw GhidraHostError(.project, "no project for \(module.hex): open the module first", status: 404)
        }
        if let running = await runningOwner(project, replacingStale: true) { return running }
        if let pending = starting[module] { return try await pending.value }
        // A live owner that does not answer is busy — a publish exporting a
        // large module — not gone: a second one would only fail on Ghidra's
        // project lock.
        if let data = try? Data(contentsOf: project.ownerURL),
           let record = try? JSONDecoder().decode(OwnerRecord.self, from: data), Subprocess.isAlive(record.pid) {
            throw GhidraHostError(.owner, "the module's owner is busy — a publish of a large module can take a "
                                  + "while; try again shortly", status: 503)
        }
        let task = Task { try await self.start(project) }
        starting[module] = task
        defer { starting[module] = nil }
        return try await task.value
    }

    /// A recorded owner whose process lives and answers; nil otherwise.
    ///
    /// With `replacingStale`, an owner running from another build of the jar
    /// than the one the host would start now — one that outlived a server
    /// restarted on new sources — is stopped, so the caller starts a new one:
    /// an old owner would publish with the old exporter. It saves on the way
    /// out, so nothing written is lost.
    func runningOwner(_ project: GhidraProject, replacingStale: Bool = false) async -> OwnerRecord? {
        guard let data = try? Data(contentsOf: project.ownerURL),
              let record = try? JSONDecoder().decode(OwnerRecord.self, from: data) else { return nil }
        guard Subprocess.isAlive(record.pid) else {
            try? FileManager.default.removeItem(at: project.ownerURL)
            leases[project.module] = nil
            return nil
        }
        guard let hello = try? await Self.call(record.port, "GET", "/v1/hello", timeout: 5) else { return nil }
        guard replacingStale, let current = try? OwnerBuild.build(for: ghidra(), sources: configuration.sources) else {
            return record
        }
        let running = (try? JSONSerialization.jsonObject(with: hello.data) as? [String: Any])?["build"] as? Int
        guard running != current else { return record }
        _ = try? await Self.call(record.port, "POST", "/v1/stop", timeout: 60)
        for _ in 0..<120 where Subprocess.isAlive(record.pid) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? FileManager.default.removeItem(at: project.ownerURL)
        leases[project.module] = nil
        return nil
    }

    private func start(_ project: GhidraProject) async throws -> OwnerRecord {
        let install = try ghidra()
        let jar = try OwnerBuild.jar(for: install, sources: configuration.sources)
        let state = try project.state()
        var arguments = ["-Xmx4G", "-Djava.awt.headless=true",
                         "-cp", (install.classpath() + [jar.path]).joined(separator: ":"), "Owner",
                         "--project-dir", project.folder.path, "--project-name", GhidraProject.name,
                         "--program", state.program, "--module", project.module.hex,
                         "--project-id", state.project]
        if let archive = Self.typeArchive(for: state) {
            arguments += ["--types", archive.path]
        }
        arguments += ["--review-types", configuration.projectsRoot.path,
                      "--port", "0", "--idle", String(configuration.idle)]
        let log = project.folder.appendingPathComponent("owner.log")
        let process = try Subprocess.spawn(install.java, arguments, log: log, ownSession: true)
        let deadline = Date().addingTimeInterval(configuration.startTimeout)
        while true {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("OWNER READY ") }),
               let port = Int(line.split(separator: " ").last ?? "") {
                let record = OwnerRecord(pid: process.pid, port: port, startedAt: Self.now())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try (encoder.encode(record) + Data("\n".utf8)).write(to: project.ownerURL, options: .atomic)
                return record
            }
            if !process.isRunning {
                let tail = text.split(separator: "\n").suffix(20).joined(separator: "\n")
                throw GhidraHostError(.owner, "the owner exited before serving:\n\(tail)")
            }
            if Date() > deadline {
                process.terminate()
                throw GhidraHostError(.owner, "the owner did not serve within \(Int(configuration.startTimeout)) s; "
                                      + "log: \(log.path)")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The EDK2 archive the program was typed with: the one `state.json`
    /// names, or — moved or never recorded — the one of the same tag in the
    /// types cache, for the module's pointer size.
    static func typeArchive(for state: ProjectState) -> URL? {
        if let named = state.archive, FileManager.default.fileExists(atPath: named) {
            return URL(fileURLWithPath: named)
        }
        guard let tag = state.madeWith.types else { return nil }
        let bits = state.module.kind == "TE" || state.module.phase == "pei" ? "Ia32" : "X64"
        let cached = UEFITypes.cacheRoot.appendingPathComponent("uefi_\(bits)-\(tag).gdt")
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    // MARK: - The bridge

    /// One call of an owner on loopback; a refusal is a `GhidraHostError`
    /// with the owner's status and words.
    static func call(_ port: Int, _ method: String, _ path: String, body: Data? = nil, lease: String? = nil,
                     timeout: TimeInterval = 600) async throws -> (data: Data, headers: [String: String]) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw GhidraHostError(.owner, "\(path) is not a path of the bridge", status: 400)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body ?? (method == "POST" ? Data() : nil)
        if let lease { request.setValue(lease, forHTTPHeaderField: "X-Lease") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GhidraHostError(.owner, "the owner on port \(port) does not answer: \(error.localizedDescription)")
        }
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GhidraHostError(.refused, message, status: http.statusCode)
        }
        return (data, headers)
    }

    // MARK: -

    /// `code_artifact.recipe_for`: the exporter and the Ghidra that wrote the
    /// artifact, and what the program was typed with when the UEFI pass ran;
    /// a types revision past the first (`…-r2`) is in the id too.
    static func recipe(for artifact: [String: Any], types: String?, passes: [String]) -> AnalysisRecipe {
        let exporter = artifact["script_version"] as? Int ?? 0
        let ghidra = artifact["ghidra"] as? String
        var id = "code-v\(exporter)-ghidra-\(safeRecipe(ghidra ?? "unknown"))"
        if let types {
            if let dash = types.range(of: "-r", options: .backwards),
               let revision = Int(types[dash.upperBound...]) {
                id = id.replacingOccurrences(of: "-ghidra-", with: "-types\(revision)-ghidra-")
            }
        } else {
            id = id.replacingOccurrences(of: "-ghidra-", with: "-plain-ghidra-")
        }
        return AnalysisRecipe(id: id, exporter: exporter, ghidra: ghidra ?? "unknown", script: "ExportCode.java",
                              types: types, passes: types == nil ? nil : (passes.isEmpty ? ["ApplyUefi.java"] : passes))
    }

    /// `cas._safe_recipe`: runs of anything but letters, digits, `.`, `_`
    /// and `-` become one `-`.
    static func safeRecipe(_ text: String) -> String {
        var out = ""
        var inRun = false
        for scalar in text.unicodeScalars {
            let ok = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._-".unicodeScalars.contains(scalar)
            if ok {
                out.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                out += "-"
                inRun = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00")
    }
}
