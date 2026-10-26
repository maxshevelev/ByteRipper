import CodeAnalysis
import Foundation

/// The served store's change feed: a sequence number, the modules each step
/// changed, and the long polls waiting for the next step.
///
/// A step is found, not announced: after a write the server serves, and on
/// every FSEvents change of the store's directory (a `byteripper-cas` run on
/// the server writes there directly), the feed compares each module's
/// fingerprint with the last one it saw. So a change is reported once,
/// whoever made it, and a write that changed nothing is no step.
public actor ChangeFeed {
    public nonisolated let epoch = UUID().uuidString.lowercased()
    public nonisolated let storeID: String

    private let store: ContentStore
    private var fingerprints: [SHA256Digest: SHA256Digest]
    private(set) var seq = 0
    /// The modules of each step, oldest first; at most `memory` steps.
    private var steps: [(seq: Int, modules: Set<SHA256Digest>)] = []
    private let memory: Int
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(store: ContentStore, memory: Int = 1000) throws {
        self.store = store
        self.storeID = try store.identity()
        self.fingerprints = store.fingerprints()
        self.memory = memory
    }

    public var current: Int { seq }

    /// Compare the store with what the feed last saw, and make a step of the
    /// modules that differ.
    @discardableResult
    public func rescan() -> [SHA256Digest] {
        let now = store.fingerprints()
        let changed = Set(now.keys.filter { now[$0] != fingerprints[$0] })
            .union(fingerprints.keys.filter { now[$0] == nil })
        fingerprints = now
        guard !changed.isEmpty else { return [] }
        seq += 1
        steps.append((seq, changed))
        if steps.count > memory { steps.removeFirst(steps.count - memory) }
        let woken = waiters
        waiters.removeAll()
        for continuation in woken.values { continuation.resume() }
        return changed.sorted()
    }

    /// What changed after `since`, waiting up to `wait` seconds for a change
    /// when nothing has yet.
    public func changes(since: Int, epoch: String?, wait: TimeInterval) async -> ServedStoreProtocol.Changes {
        if let answer = answer(since: since, epoch: epoch) { return answer }
        if wait > 0 {
            let id = UUID()
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                await self?.wake(id)
            }
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
            timeout.cancel()
        }
        return answer(since: since, epoch: epoch)
            ?? .init(store: storeID, epoch: self.epoch, seq: seq, modules: [], resync: false)
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// An answer when there is one to give now: a resync, or the modules of
    /// the steps after `since`.
    private func answer(since: Int, epoch: String?) -> ServedStoreProtocol.Changes? {
        let oldest = steps.first.map { $0.seq - 1 } ?? seq
        if epoch != self.epoch || since > seq || since < oldest {
            return .init(store: storeID, epoch: self.epoch, seq: seq, modules: [], resync: true)
        }
        guard since < seq else { return nil }
        let modules = steps.filter { $0.seq > since }.reduce(into: Set<SHA256Digest>()) { $0.formUnion($1.modules) }
        return .init(store: storeID, epoch: self.epoch, seq: seq, modules: modules.sorted(), resync: false)
    }
}
