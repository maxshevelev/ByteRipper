import Foundation
import Localization
import MEFirmware

/// One of the three files the ME analysis reads out of upstream's repository.
public enum MEADatabaseFile: Int, CaseIterable, Sendable, Comparable {
    case database, huffman, fileTable

    /// What the repository calls it, which is what the status line says.
    public var fileName: String {
        switch self {
        case .database: return "MEA.dat"
        case .huffman: return "Huffman.dat"
        case .fileTable: return "FileTable.dat"
        }
    }

    public static func < (lhs: MEADatabaseFile, rhs: MEADatabaseFile) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The downloads of upstream's files under way, for the status line.
///
/// The engine asks for each file when it reaches the step that reads it, and
/// waits for it there: `MEA.dat` first, `Huffman.dat` at the modules,
/// `FileTable.dat` at the file system — three downloads one after another on
/// a first reading. `prefetch` starts all three side by side when a reading
/// begins; the engine's own asks then join the download already running, since
/// the source fetches each file once however many callers ask.
@MainActor public final class MEADownloads {
    public static let shared = MEADownloads()

    private var counts: [MEADatabaseFile: Int] = [:]
    /// Files a prefetch is asking the source about, before it knows whether
    /// that means a download — so a second prefetch in the meantime starts
    /// nothing of its own.
    private var asking: Set<MEADatabaseFile> = []
    private var observers: [UUID: @MainActor (Set<MEADatabaseFile>) -> Void] = [:]

    public init() {}

    /// What is being downloaded right now.
    public var active: Set<MEADatabaseFile> {
        Set(counts.filter { $0.value > 0 }.keys)
    }

    /// Calls `changed` with `active` each time it changes, until `stopObserving`.
    public func observe(_ changed: @escaping @MainActor (Set<MEADatabaseFile>) -> Void) -> UUID {
        let id = UUID()
        observers[id] = changed
        return id
    }

    public func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    /// Starts every file `source` does not hold yet, side by side. A file it
    /// holds — fetched earlier in this run — costs nothing and is not shown; a
    /// download that fails is left to the engine's own ask, which tries again
    /// and reports what went wrong. A source that does not fetch over the
    /// network — a stub, a local file — answers at once, so nothing is started.
    public func prefetch(from source: any MEADataSource) {
        guard source.fetchesOverTheNetwork else { return }
        for file in MEADatabaseFile.allCases where counts[file, default: 0] == 0 && !asking.contains(file) {
            asking.insert(file)
            Task { [weak self] in
                let held = await Self.holds(file, in: source)
                guard let self else { return }
                self.asking.remove(file)
                guard !held else { return }
                self.begin(file)
                await Self.fetch(file, from: source)
                self.end(file)
            }
        }
    }

    private func begin(_ file: MEADatabaseFile) {
        counts[file, default: 0] += 1
        announce()
    }

    private func end(_ file: MEADatabaseFile) {
        counts[file] = max(0, counts[file, default: 0] - 1)
        announce()
    }

    private func announce() {
        let now = active
        for observer in observers.values { observer(now) }
    }

    private nonisolated static func holds(_ file: MEADatabaseFile, in source: any MEADataSource) async -> Bool {
        switch file {
        case .database: return await source.heldDatabase() != nil
        case .huffman: return await source.heldHuffmanDictionaries() != nil
        case .fileTable: return await source.heldFileTable() != nil
        }
    }

    private nonisolated static func fetch(_ file: MEADatabaseFile, from source: any MEADataSource) async {
        switch file {
        case .database: _ = try? await source.database()
        case .huffman: _ = try? await source.huffmanDictionaries()
        case .fileTable: _ = try? await source.fileTable()
        }
    }
}

/// The status line while an ME region is read: which of upstream's files are
/// still downloading, and once none is, that the region is being analysed.
/// Says it through `say` at once and again on every change, until `stop`.
@MainActor public final class MEAReadingStatus {
    private let downloads: MEADownloads
    private var observation: UUID?

    /// `downloads` is the app's own unless a test hands it one.
    public init(downloads: MEADownloads? = nil, say: @escaping @MainActor (String) -> Void) {
        let downloads = downloads ?? .shared
        self.downloads = downloads
        say(Self.line(for: downloads.active))
        observation = downloads.observe { say(Self.line(for: $0)) }
    }

    /// The reading is over: the line is the caller's again.
    public func stop() {
        observation.map(downloads.stopObserving)
        observation = nil
    }

    public static func line(for downloading: Set<MEADatabaseFile>) -> String {
        guard !downloading.isEmpty else { return L("Reading ME…") }
        return L("Downloading %1$@…", downloading.sorted().map(\.fileName).joined(separator: ", "))
    }
}
