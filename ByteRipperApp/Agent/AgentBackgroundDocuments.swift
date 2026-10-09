import Foundation
import ByteRipperCore

/// Files an agent opened by path, with no window (`Design/AGENT_PLAN.md`,
/// "Background documents and surveys").
///
/// Each is a `PaneViewModel` that no window shows — the same document, the
/// same chunked storage and the same shared UEFI tree an open file has, so the
/// tool-modules' queries answer about it exactly as they would on screen, and
/// nothing reads a file a second way. Read-only by use: nothing here writes,
/// and the tools that would refuse a document that is not on screen.
///
/// Kept least recently used first, up to `limit`: a survey over fifty dumps
/// must not end holding fifty parsed images. A file changed on disk since it
/// was opened is read again the next time it is asked for, and keeps its id.
@MainActor
final class AgentBackgroundDocuments {
    /// How many are kept parsed at once.
    var limit = 8

    @MainActor final class Entry {
        let pane = PaneViewModel()
        let url: URL
        var modified: Date?
        var lastUsed = Date()

        init(url: URL) {
            self.url = url
        }
    }

    private(set) var entries: [Entry] = []

    /// The file at `path`, opened or already open. Throws what opening it
    /// threw — no such file, not readable.
    func open(_ url: URL) throws -> Entry {
        let url = url.standardizedFileURL
        let modified = Self.modificationDate(of: url)
        if let entry = entries.first(where: { $0.url == url }) {
            if entry.modified != modified {
                try entry.pane.open(url: url)
                entry.modified = modified
            }
            entry.lastUsed = Date()
            return entry
        }
        let entry = Entry(url: url)
        try entry.pane.open(url: url)
        entry.modified = modified
        entries.append(entry)
        evict(keeping: entry)
        return entry
    }

    /// Marks `pane`'s entry as just used, reading the file again if it changed
    /// on disk. False when it is not one of these.
    @discardableResult
    func touch(_ pane: PaneViewModel) -> Bool {
        guard let entry = entries.first(where: { $0.pane === pane }) else { return false }
        _ = try? open(entry.url)
        return true
    }

    func close(_ pane: PaneViewModel) {
        guard let index = entries.firstIndex(where: { $0.pane === pane }) else { return }
        entries[index].pane.close()
        entries.remove(at: index)
    }

    func closeAll() {
        for entry in entries { entry.pane.close() }
        entries.removeAll()
    }

    private func evict(keeping kept: Entry) {
        while entries.count > limit {
            guard let oldest = entries.filter({ $0 !== kept }).min(by: { $0.lastUsed < $1.lastUsed }) else { return }
            close(oldest.pane)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
