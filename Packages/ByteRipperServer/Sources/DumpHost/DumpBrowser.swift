import Foundation

/// The folders under `--dump-roots`, as the console's file browser walks them
/// (`Design/SERVER_HEADLESS_PLAN.md` §8): the roots at the top, then a
/// folder's folders and files.
///
/// Only a folder inside a root is listed — the same `realpath` rule as
/// opening (decision 18), so `..` and a symlink cannot walk out of one. An
/// entry whose link leads outside every root is listed, so the operator sees
/// it is there, and marked: opening it would be refused anyway.
public struct DumpBrowser: Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case root
            case folder
            case file
        }

        public let name: String
        /// The path to open or to list next, symlinks followed.
        public let path: String
        public let kind: Kind
        public let size: UInt64?
        public let modified: Date?
        /// A root that does not resolve, or a link that leads out of every
        /// root: listed, not entered and not opened.
        public let unavailable: String?
    }

    public struct Listing: Equatable, Sendable {
        /// The folder listed, resolved; nil for the top, the roots.
        public let path: String?
        /// The root the folder is in; nil for the top.
        public let root: String?
        /// The folder above, while it is still inside the root; nil at a
        /// root (the way up is the top) and at the top.
        public let parent: String?
        public let entries: [Entry]
        /// More entries than `limit` were there: the rest are not listed.
        public let truncated: Bool
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The most entries one folder lists: a folder of dumps is tens, and a
    /// folder of hundreds of thousands is not one to browse.
    public static let limit = 2000

    let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots
    }

    /// The top — the roots — when `path` is nil, else the folder `path`,
    /// which must resolve inside a root.
    public func list(_ path: String?) throws -> Listing {
        guard let path, !path.isEmpty else { return top() }
        guard let folder = DocumentRegistry.resolved(URL(fileURLWithPath: path)) else {
            throw Refusal(description: "\(path) is not there")
        }
        guard let root = root(of: folder) else {
            throw Refusal(description: "\(folder.path) is outside the dump roots")
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Refusal(description: "\(folder.path) is not a folder")
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw Refusal(description: "\(folder.path) cannot be read: \(error.localizedDescription)")
        }
        var entries: [Entry] = []
        for name in names where !name.hasPrefix(".") {
            if let entry = entry(name, in: folder) { entries.append(entry) }
        }
        entries.sort { a, b in
            a.kind != b.kind ? a.kind == .folder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let truncated = entries.count > Self.limit
        let parent = folder.path == root.path ? nil : folder.deletingLastPathComponent().path
        return Listing(path: folder.path, root: root.path, parent: parent,
                       entries: Array(entries.prefix(Self.limit)), truncated: truncated)
    }

    private func top() -> Listing {
        let entries = roots.map { root -> Entry in
            guard let resolved = DocumentRegistry.resolved(root) else {
                return Entry(name: root.path, path: root.path, kind: .root, size: nil, modified: nil,
                             unavailable: "not there — not mounted, or mistyped")
            }
            return Entry(name: root.path, path: resolved.path, kind: .root, size: nil,
                         modified: Self.modified(resolved), unavailable: nil)
        }
        return Listing(path: nil, root: nil, parent: nil, entries: entries, truncated: false)
    }

    /// One entry of `folder`: a folder or a regular file, a link followed to
    /// what it names. Anything else — a socket, a device — is not listed.
    private func entry(_ name: String, in folder: URL) -> Entry? {
        let url = folder.appendingPathComponent(name)
        guard let resolved = DocumentRegistry.resolved(url) else { return nil }
        guard let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                                 .fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        let outside = root(of: resolved) == nil ? "a link out of the dump roots" : nil
        if values.isDirectory == true {
            return Entry(name: name, path: resolved.path, kind: .folder, size: nil,
                         modified: values.contentModificationDate, unavailable: outside)
        }
        guard values.isRegularFile == true else { return nil }
        return Entry(name: name, path: resolved.path, kind: .file, size: values.fileSize.map(UInt64.init),
                     modified: values.contentModificationDate, unavailable: outside)
    }

    /// The resolved root `resolved` lies in, itself included.
    func root(of resolved: URL) -> URL? {
        for root in roots {
            guard let base = DocumentRegistry.resolved(root) else { continue }
            if resolved.path == base.path
                || resolved.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") {
                return base
            }
        }
        return nil
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
