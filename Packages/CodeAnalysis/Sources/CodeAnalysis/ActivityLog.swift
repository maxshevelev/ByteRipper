import Foundation

/// What happened to the store's modules and to the server that keeps it, as
/// the console's Activity page shows it live: revisions published, publishes
/// that stored nothing new or were refused, leases taken, given back and
/// closed — each with its holder — and the server's starts and stops with its
/// version. A start with no stop before it is a server that died.
///
/// One JSON object per line, in the store's private part beside the leases
/// (`private/events.jsonl`): it is no object of the CAS, no mirror takes it,
/// and it goes with the store. What is older than `keep` goes, at most once
/// per `pruneEvery` — the time of the last pruning is kept beside the file, so
/// a server restarted often does not rewrite it at each start.
public final class ActivityLog: @unchecked Sendable {
    public struct Event: Codable, Equatable, Sendable {
        /// Numbered by the log, from 1, so a reader asks for what came after
        /// the last it has.
        public var seq: Int = 0
        /// ISO 8601, UTC.
        public var at: String = ""
        /// One of `Kind`'s values; a reader shows one it does not know as it is.
        public var kind: String
        public var module: String?
        /// The module's name, as its project has it.
        public var name: String?
        /// Who holds or held the module: a token's name, or the local MCP.
        public var holder: String?
        /// Who closed a lease, or published for a holder.
        public var by: String?
        public var revision: Int?
        /// The server's version and commit, on a start and a stop.
        public var version: String?
        public var commit: String?
        public var pid: Int32?
        /// Why a publish was refused; on a give-back, `discarded` when the
        /// holder's changes went unpublished.
        public var reason: String?
        /// On a start: the server before it ended with no stop.
        public var unclean: Bool?

        public init(kind: String, module: String? = nil, name: String? = nil, holder: String? = nil,
                    by: String? = nil, revision: Int? = nil, version: String? = nil, commit: String? = nil,
                    pid: Int32? = nil, reason: String? = nil, unclean: Bool? = nil) {
            self.kind = kind
            self.module = module
            self.name = name
            self.holder = holder
            self.by = by
            self.revision = revision
            self.version = version
            self.commit = commit
            self.pid = pid
            self.reason = reason
            self.unclean = unclean
        }
    }

    public enum Kind {
        public static let serverStart = "server_start"
        public static let serverStop = "server_stop"
        /// A new revision of the module's review.
        public static let publish = "publish"
        /// A publish that stored the revision the module had.
        public static let publishUnchanged = "publish_unchanged"
        public static let publishRefused = "publish_refused"
        public static let leaseTake = "lease_take"
        public static let leaseRelease = "lease_release"
        public static let leaseClose = "lease_close"
    }

    public let file: URL
    public let keep: TimeInterval
    public let pruneEvery: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var events: [Event] = []
    private var last = 0
    private var prunedAt: Date?

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The last pruning's time and the last number then, beside the file.
    var prunedFile: URL { file.deletingPathExtension().appendingPathExtension("pruned") }

    public init(file: URL, keep: TimeInterval = 14 * 86_400, pruneEvery: TimeInterval = 86_400,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.keep = keep
        self.pruneEvery = pruneEvery
        self.now = now
        lock.lock()
        defer { lock.unlock() }
        events = Self.read(file)
        last = events.last?.seq ?? 0
        // The sidecar: the last pruning's time, and the last number then — a
        // pruning that dropped every event must not number them again from 1.
        let sidecar = ((try? String(contentsOf: prunedFile, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
        prunedAt = sidecar.first.flatMap { Self.stamp.date(from: $0) }
        last = max(last, sidecar.dropFirst().first.flatMap { Int($0) } ?? 0)
        pruneIfDue()
    }

    /// The event written down, numbered and stamped now. A failure to write
    /// keeps it in memory: the page shows it, the next start does not.
    @discardableResult
    public func append(_ event: Event) -> Event {
        lock.lock()
        defer { lock.unlock() }
        var event = event
        last += 1
        event.seq = last
        event.at = Self.stamp.string(from: now())
        events.append(event)
        if let line = try? Self.encoder.encode(event) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line + Data("\n".utf8))
            } else {
                try? (line + Data("\n".utf8)).write(to: file, options: .atomic)
            }
        }
        pruneIfDue()
        return event
    }

    /// The events after `seq`, oldest first, at most `limit` — the newest
    /// ones when there are more.
    public func events(after seq: Int = 0, limit: Int = 500) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        let newer = events.filter { $0.seq > seq }
        return Array(newer.suffix(max(0, limit)))
    }

    /// The last number given; the next event gets the one after it.
    public var lastNumber: Int {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// The last event of these kinds.
    public func last(of kinds: Set<String>) -> Event? {
        lock.lock()
        defer { lock.unlock() }
        return events.last { kinds.contains($0.kind) }
    }

    /// Under the lock: what is older than `keep` goes, when the last pruning
    /// was `pruneEvery` ago or more.
    private func pruneIfDue() {
        let moment = now()
        if let then = prunedAt, moment.timeIntervalSince(then) < pruneEvery { return }
        let cutoff = moment.addingTimeInterval(-keep)
        let kept = events.filter { (Self.stamp.date(from: $0.at) ?? moment) >= cutoff }
        if kept.count != events.count {
            let lines = kept.compactMap { try? Self.encoder.encode($0) }
            var data = Data()
            for line in lines { data += line + Data("\n".utf8) }
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            events = kept
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (Self.stamp.string(from: moment) + "\n\(last)\n").write(to: prunedFile, atomically: true, encoding: .utf8)
        prunedAt = moment
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The file's events; a line that does not read is skipped.
    private static func read(_ file: URL) -> [Event] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Event.self, from: Data($0)) }
    }
}
