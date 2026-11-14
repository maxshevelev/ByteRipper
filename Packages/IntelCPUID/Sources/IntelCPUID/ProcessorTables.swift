import Foundation

/// The tables that say which processors stand behind a CPUID: the models
/// (`ProcessorFamily`), the microcode updates that serve several CPUIDs
/// (`MicrocodeSignatures`), and what the repository says of the entries the
/// article lacks (`EntryNotes`).
///
/// They are not part of the app. They live in the public repository
/// `github.com/maxshevelev/IntelCPUID`, which `IntelCPUIDRepository` reads at
/// run time, so a correction there reaches every bench without a new build.
/// There is one copy in the process — `current` — and every reader reads it:
/// the FIT panel, its add-microcode form, the agent's tools and the Intel
/// CPUID Lookup window. Until something is installed — a first run with no
/// network and no copy kept from an earlier one — the tables are empty, and
/// every CPUID is one they do not know.
public struct ProcessorTables: Sendable {
    /// The one format this build reads. A file of a newer one is refused, not
    /// guessed at, and the tables in hand are kept.
    public static let formatVersion = 1

    public var families: [ProcessorFamily]
    public var microcode: MicrocodeSignatures
    /// By `ProcessorFamily.key`.
    public var notes: [String: EntryNotes]
    /// The day the table's sources were last read, as the file says it —
    /// `2026-11-14`. Nil when it does not say.
    public var retrieved: String?

    public init(families: [ProcessorFamily], microcode: MicrocodeSignatures,
                notes: [String: EntryNotes] = [:], retrieved: String? = nil) {
        self.families = families
        self.microcode = microcode
        self.notes = notes
        self.retrieved = retrieved
    }

    public static let empty = ProcessorTables(families: [], microcode: MicrocodeSignatures(updates: []))

    public var isEmpty: Bool { families.isEmpty }

    public enum DecodeError: Error, Equatable {
        /// The file says it is of a format this build does not read.
        case unsupportedFormat(file: String, version: Int)
        /// The file is not the JSON this build reads.
        case malformed(file: String)
    }

    /// `IntelCPUIDBrandNames.json` and `IntelMicrocodeSignatures.json`, read
    /// together: one that fails is a reason to keep both as they are. The
    /// notes are what the tables can do without: a file that does not read
    /// leaves them empty, and the tables stand.
    public static func decode(brandNames: Data, signatures: Data, notes: Data? = nil) throws -> ProcessorTables {
        struct Source: Decodable { var retrieved: String? }
        struct Names: Decodable { var formatVersion: Int?; var source: Source?; var entries: [ProcessorFamily] }
        struct Signatures: Decodable { var formatVersion: Int?; var updates: [MicrocodeSignatures.Update] }
        let decoder = JSONDecoder()
        guard let names = try? decoder.decode(Names.self, from: brandNames) else {
            throw DecodeError.malformed(file: "IntelCPUIDBrandNames.json")
        }
        guard let shared = try? decoder.decode(Signatures.self, from: signatures) else {
            throw DecodeError.malformed(file: "IntelMicrocodeSignatures.json")
        }
        for (file, version) in [("IntelCPUIDBrandNames.json", names.formatVersion),
                                ("IntelMicrocodeSignatures.json", shared.formatVersion)] {
            guard let version, version <= formatVersion else {
                throw DecodeError.unsupportedFormat(file: file, version: version ?? 0)
            }
        }
        return ProcessorTables(families: names.entries, microcode: MicrocodeSignatures(updates: shared.updates),
                               notes: notes.map(decodeNotes) ?? [:], retrieved: names.source?.retrieved)
    }

    /// The generator's `extra-entries.json`: its entries' notes and pages, by
    /// the entry they are of. An entry that does not read is left out, not
    /// the file.
    static func decodeNotes(_ data: Data) -> [String: EntryNotes] {
        struct Entry: Decodable {
            var cpuids: [String]
            var codeNames: [String]
            var note: String?
            var evidence: [EntryNotes.Evidence]?
        }
        struct Lenient<T: Decodable>: Decodable {
            var value: T?
            init(from decoder: Decoder) { value = try? T(from: decoder) }
        }
        struct File: Decodable { var entries: [Lenient<Entry>] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        var notes: [String: EntryNotes] = [:]
        for entry in file.entries.compactMap(\.value) {
            let key = entry.cpuids.joined(separator: ",") + "|" + entry.codeNames.joined(separator: ",")
            notes[key] = EntryNotes(note: entry.note, evidence: entry.evidence ?? [])
        }
        return notes
    }

    /// What the repository says of `family` beyond the table, if anything.
    public func notes(on family: ProcessorFamily) -> EntryNotes? { notes[family.key] }

    // MARK: - The tables this process uses

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var tables = ProcessorTables.empty
        var source: any ProcessorTablesSource = IntelCPUIDRepository.shared
    }
    private static let store = Store()

    /// What the table says now: the last tables installed, or nothing.
    public static var current: ProcessorTables {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.tables
    }

    /// Posted on the main queue after `install`, so whatever shows processor
    /// names can show them again.
    public static let didChange = Notification.Name("ProcessorTablesDidChange")

    /// Makes `tables` the ones every lookup reads from now on.
    public static func install(_ tables: ProcessorTables) {
        store.lock.lock()
        store.tables = tables
        store.lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Where the tables come from — the repository. Swappable, because a test
    /// suite that reaches GitHub is a suite that fails on a train: a test
    /// installs a source of its own, and every reader asks that one.
    public static var source: any ProcessorTablesSource {
        get {
            store.lock.lock()
            defer { store.lock.unlock() }
            return store.source
        }
        set {
            store.lock.lock()
            store.source = newValue
            store.lock.unlock()
        }
    }

    /// Asks the source to bring the tables up to date: what every reader
    /// calls when it opens.
    public static func refresh() async {
        await source.refresh()
    }
}
