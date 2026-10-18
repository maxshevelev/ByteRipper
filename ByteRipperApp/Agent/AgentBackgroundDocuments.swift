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
/// Let go least recently used first, past either of two bounds the person
/// sets in Settings ▸ Agent (`AgentService`): how many files, and how much
/// memory they hold between them. A survey over fifty dumps must not end
/// holding fifty parsed images. The file asked about last is kept whatever it
/// holds. A file let go keeps its id (`AgentDesk`): named again, it is read
/// again. A file changed on disk since it was opened is read again the next
/// time it is asked for, and keeps its id.
@MainActor
final class AgentBackgroundDocuments {
    /// How many are kept parsed at once.
    var fileLimit = AgentBackgroundLimits.defaultFiles {
        didSet { trim() }
    }
    /// How many bytes they may hold between them (`Entry.heldBytes`).
    var memoryLimit = AgentBackgroundLimits.defaultMemoryMiB(physicalMemory: ProcessInfo.processInfo.physicalMemory) << 20 {
        didSet { trim() }
    }
    /// Told of each file let go to stay inside the bounds — not of one
    /// closed on purpose.
    var onRelease: ((Entry) -> Void)?

    @MainActor final class Entry {
        let pane = PaneViewModel()
        let url: URL
        var modified: Date?
        /// When it was last asked about, on `clock`.
        var lastUsed = 0
        /// The agent's name for it (`AgentDesk.id(of:)`), once it has one.
        var id: String?

        init(url: URL) {
            self.url = url
        }

        /// The bytes it holds in memory: what was read of the file, and what
        /// its compressed sections decompressed to. Its tree's nodes and the
        /// ME analysis are not counted; beside the buffers they are small.
        var heldBytes: Int {
            let file = (pane.document?.storage as? EditOverlayStorage)?.residentByteCount ?? 0
            return file + (pane.uefiState.tree?.decompressedByteCount ?? 0)
        }
    }

    private(set) var entries: [Entry] = []
    /// Counts the uses, so the last one is told apart from the one before
    /// even within a clock tick.
    private var clock = 0

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
            clock += 1
            entry.lastUsed = clock
            return entry
        }
        let entry = Entry(url: url)
        try entry.pane.open(url: url)
        entry.modified = modified
        clock += 1
        entry.lastUsed = clock
        entries.append(entry)
        trim()
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

    /// What they hold between them.
    var heldBytes: Int {
        entries.reduce(0) { $0 + $1.heldBytes }
    }

    /// Lets go of the least recently used until both bounds hold, keeping the
    /// one used last. Run after every call too: a file grows as it is asked
    /// about — a tree opened, a section decompressed.
    func trim() {
        guard let kept = entries.max(by: { $0.lastUsed < $1.lastUsed }) else { return }
        var held = heldBytes
        while entries.count > fileLimit || held > memoryLimit {
            guard let oldest = entries.filter({ $0 !== kept }).min(by: { $0.lastUsed < $1.lastUsed }) else { return }
            held -= oldest.heldBytes
            close(oldest.pane)
            onRelease?(oldest)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// The bounds Settings ▸ Agent offers for the files an agent opened by path
/// (`AgentBackgroundDocuments`), and what they are until the person picks.
///
/// A parsed dump holds what was read of the file — at most 32 MiB of it,
/// `ChunkCache` — and what its compressed sections decompressed to, at most
/// 256 MiB a tree and some tens of MiB for a usual BIOS. Eight files and
/// 1 GiB keep a working set of dumps parsed on any Mac the app runs on;
/// past a quarter of the Mac's memory the agent's files would be pushing
/// the person's own work out of it.
enum AgentBackgroundLimits {
    static let fileChoices = [1, 2, 4, 8, 16, 32, 64]
    static let defaultFiles = 8

    static let memoryChoicesMiB = [256, 512, 1024, 2048, 4096, 8192, 16384]
    static let defaultMemoryMiBWanted = 1024

    /// The memory bounds offered on a Mac with `physicalMemory` bytes: up to
    /// a quarter of it, and always the smallest.
    static func memoryChoicesMiB(physicalMemory: UInt64) -> [Int] {
        let quarter = (physicalMemory / 4) >> 20
        let offered = memoryChoicesMiB.filter { UInt64($0) <= quarter }
        return offered.isEmpty ? [memoryChoicesMiB[0]] : offered
    }

    static func defaultMemoryMiB(physicalMemory: UInt64) -> Int {
        let offered = memoryChoicesMiB(physicalMemory: physicalMemory)
        return offered.last { $0 <= defaultMemoryMiBWanted } ?? offered[0]
    }

    /// A kept value brought inside what is offered: the largest choice not
    /// over it — a setting made on a Mac with more memory, or written by
    /// hand — or `fallback` when there is none or nothing was kept.
    static func snapped(_ value: Int?, to choices: [Int], fallback: Int) -> Int {
        guard let value, value > 0 else { return fallback }
        return choices.last { $0 <= value } ?? choices[0]
    }
}
