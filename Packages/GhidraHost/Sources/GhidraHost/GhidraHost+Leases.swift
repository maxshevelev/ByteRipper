import CodeAnalysis
import Foundation

/// A module in work (`Design/SERVER_PLAN.md`, stage 2.4): one holder at a
/// time has the right to review it. The holder takes the module into work
/// before its first write, and keeps it — with no term — through any number
/// of publishes, until it gives it back or an administrator closes the lease.
/// Reading needs no lease.
///
/// The holder is who the call comes from: a server's HTTP client by its
/// token's name, the server's own MCP socket and the app's host by the
/// configuration's `holder`. The leases are kept in a file beside the store's
/// private part, so a restarted server knows who holds what.
///
/// A lease the administrator closes takes the holder's unpublished changes
/// with it: the working project goes to the Trash, and the next open unpacks
/// the last published revision's project from the store. The holder hears of
/// it at its next call on the module, a read included, and an HTTP client
/// waiting on `waitForLeaseEnd` at once.
extension GhidraHost {
    /// A module's holder and since when, and what the holder has done under
    /// the lease: the console's Activity page shows it.
    public struct WorkLease: Codable, Equatable, Sendable {
        public var holder: String
        public var since: String
        /// The holder's last call on the module — a read, a write, a publish —
        /// and when. A read is kept in memory only; a write or a publish is
        /// written down with the counts.
        public var lastCall: String?
        public var lastAt: String?
        /// Writes and publishes since the take.
        public var writes: Int?
        public var publishes: Int?
        /// The revision the holder's last publish made.
        public var revision: Int?

        public init(holder: String, since: String) {
            self.holder = holder
            self.since = since
        }

        enum CodingKeys: String, CodingKey {
            case holder, since, writes, publishes, revision
            case lastCall = "last_call"
            case lastAt = "last_at"
        }
    }

    /// A lease an administrator closed, kept until its holder takes the module
    /// again: what the holder is told.
    public struct LeaseEnd: Codable, Equatable, Sendable {
        public var holder: String
        public var since: String
        public var closedBy: String
        public var at: String
        /// Whether the holder has been told at a read; a write is refused
        /// with it until the holder takes the module again.
        public var told: Bool

        enum CodingKeys: String, CodingKey {
            case holder, since, at, told
            case closedBy = "closed_by"
        }
    }

    /// What the file holds, by module.
    struct LeaseBook: Codable, Equatable {
        var leases: [String: WorkLease] = [:]
        var closed: [String: LeaseEnd] = [:]
    }

    /// One module's row of the list an administrator reads: the lease and
    /// what its holder has done under it, or the close not yet taken back.
    public struct LeaseRow: Codable, Equatable, Sendable {
        public var module: String
        public var name: String?
        public var holder: String?
        public var since: String?
        public var lastCall: String?
        public var lastAt: String?
        public var writes: Int?
        public var publishes: Int?
        public var revision: Int?
        public var closed: LeaseEnd?

        enum CodingKeys: String, CodingKey {
            case module, name, holder, since, writes, publishes, revision, closed
            case lastCall = "last_call"
            case lastAt = "last_at"
        }
    }

    static func loadLeaseBook(_ file: URL?) -> LeaseBook {
        guard let file, let data = try? Data(contentsOf: file),
              let book = try? JSONDecoder().decode(LeaseBook.self, from: data) else { return LeaseBook() }
        return book
    }

    func saveLeaseBook() throws {
        guard let file = configuration.leasesFile else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(leaseBook).write(to: file, options: .atomic)
    }

    func holderName(_ holder: String?) -> String { holder ?? configuration.holder }

    /// The module's lease now, if any.
    public func workLease(_ module: SHA256Digest) -> WorkLease? { leaseBook.leases[module.hex] }

    /// The module taken into work by `holder`. The same holder again is the
    /// same lease; another holder's is a refusal naming it.
    @discardableResult
    public func take(_ module: SHA256Digest, holder: String? = nil) async throws -> WorkLease {
        let holder = holderName(holder)
        if let held = leaseBook.leases[module.hex] {
            if held.holder == holder { return held }
            throw Self.heldByAnother(held)
        }
        let project = self.project(module)
        if !project.exists { try await restoreProject(module) }
        guard project.exists else {
            throw GhidraHostError(.project, "no project for \(module.hex): open the module first", status: 404)
        }
        var lease = WorkLease(holder: holder, since: Self.now())
        lease.lastCall = "take"
        lease.lastAt = lease.since
        leaseBook.leases[module.hex] = lease
        if leaseBook.closed[module.hex]?.holder == holder { leaseBook.closed[module.hex] = nil }
        try saveLeaseBook()
        return lease
    }

    /// A write, a publish or a give-back of `holder`: refused unless it holds
    /// the module.
    func requireLease(_ module: SHA256Digest, holder: String?) throws {
        let holder = holderName(holder)
        if let held = leaseBook.leases[module.hex] {
            if held.holder == holder { return }
            throw Self.heldByAnother(held)
        }
        if let closed = leaseBook.closed[module.hex], closed.holder == holder {
            if !closed.told {
                leaseBook.closed[module.hex]?.told = true
                try? saveLeaseBook()
            }
            throw Self.closedRefusal(closed)
        }
        throw GhidraHostError(.refused, "the module is not in work: take it first (`ghidra_take`, "
            + "POST /ghidra/v1/modules/<module>/lease). Reading needs no lease.", status: 409)
    }

    /// A read of `holder`: refused once when an administrator closed its
    /// lease and it has not been told yet, so it hears of it at once.
    func tellClosed(_ module: SHA256Digest, holder: String?) throws {
        let holder = holderName(holder)
        guard let closed = leaseBook.closed[module.hex], closed.holder == holder, !closed.told else { return }
        leaseBook.closed[module.hex]?.told = true
        try? saveLeaseBook()
        throw Self.closedRefusal(closed)
    }

    /// What the holder did under its lease, for the Activity page. A read is
    /// not written down: it would write the file at every call.
    func noteActivity(_ module: SHA256Digest, holder: String?, call: String, kind: ActivityKind,
                      revision: Int? = nil) {
        guard var lease = leaseBook.leases[module.hex], lease.holder == holderName(holder) else { return }
        lease.lastCall = call
        lease.lastAt = Self.now()
        switch kind {
        case .read: break
        case .write: lease.writes = (lease.writes ?? 0) + 1
        case .publish:
            lease.publishes = (lease.publishes ?? 0) + 1
            if let revision { lease.revision = revision }
        }
        leaseBook.leases[module.hex] = lease
        if kind != .read { try? saveLeaseBook() }
    }

    enum ActivityKind { case read, write, publish }

    /// The lease given back by its holder.
    func dropLease(_ module: SHA256Digest) throws {
        guard leaseBook.leases.removeValue(forKey: module.hex) != nil else { return }
        try saveLeaseBook()
        wakeLeaseWaiters(module)
    }

    /// An administrator's close: the owner stopped, the working project to
    /// the Trash — the holder's unpublished changes with it — and the store's
    /// copy of the last published revision left for the next open.
    public func closeLease(_ module: SHA256Digest, by administrator: String) async throws -> LeaseEnd {
        guard let held = leaseBook.leases[module.hex] else {
            throw GhidraHostError(.refused, "the module is not in work: no lease to close", status: 404)
        }
        try await discardWorkingProject(module)
        let closed = LeaseEnd(holder: held.holder, since: held.since, closedBy: administrator, at: Self.now(), told: false)
        leaseBook.leases[module.hex] = nil
        leaseBook.closed[module.hex] = closed
        try saveLeaseBook()
        wakeLeaseWaiters(module)
        return closed
    }

    /// The working project let go, its owner stopped first: to the Trash,
    /// recoverable. The store's copy stays, and the next open unpacks it.
    func discardWorkingProject(_ module: SHA256Digest) async throws {
        let project = self.project(module)
        guard project.exists else { return }
        _ = await stop(module)
        leaseBaselines[module] = nil
        try FileManager.default.trashItem(at: project.folder, resultingItemURL: nil)
    }

    /// Every module in work and every lease closed and not yet taken again.
    public func leaseRows() -> [LeaseRow] {
        let modules = Set(leaseBook.leases.keys).union(leaseBook.closed.keys).sorted()
        return modules.map { hex in
            let name = SHA256Digest(hex: hex).flatMap { try? project($0).state().module.name }
            let held = leaseBook.leases[hex]
            return LeaseRow(module: hex, name: name, holder: held?.holder, since: held?.since,
                            lastCall: held?.lastCall, lastAt: held?.lastAt, writes: held?.writes,
                            publishes: held?.publishes, revision: held?.revision, closed: leaseBook.closed[hex])
        }
    }

    /// Answers when `holder`'s lease of the module ends — given back or
    /// closed — or after `seconds`: the lease's state then. An HTTP client
    /// keeps one of these open while it holds a module, and hears at once.
    public func waitForLeaseEnd(_ module: SHA256Digest, holder: String?, seconds: Int) async -> [String: String] {
        let holder = holderName(holder)
        func state() -> [String: String]? {
            if let held = leaseBook.leases[module.hex], held.holder == holder { return nil }
            if let closed = leaseBook.closed[module.hex], closed.holder == holder {
                return ["state": "closed", "closed_by": closed.closedBy, "at": closed.at]
            }
            return ["state": "not_held"]
        }
        if let now = state() { return now }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            leaseWaiters[module, default: [:]][id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                await self?.wakeLeaseWaiter(module, id)
            }
        }
        return state() ?? ["state": "held"]
    }

    func wakeLeaseWaiters(_ module: SHA256Digest) {
        let waiting = leaseWaiters.removeValue(forKey: module) ?? [:]
        for continuation in waiting.values { continuation.resume() }
    }

    func wakeLeaseWaiter(_ module: SHA256Digest, _ id: UUID) {
        leaseWaiters[module]?.removeValue(forKey: id)?.resume()
    }

    static func heldByAnother(_ held: WorkLease) -> GhidraHostError {
        GhidraHostError(.refused, "the module is in work by \(held.holder) since \(held.since): only its holder "
            + "writes and publishes. Reading needs no lease; an administrator can close the lease.", status: 409)
    }

    static func closedRefusal(_ closed: LeaseEnd) -> GhidraHostError {
        GhidraHostError(.refused, "your lease of this module was closed by \(closed.closedBy) at \(closed.at): "
            + "its unpublished changes are gone, and the project is the last published revision again. "
            + "Take the module into work again to go on.", status: 409)
    }
}
