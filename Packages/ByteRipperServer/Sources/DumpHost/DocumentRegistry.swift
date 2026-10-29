import AgentDocuments
import AgentKit
import Foundation
import ToolModuleKit

/// The documents the server holds, and the ids an agent knows them by
/// (`Design/SERVER_HEADLESS_PLAN.md` §6, decisions 9–12 and 18).
///
/// Only the operator changes the set — open by path or by upload, close,
/// reopen, forget, reorder — and every change is written to `documents.json`
/// at once, so ids, hashes and versions survive a restart. An id is never
/// given to another file: new ones come from `next_id`, and a row that cannot
/// be served keeps its id as a "missing" row with the reason.
@MainActor
public final class DocumentRegistry: AgentDocumentSet {
    public enum State {
        case open(DocumentHost)
        case missing(MissingReason)
    }

    /// One document as the console lists it, open or missing.
    public struct Row {
        public let id: String
        public let path: URL
        public let name: String
        /// Uploaded through the console: the one kind the server may delete.
        public let uploaded: Bool
        public fileprivate(set) var sha256: String
        public fileprivate(set) var version: Int
        public fileprivate(set) var stamp: FileStamp?
        public fileprivate(set) var state: State

        public var host: DocumentHost? {
            if case .open(let host) = state { return host }
            return nil
        }
    }

    /// What the operator is told when a change is refused.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    public private(set) var rows: [Row] = []
    private var nextID = 1
    private let roots: [URL]
    /// The roots as the command line gave them, absent ones included: a
    /// document under one is missing for that reason, not because its file
    /// went (`absentRoots`, `MissingReason.rootMissing`).
    private let givenRoots: [URL]
    public let uploads: URL
    private let file: URL
    public let limits: DumpLimits

    /// - Parameters:
    ///   - roots: the `--dump-roots` directories a path must resolve inside.
    ///     One that is not there is kept and reported, not dropped: a typo or
    ///     an unmounted volume must not read as deleted dumps.
    ///   - uploads: `<Server>/Uploads`, the other place a path may be.
    ///   - file: `documents.json`.
    public init(roots: [URL], uploads: URL, file: URL, limits: DumpLimits = DumpLimits()) {
        self.givenRoots = roots
        self.roots = roots.compactMap(Self.resolved)
        self.uploads = uploads
        self.file = file
        self.limits = limits
    }

    /// The `--dump-roots` named that do not resolve now: the server says so
    /// at start, and the documents under them are missing for that reason.
    public var absentRoots: [URL] {
        givenRoots.filter { Self.resolved($0) == nil }
    }

    // MARK: - Restore

    /// Reads `documents.json` and opens its rows in their stored order, each
    /// checked against the roots, read, hashed and admitted if the limits
    /// still allow; a row that is not keeps its id as a missing one. A file
    /// that cannot be read is refused rather than started from empty — that
    /// would hand its ids out again.
    public func restore() async throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let saved: Saved
        do {
            saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
        } catch {
            throw Failure("\(file.path) cannot be read (\(error)); move it aside to start without documents")
        }
        // An id is never given to another file (decision 10): a file that
        // names one twice, or that claims a `next_id` already passed, is not
        // started from — handing a live id to a new document is worse than
        // naming the file to fix.
        let ids = saved.documents.map(\.id)
        guard Set(ids).count == ids.count else {
            throw Failure("\(file.path) names a document id twice; fix it, or move it aside to start without documents")
        }
        let highest = ids.compactMap(Self.number(of:)).max() ?? 0
        nextID = max(saved.nextID, highest + 1)
        rows = []
        for entry in saved.documents {
            var row = Row(id: entry.id, path: URL(fileURLWithPath: entry.path), name: entry.name,
                          uploaded: entry.uploaded, sha256: entry.sha256, version: entry.version,
                          stamp: entry.stamp, state: .missing(entry.missing ?? .gone))
            await admit(&row)
            rows.append(row)
        }
        try save()
    }

    // MARK: - Changes

    /// Opens the file at `path` and answers its id: a new one, or the one it
    /// already has — open, or missing and now back.
    @discardableResult
    public func open(path: URL, name: String? = nil) async throws -> String {
        guard let resolved = Self.resolved(path) else {
            if let root = absentRoot(containing: path) {
                throw Failure(MissingReason.rootMissing(root.path).message)
            }
            throw Failure("\(path.path) does not exist")
        }
        guard isAdmissible(resolved) else {
            throw Failure("\(resolved.path) is outside the dump roots; the server opens only files under "
                + "--dump-roots and its uploads")
        }
        if let index = rows.firstIndex(where: { $0.path == resolved }) {
            if rows[index].host == nil { try await reopen(rows[index].id) }
            return rows[index].id
        }
        guard let stamp = FileStamp.of(resolved), Self.isRegularFile(resolved) else {
            throw Failure("\(resolved.path) is not a file")
        }
        if let limit = exceeded(adding: stamp.size, besides: nil) {
            throw Failure("opening \(resolved.lastPathComponent) would pass \(limit)")
        }
        guard let data = await Self.contents(of: resolved) else {
            throw Failure("\(resolved.path) cannot be read")
        }
        let id = mint()
        let host = DocumentHost(id: id, name: name ?? resolved.lastPathComponent, url: resolved, data: data,
                                stamp: stamp, version: 1)
        rows.append(Row(id: id, path: resolved, name: host.name, uploaded: resolved.deletingLastPathComponent().path == uploadsResolved?.path,
                        sha256: host.sha256, version: 1, stamp: stamp, state: .open(host)))
        try save()
        return id
    }

    /// Keeps `data` as `Uploads/<sha256>` and opens it under `name`. Nothing
    /// a client sends becomes a path: the file is named by its hash. Bytes
    /// already open answer the id they have, and the copy is not kept.
    @discardableResult
    public func upload(_ data: Data, name: String) async throws -> String {
        guard UInt64(data.count) <= limits.uploadBytes else {
            throw Failure("an upload is limited to \(DumpLimits.words(limits.uploadBytes))")
        }
        let sha256 = DocumentHost.hash(data)
        if let row = rows.first(where: { $0.host != nil && $0.sha256 == sha256 }) { return row.id }
        if let limit = exceeded(adding: UInt64(data.count), besides: nil) {
            throw Failure("opening \(name) would pass \(limit)")
        }
        let target = uploads.appendingPathComponent(sha256, isDirectory: false)
        try await Self.writeOffMain(data, to: target)
        return try await open(path: target, name: name)
    }

    /// Reads the file again under the same id, one version on. A file that
    /// is gone makes the row a missing one, its id kept; a missing row is
    /// checked against the roots and the limits again, and opened if it passes.
    public func reopen(_ id: String) async throws {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { throw Failure("no document \(id)") }
        if let host = rows[index].host {
            guard let stamp = FileStamp.of(host.url) else {
                rows[index].state = .missing(reason(for: host.url))
                try save()
                return
            }
            guard let data = await Self.contents(of: host.url) else {
                // There and not readable: no reason of the plan's fits better.
                rows[index].state = .missing(.gone)
                try save()
                return
            }
            if let limit = exceeded(adding: stamp.size, besides: id) {
                throw Failure("reopening \(id) would pass \(limit)")
            }
            host.replace(data: data, stamp: stamp)
            rows[index].sha256 = host.sha256
            rows[index].version = host.version
            rows[index].stamp = stamp
        } else {
            // A copy: admitting reads every row to count the limits.
            var row = rows[index]
            await admit(&row)
            rows[index] = row
        }
        try save()
    }

    /// Closes an open document. Its id is retired with it, not freed.
    public func close(_ id: String) throws {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].host != nil else {
            throw Failure("no open document \(id)")
        }
        rows.remove(at: index)
        try save()
    }

    /// Closes an uploaded document and deletes its file — the only file the
    /// server deletes.
    public func delete(_ id: String) throws {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { throw Failure("no document \(id)") }
        guard rows[index].uploaded else { throw Failure("\(id) was not uploaded; only an upload is deleted") }
        let path = rows[index].path
        rows.remove(at: index)
        try save()
        try? FileManager.default.removeItem(at: path)
    }

    /// Removes a missing row for good; its id is retired with it.
    public func forget(_ id: String) throws {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].host == nil else {
            throw Failure("no missing document \(id)")
        }
        rows.remove(at: index)
        try save()
    }

    /// Puts the rows in the order given — the order a restore admits them in.
    public func reorder(_ ids: [String]) throws {
        guard ids.count == rows.count, Set(ids) == Set(rows.map(\.id)) else {
            throw Failure("the order must name every document once")
        }
        rows.sort { ids.firstIndex(of: $0.id)! < ids.firstIndex(of: $1.id)! }
        try save()
    }

    // MARK: - AgentDocumentSet

    public func documents() -> [any AgentDocument] {
        rows.compactMap { $0.host.map(ServedDocument.init) }
    }

    public func resolve(_ document: String?) throws -> any AgentDocument {
        if let document, let row = rows.first(where: { $0.id == document }), case .missing(let reason) = row.state {
            throw AgentToolError("\(row.name) (\(document)) is not served now: \(reason.message). "
                + "The operator can reopen it in the console.")
        }
        return try AgentDocumentRule.resolve(document, in: documents(),
                                             noneOpen: "No dump is open on this server. The operator opens one in the console.")
    }

    // MARK: - Admission

    /// Opens a missing row if decision 18 and the limits allow, under its id
    /// and with `version` by decision 10: the same bytes keep it, other bytes
    /// raise it by one. The `stat` is taken before the read, so a write that
    /// lands during the read shows as `changed` rather than hiding.
    private func admit(_ row: inout Row) async {
        guard let resolved = Self.resolved(row.path), isAdmissible(resolved) else {
            row.state = .missing(reason(for: row.path))
            return
        }
        guard let stamp = FileStamp.of(resolved) else {
            row.state = .missing(reason(for: row.path))
            return
        }
        if let limit = exceeded(adding: stamp.size, besides: row.id) {
            row.state = .missing(.limit(limit))
            return
        }
        guard let data = await Self.contents(of: resolved) else {
            // There and not readable: no reason of the plan's fits better.
            row.state = .missing(.gone)
            return
        }
        let sha256 = DocumentHost.hash(data)
        let version = sha256 == row.sha256 ? row.version : row.version + 1
        let host = DocumentHost(id: row.id, name: row.name, url: resolved, data: data, stamp: stamp, version: version)
        row.sha256 = sha256
        row.version = version
        row.stamp = stamp
        row.state = .open(host)
    }

    /// The limit opening `size` more bytes would pass, in words; nil when
    /// it fits. `besides` is a row whose own bytes are not counted twice.
    private func exceeded(adding size: UInt64, besides id: String?) -> String? {
        let open = rows.filter { $0.id != id && $0.host != nil }
        if open.count + 1 > limits.documents {
            return "the limit of \(limits.documents) open documents"
        }
        let bytes = open.reduce(UInt64(0)) { $0 + ($1.host?.contentSize ?? 0) }
        if bytes + size > limits.openBytes {
            return "the limit of \(DumpLimits.words(limits.openBytes)) of open documents"
        }
        return nil
    }

    /// Why `path` cannot be served: the root it was opened under is not there,
    /// the file is gone, or the path left the roots.
    private func reason(for path: URL) -> MissingReason {
        guard Self.resolved(path) == nil else { return .outsideRoots }
        if let root = absentRoot(containing: path) { return .rootMissing(root.path) }
        return .gone
    }

    /// The `--dump-roots` entry `path` lies under **and** that is not there —
    /// the one to name instead of "the file is gone". A root that is present
    /// does not match: the file is what went, not the volume.
    private func absentRoot(containing path: URL) -> URL? {
        givenRoots.first { root in
            guard Self.resolved(root) == nil, let guess = Self.resolvedAllowingAbsence(root) else { return false }
            return path.path == guess.path
                || path.path.hasPrefix(guess.path.hasSuffix("/") ? guess.path : guess.path + "/")
        }
    }

    /// Decision 18: the path, symlinks followed, inside a root or the uploads.
    private func isAdmissible(_ resolved: URL) -> Bool {
        (roots + [uploadsResolved].compactMap { $0 }).contains { root in
            resolved.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
        }
    }

    private var uploadsResolved: URL? { Self.resolved(uploads) }

    private func mint() -> String {
        defer { nextID += 1 }
        return "d\(nextID)"
    }

    // MARK: - Files

    /// `realpath`: symlinks followed, nil when the path does not exist.
    nonisolated static func resolved(_ url: URL) -> URL? {
        guard let pointer = realpath(url.path, nil) else { return nil }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }

    /// `realpath` with the leaf allowed to be absent: the nearest existing
    /// ancestor is resolved and the rest put back. A volume that is not
    /// mounted still has the way to it, and `/var` is `/private/var` here.
    nonisolated static func resolvedAllowingAbsence(_ url: URL) -> URL? {
        var components = url.pathComponents
        var absent: [String] = []
        while components.count > 1 {
            if let resolved = resolved(URL(fileURLWithPath: NSString.path(withComponents: components))) {
                return URL(fileURLWithPath: NSString.path(withComponents: [resolved.path] + absent))
            }
            absent.insert(components.removeLast(), at: 0)
        }
        return nil
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// A file read off the main actor: a dump may be hundreds of megabytes,
    /// and that actor also runs the tools and the console. The `stat` is
    /// taken before the read, by the caller (decision 10).
    nonisolated static func contents(of url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
    }

    /// A file written off the main actor: an upload may be a quarter of a
    /// gigabyte.
    nonisolated static func writeOffMain(_ data: Data, to target: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try writePrivately(data, to: target) }.value
    }

    /// The number an id carries: `d12` → 12, nil for anything else.
    nonisolated static func number(of id: String) -> Int? {
        guard id.hasPrefix("d") else { return nil }
        return Int(id.dropFirst())
    }

    /// Written to a temporary file 0600 from its first byte, then renamed
    /// into place, in a folder only this user may enter.
    nonisolated static func writePrivately(_ data: Data, to target: URL) throws {
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Failure("\(temporary.path) cannot be written: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, target.path) == 0 else {
                throw Failure("\(target.path) cannot be written: \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private func save() throws {
        let saved = Saved(nextID: nextID, documents: rows.map { row in
            var missing: MissingReason?
            if case .missing(let reason) = row.state { missing = reason }
            return SavedRow(id: row.id, path: row.path.path, name: row.name, uploaded: row.uploaded,
                            sha256: row.sha256, version: row.version, stamp: row.stamp, missing: missing)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivately(encoder.encode(saved), to: file)
    }

    private struct Saved: Codable {
        var nextID: Int
        var documents: [SavedRow]

        enum CodingKeys: String, CodingKey {
            case nextID = "next_id"
            case documents
        }
    }

    private struct SavedRow: Codable {
        var id: String
        var path: String
        var name: String
        var uploaded: Bool
        var sha256: String
        var version: Int
        var stamp: FileStamp?
        var missing: MissingReason?
    }
}

/// An open document as `AgentDocuments`' tools see it, with the `disk` mark
/// taken at the moment it is asked for.
struct ServedDocument: AgentDocument {
    let host: DocumentHost
    let id: String
    let label: String
    let disk: String?

    @MainActor init(_ host: DocumentHost) {
        self.host = host
        id = host.id
        label = host.name
        disk = host.diskState()?.rawValue
    }

    @MainActor func readHost() -> any ToolReadHost { host }
}
