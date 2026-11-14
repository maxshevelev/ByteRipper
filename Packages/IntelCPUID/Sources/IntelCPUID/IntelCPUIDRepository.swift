import Foundation

/// Where the processor tables come from (`ProcessorTables.source`).
///
/// A protocol because the app's tests must not touch the network: a test
/// installs tables of its own.
public protocol ProcessorTablesSource: Sendable {
    /// Installs the tables kept from the last good read, if none are installed
    /// yet, then — unless they were checked recently — asks the repository
    /// whether they changed and installs what it answers. A failure leaves the
    /// installed tables as they are.
    func refresh() async
}

/// `github.com/maxshevelev/IntelCPUID`, over HTTPS.
///
/// Its two files are the processor tables, and the app has no copy of its
/// own: what it shows is what it last read from there whole. Each file is
/// asked for with the ETag of the copy kept, so an unchanged table costs a
/// `304` a file; the pair is installed only when both decode, so a broken push
/// or a file of a newer format leaves the bench with the tables it had. The
/// kept copy is what a run with no network shows, and before there is one — a
/// first run offline — the tables are empty.
///
/// A third file is read beside them: the generator's `extra-entries.json`,
/// whose notes and pages the lookup window shows for the entries the article
/// lacks. The tables do not wait on it — when it cannot be had, the copy kept
/// of it stands, or there are no notes.
public actor IntelCPUIDRepository: ProcessorTablesSource {
    public static let shared = IntelCPUIDRepository()

    public static let base = URL(string: "https://raw.githubusercontent.com/maxshevelev/IntelCPUID/main/")!
    static let names = "IntelCPUIDBrandNames.json"
    static let signatures = "IntelMicrocodeSignatures.json"
    /// Its path in the repository; kept under its last component.
    static let notes = "Skills/update-cpuid-brand-names/scripts/extra-entries.json"

    private let session: URLSession
    private let folder: URL?
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var keptRead = false
    private var checked: Date?
    private var running: Task<Void, Never>?

    public init() {
        self.init(session: .shared, folder: Self.cacheFolder(), ttl: 24 * 60 * 60)
    }

    /// - Parameters:
    ///   - folder: where the last good copy is kept; nil keeps none.
    ///   - ttl: how long a check stands before the repository is asked again.
    public init(session: URLSession, folder: URL?, ttl: TimeInterval,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.folder = folder
        self.ttl = ttl
        self.now = now
    }

    /// `~/Library/Caches/<bundle identifier>/IntelCPUID`, as the microcode
    /// listing's cache is named, so the test host keeps its own.
    static func cacheFolder() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ByteRipper", isDirectory: true)
            .appendingPathComponent("IntelCPUID", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder
    }

    public func refresh() async {
        if !keptRead {
            keptRead = true
            if let kept = readKept(), ProcessorTables.current.isEmpty { ProcessorTables.install(kept.tables) }
        }
        if let checked, now().timeIntervalSince(checked) < ttl { return }
        // Two readers opening at once ask once.
        if let running { return await running.value }
        let task = Task { await self.check() }
        running = task
        await task.value
        running = nil
    }

    /// Asks for the files; installs and keeps them when any changed and the
    /// tables decode. A failure is not recorded as a check, so the next
    /// reader asks again.
    private func check() async {
        let kept = readKept()
        guard let names = await fetch(Self.names, keptETag: kept?.etags[Self.names]),
              let signatures = await fetch(Self.signatures, keptETag: kept?.etags[Self.signatures])
        else { return }
        // Asked without a validator when nothing of it is kept, so a `304`
        // never stands for a copy that is not there.
        let notes = await fetch(Self.notes, keptETag: kept?.notes == nil ? nil : kept?.etags[Self.notes])
        checked = now()
        if names.data == nil && signatures.data == nil && notes?.data == nil { return }   // nothing new
        guard let namesData = names.data ?? kept?.names,
              let signaturesData = signatures.data ?? kept?.signatures
        else { return }
        let notesData = notes?.data ?? kept?.notes
        guard let tables = try? ProcessorTables.decode(brandNames: namesData, signatures: signaturesData,
                                                       notes: notesData)
        else { return }
        var etags = [Self.names: names.etag, Self.signatures: signatures.etag].compactMapValues { $0 }
        if notesData != nil { etags[Self.notes] = notes?.etag ?? kept?.etags[Self.notes] }
        keep(names: namesData, signatures: signaturesData, notes: notesData, etags: etags)
        ProcessorTables.install(tables)
    }

    private struct Answer {
        /// Nil for a `304`: the kept copy stands.
        var data: Data?
        var etag: String?
    }

    /// Nil when the file could not be had: no network, or an answer other
    /// than `200` and `304`.
    private func fetch(_ file: String, keptETag: String?) async -> Answer? {
        var request = URLRequest(url: Self.base.appendingPathComponent(file))
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ByteRipper", forHTTPHeaderField: "User-Agent")
        if let keptETag { request.setValue(keptETag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 304 where keptETag != nil: return Answer(data: nil, etag: keptETag)
        case 200..<300: return Answer(data: data, etag: http.value(forHTTPHeaderField: "ETag"))
        default: return nil
        }
    }

    // MARK: - The kept copy

    private struct Kept {
        var names: Data
        var signatures: Data
        var notes: Data?
        var etags: [String: String]
        var tables: ProcessorTables
    }

    private static var notesFile: String { (notes as NSString).lastPathComponent }

    private func readKept() -> Kept? {
        guard let folder,
              let names = try? Data(contentsOf: folder.appendingPathComponent(Self.names)),
              let signatures = try? Data(contentsOf: folder.appendingPathComponent(Self.signatures))
        else { return nil }
        let notes = try? Data(contentsOf: folder.appendingPathComponent(Self.notesFile))
        guard let tables = try? ProcessorTables.decode(brandNames: names, signatures: signatures, notes: notes)
        else { return nil }
        let etags = (try? Data(contentsOf: folder.appendingPathComponent("etags.json")))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return Kept(names: names, signatures: signatures, notes: notes, etags: etags, tables: tables)
    }

    private func keep(names: Data, signatures: Data, notes: Data?, etags: [String: String]) {
        guard let folder else { return }
        try? names.write(to: folder.appendingPathComponent(Self.names), options: .atomic)
        try? signatures.write(to: folder.appendingPathComponent(Self.signatures), options: .atomic)
        if let notes { try? notes.write(to: folder.appendingPathComponent(Self.notesFile), options: .atomic) }
        if let data = try? JSONEncoder().encode(etags) {
            try? data.write(to: folder.appendingPathComponent("etags.json"), options: .atomic)
        }
    }
}
