import CodeAnalysis
import Foundation

/// The UEFI pass's typing run again over modules a review has worked on: the
/// PEI Services pointer below the IDT, protocol, PPI and SMST pointers by
/// their GUID or the call they come from — only where a place still has no
/// type (`ApplyUefi.retype`). The person's decision of 2026-11-22: one run on
/// the server over every reviewed module, each module that changed published
/// as a revision of its own, no tool for agents and no console control.
extension GhidraHost {
    /// One module's line of the run.
    public struct RetypeRow: Codable, Equatable, Sendable {
        public var module: String
        public var name: String
        /// Calls the module's own C prints through `(code **)`, before and after.
        public var before: Int
        public var after: Int?
        /// Places the pass typed.
        public var typed: Int
        /// The revision the run published, when it published one.
        public var revision: Int?
        /// `published`, `unchanged`, `leased` (another holder has it),
        /// `refused` (the publish was refused; nothing was kept) or `failed`.
        public var outcome: String
        public var note: String?
        /// Local and parameter names the C showed before and no longer does:
        /// two variables a review named apart that the decompiler now reads as
        /// one, since they hold the same type.
        public var namesGone: [String]
    }

    /// The holder the run takes each module as.
    public static let retypeHolder = "server retype"

    /// Runs the typing over `modules`, or over every reviewed module the store
    /// has a revision of, one at a time: take it, type it, publish it if
    /// anything was typed, give it back. A module another holder has is left
    /// alone. A refused publish discards what the run did to that module — its
    /// working project goes to the Trash — so its next holder opens the last
    /// published revision.
    public func retypeReviewed(_ modules: [SHA256Digest]? = nil, by: String = "server retype",
                               progress: @escaping @Sendable (RetypeRow) -> Void = { _ in }) async throws -> [RetypeRow] {
        let install = try ghidra()
        let paths = try await UEFITypes.ensure(install: install, sources: configuration.sources, progress: { _ in })
        let manifests = try await writer.newestAnalyses()
        let newest = Dictionary(manifests.map { ($0.module.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        let chosen: [SHA256Digest] = modules ?? GhidraProject.all(in: configuration.projectsRoot).compactMap { project in
            guard let state = try? project.state(), state.reviewed == true, state.published != nil else { return nil }
            return project.module
        }.sorted { $0.hex < $1.hex }
        var rows: [RetypeRow] = []
        for module in chosen {
            let row = await retypeOne(module, manifest: newest[module], guids: paths.guidsTSV, by: by)
            rows.append(row)
            progress(row)
        }
        return rows
    }

    /// What `GET …/retype` answers: the rows so far and whether the run is
    /// still going.
    public struct RetypeProgress: Codable, Sendable {
        public var running: Bool
        public var rows: [RetypeRow]
    }

    public func retypeProgress() -> RetypeProgress { RetypeProgress(running: retypeRunning, rows: retypeRows) }

    /// Starts the run over every reviewed module, or `modules`, in the
    /// background, one at a time; refused while one is going. Each row is
    /// also written to `retype-<date>.json` beside the projects, so the table
    /// outlives the process.
    public func startRetype(_ modules: [SHA256Digest]? = nil, by: String) throws {
        guard !retypeRunning else { throw GhidraHostError(.refused, "a retype run is going", status: 409) }
        retypeRunning = true
        retypeRows = []
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = configuration.projectsRoot.appendingPathComponent("retype-\(stamp).json")
        Task {
            _ = try? await self.retypeReviewed(modules, by: by) { row in
                Task { await self.noteRetype(row, file: file) }
            }
            await self.finishRetype()
        }
    }

    private func noteRetype(_ row: RetypeRow, file: URL) {
        retypeRows.append(row)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(retypeRows).write(to: file, options: .atomic)
    }

    private func finishRetype() { retypeRunning = false }

    private func retypeOne(_ module: SHA256Digest, manifest: AnalysisManifest?, guids: URL,
                           by: String) async -> RetypeRow {
        let state = try? project(module).state()
        let name = state?.module.name ?? manifest?.module.name ?? module.hex
        let beforeArtifact = await storedArtifactJSON(manifest)
        var row = RetypeRow(module: module.hex, name: name, before: Self.rawCalls(in: beforeArtifact),
                            after: nil, typed: 0, revision: nil, outcome: "failed", note: nil, namesGone: [])
        if let held = leaseBook.leases[module.hex], held.holder != Self.retypeHolder {
            row.outcome = "leased"
            row.note = "held by \(held.holder)"
            return row
        }
        let wasRunning = await runningOwner(project(module)) != nil
        defer { if !wasRunning { Task { await self.stop(module) } } }
        do {
            _ = try await take(module, holder: Self.retypeHolder)
        } catch {
            row.note = "take: \((error as? GhidraHostError)?.message ?? "\(error)")"
            return row
        }
        do {
            // Library functions read as their registry entry's text: the run
            // leaves them as they are.
            let linked = (beforeArtifact?["functions"] as? [[String: Any]] ?? []).compactMap { function in
                function["registry"] != nil ? function["entry"] as? String : nil
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "guids": guids.path, "phase": state?.module.phase ?? "dxe", "skip": linked])
            let answer = try await write(module, "/v1/uefi/retype", body: body, holder: Self.retypeHolder)
            let typed = ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])?["typed"] as? Int ?? 0
            row.typed = typed
            if typed == 0 {
                // Nothing typed: the lease changed nothing, and its release
                // publishes nothing.
                _ = try await release(module, by: by, holder: Self.retypeHolder)
                row.outcome = "unchanged"
                row.after = row.before
                return row
            }
            let publication = try await release(module, by: by, holder: Self.retypeHolder)
            let afterArtifact = await storedArtifactJSON(publication?.manifest)
            row.revision = publication?.manifest.reading?.rev
            if row.revision == nil, publication != nil {
                row.revision = (try? await writer.latestRevision(module: module))?.rev
            }
            row.after = Self.rawCalls(in: afterArtifact)
            row.namesGone = Self.namesGone(from: beforeArtifact, to: afterArtifact)
            row.outcome = publication == nil ? "unchanged" : "published"
            return row
        } catch {
            row.outcome = "refused"
            row.note = (error as? GhidraHostError)?.message ?? "\(error)"
            _ = try? await release(module, by: by, holder: Self.retypeHolder, discard: true)
            return row
        }
    }

    private func storedArtifactJSON(_ manifest: AnalysisManifest?) async -> [String: Any]? {
        guard let manifest, let data = try? await writer.readObject(manifest.artifact.sha256) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Lines of the module's own C that call through `(code **)`: a call
    /// whose target the decompiler could not name. Library functions read as
    /// their entry's text and are not counted.
    static func rawCalls(in artifact: [String: Any]?) -> Int {
        var count = 0
        for function in artifact?["functions"] as? [[String: Any]] ?? [] {
            guard let c = function["c"] as? String else { continue }
            count += c.split(separator: "\n").filter { $0.contains("(code **)") }.count
        }
        return count
    }

    /// `Function: Name` for every local or parameter name the C showed
    /// before and does not after.
    static func namesGone(from before: [String: Any]?, to after: [String: Any]?) -> [String] {
        func names(_ artifact: [String: Any]?) -> [String: Set<String>] {
            var found: [String: Set<String>] = [:]
            for function in artifact?["functions"] as? [[String: Any]] ?? [] {
                guard let c = function["c"] as? String, let entry = function["entry"] as? String else { continue }
                let text = Array(c.utf16)
                var set = Set<String>()
                for span in function["c_spans"] as? [[Any]] ?? [] {
                    guard span.count >= 3, let start = span[0] as? Int, let length = span[1] as? Int,
                          let kind = span[2] as? String, kind == "local" || kind == "parameter",
                          start >= 0, start + length <= text.count else { continue }
                    set.insert(String(decoding: text[start..<(start + length)], as: UTF16.self))
                }
                found["\(function["name"] as? String ?? entry)"] = set
            }
            return found
        }
        let old = names(before), new = names(after)
        var gone: [String] = []
        for (function, set) in old.sorted(by: { $0.key < $1.key }) {
            guard let now = new[function] else { continue }
            for name in set.subtracting(now).sorted() { gone.append("\(function): \(name)") }
        }
        return gone
    }
}
