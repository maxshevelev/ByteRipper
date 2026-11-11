import Foundation

/// The work a search shows while it runs — the status bar's operation, with
/// its progress and its (×). The indexer begins one per scan and finishes it;
/// what draws it is the owner's.
public protocol FindActivity: AnyObject, Sendable {
    /// How far the scan has got, as a fraction. Called from the scan's thread.
    func report(_ fraction: Double)
    /// The scan is over, finished or stopped.
    func finish()
}

/// What a search found when it was started (`FindIndexer.find`).
public enum FindOutcome<Query: Equatable & Sendable>: Equatable, Sendable {
    /// A candidate found a match: the search is now that candidate's, and its
    /// index is being built.
    case found(index: Int, query: Query, range: Range<UInt64>, wrapped: Bool)
    /// No candidate occurs anywhere. The search is a finished one with no
    /// matches.
    case nothing
    /// The search was stopped, or replaced by another, before it answered.
    case cancelled
    /// A search for exactly these candidates is already looking: this press
    /// is answered by that one.
    case alreadyRunning
}

/// What a step through a search found (`FindIndexer.step`).
public enum FindStepOutcome: Equatable, Sendable {
    /// The index answered: the match at `index` of the set.
    case indexed(MatchStep)
    /// The index could not answer — it is still filling, or it kept only a
    /// count — and a scan found this match.
    case scanned(range: Range<UInt64>, wrapped: Bool)
    /// A finished search with nothing to step to, or no search at all.
    case nothing
    /// The scan found no match anywhere.
    case notFound
    /// The step was stopped before it answered.
    case cancelled
}

/// One search over one content, and the reader's place in it
/// (`Design/FIND_HIGHLIGHT_PLAN.md`, §11).
///
/// Each panel that searches holds one: the dump's panes, a fragment panel's
/// pane, a code panel. What it holds is the panel's search and nobody else's —
/// a search in one panel neither stops nor touches the search in another.
///
/// It owns:
/// - **the pass** that answers a press before there is an index — the
///   candidates in turn, each from the reader's place and then round the end;
/// - **the index** of every occurrence, built in the background behind the
///   answer and published as it fills;
/// - **the steps**, answered by the index wherever it can and by one scan
///   where it cannot;
/// - **what is shown**: the set, the match the reader stands on, and whether
///   the search is being shown at all.
///
/// The owner gives it the content and the reader's place (`anchor`), shows
/// what it says, and says when the content changed (`invalidate`). A view
/// draws what is here and keeps nothing of its own.
@MainActor
public final class FindIndexer<Content: FindContent> {
    public typealias Query = Content.Query
    public typealias Matches = MatchSet<Query>

    /// What the search runs over. Set it when the panel shows other content;
    /// a change of what the content holds is `invalidate()`.
    public var content: Content?

    public init(content: Content? = nil) {
        self.content = content
    }

    // MARK: - What is shown

    /// Every occurrence of the search, as far as the index has got. Nil until
    /// a search has been run, and again once one is invalidated — but not when
    /// its showing merely ended: a search survives `Done` so a results list
    /// can go on listing it (§11).
    public private(set) var matches: Matches?

    /// The match the reader stands on. A range, not an ordinal: a scan finds
    /// the answer long before the index can say which number it is.
    public private(set) var current: Range<UInt64>?

    /// Whether the search is being shown: highlights, marks, a count. A search
    /// outlives its showing; only `invalidate` drops the set itself.
    public private(set) var isHighlighting = false

    /// The set as everything that draws it sees it: nil once the showing ended.
    public var highlightedMatches: Matches? { isHighlighting ? matches : nil }

    /// Which match the reader stands on, counted from 0 — asked of a finished
    /// index only, since an ordinal out of a half-built one would climb as the
    /// scan ran. Nil, too, for a match the index does not start on (a run of
    /// a pattern overlapping itself is grouped differently from different
    /// starts).
    public var currentIndex: Int? {
        guard let current, let matches, matches.isComplete else { return nil }
        return matches.index(startingAt: current.lowerBound)
    }

    /// Whether the set is `query`'s: a press for the same search steps
    /// rather than starting again.
    public func hasMatches(for query: Query) -> Bool { matches?.query == query }

    /// The shown matches overlapping `range`. Empty when nothing is shown, and
    /// when the set kept only a count.
    public func matchRanges(intersecting range: Range<UInt64>) -> [Range<UInt64>] {
        guard let set = highlightedMatches, set.isHighlightable else { return [] }
        return set.matches(intersecting: range)
    }

    // MARK: - Telling the owner

    /// Anything about how the search looks changed — the set, the showing,
    /// the current match. Not a content change: nothing may scroll.
    public var onAppearanceChanged: (() -> Void)?
    /// The set itself was replaced or dropped: what a results list lists.
    public var onSetChanged: (() -> Void)?
    /// The index grew over `range`, which it did not cover before. Only that
    /// stretch needs drawing again.
    public var onFilled: ((Range<UInt64>) -> Void)?
    /// The index turned up its first match of `query`: the search found
    /// something, which a search that started with an index and no pass has
    /// no other way to learn. Once per index.
    public var onFoundSomething: ((Query) -> Void)?
    /// Begins the activity a scan shows; `cancel` is what its (×) does. Nil
    /// shows nothing.
    public var beginActivity: ((_ cancel: @escaping @MainActor () -> Void) -> (any FindActivity)?)?

    /// How often a half-built index is published: often enough that the
    /// highlights follow the scan visibly, rarely enough that the copy each
    /// publish costs stays a rounding error next to the scan.
    public var publishInterval: TimeInterval = 0.1

    // MARK: - Starting a search

    /// The candidates a pass is looking for, while it looks.
    public private(set) var passInFlight: [Query]?

    /// Whether an index is being built.
    public var isIndexing: Bool { indexFlag != nil }

    /// Starts a search: runs the pass from `anchor` in `direction` and, when
    /// a candidate finds something, makes the search that candidate's and
    /// starts its index. With `landing`, the reader is put on the match found
    /// (Return, ‹ ›); without, the search is only listed (a results list).
    ///
    /// While the pass looks, the set is the first candidate's and covers
    /// nothing: nothing is shown as found, and a second press finds a search
    /// already under way.
    public func find(_ candidates: [Query], from anchor: UInt64, direction: SearchDirection,
                     landing: Bool = true) async -> FindOutcome<Query> {
        guard let content, let first = candidates.first else { return .nothing }
        guard passInFlight != candidates else { return .alreadyRunning }
        cancelNavigation()
        stopIndexing()
        install(placeholder(for: first, in: content))
        let (flag, activity) = beginNavigation()
        passInFlight = candidates
        let result = await Task.detached(priority: .userInitiated) {
            try? FindPass.firstMatch(among: candidates, in: content, from: anchor,
                                     direction: direction,
                                     shouldCancel: { flag.isCancelled },
                                     progress: { activity?.report($0) })
        }.value
        activity?.finish()
        guard navigationFlag === flag, !flag.isCancelled else { return .cancelled }
        navigationFlag = nil
        passInFlight = nil
        guard let found = result else {
            let last = candidates[candidates.count - 1]
            install(Matches(query: last, matchLength: content.matchLength(of: last),
                            extent: content.extent, starts: []))
            return .nothing
        }
        install(placeholder(for: found.query, in: content))
        if landing { highlight(onMatch: found.range) }
        startIndexing(found.query)
        return .found(index: found.index, query: found.query, range: found.range,
                      wrapped: found.wrapped)
    }

    /// Starts `query`'s index without a pass and without going anywhere: what
    /// a results list asks for when there is one thing to look for.
    public func index(_ query: Query) {
        guard let content else { return }
        cancelNavigation()
        install(placeholder(for: query, in: content))
        startIndexing(query)
    }

    // MARK: - Stepping

    /// The next (or previous) match from `anchor` (§11).
    ///
    /// Answered by the index wherever it can: a rank/select step, instant,
    /// that leaves the index alone. A half-built index answers for what it
    /// covers — but a wrap is only true once it is finished, since while it
    /// fills "nothing ahead" may mean "not found yet". Only a step it cannot
    /// answer is scanned for: one scan for the search's own query, which does
    /// not stop the index being built behind it.
    public func step(_ direction: SearchDirection, from anchor: UInt64) async -> FindStepOutcome {
        guard let set = matches else { return .nothing }
        if set.isHighlightable, let step = set.step(direction, from: anchor),
           !step.wrapped || set.isComplete {
            highlight(current: step.index)
            return .indexed(step)
        }
        // A finished index with nothing in it has nothing to step to.
        guard !set.isComplete || !set.isHighlightable, let content else { return .nothing }
        cancelNavigation()
        let (flag, activity) = beginNavigation()
        let query = set.query
        let result = await Task.detached(priority: .userInitiated) {
            try? FindPass.firstMatch(among: [query], in: content, from: anchor,
                                     direction: direction,
                                     shouldCancel: { flag.isCancelled },
                                     progress: { activity?.report($0) })
        }.value
        activity?.finish()
        guard navigationFlag === flag, !flag.isCancelled else { return .cancelled }
        navigationFlag = nil
        guard let found = result else { return .notFound }
        highlight(onMatch: found.range)
        return .scanned(range: found.range, wrapped: found.wrapped)
    }

    // MARK: - Showing

    /// Shows the set again, on the match at `index` when one is named.
    /// Announced even when nothing changed: the same match picked twice is
    /// the second pick turning the showing back on.
    public func highlight(current index: Int? = nil) {
        guard let matches else { return }
        isHighlighting = true
        if let index { current = matches.range(at: index) }
        onAppearanceChanged?()
    }

    /// Shows the set, on a match a scan found rather than one out of the index.
    public func highlight(onMatch range: Range<UInt64>) {
        guard matches != nil else { return }
        isHighlighting = true
        current = range
        onAppearanceChanged?()
    }

    /// Moves the reader to the match at `index`; out of range clears it.
    public func setCurrent(_ index: Int?) {
        let range = index.flatMap { matches?.range(at: $0) }
        guard range != current else { return }
        current = range
        onAppearanceChanged?()
    }

    /// Ends the showing and keeps the set: a results list goes on listing the
    /// search that was run (§11).
    public func endHighlighting() {
        guard isHighlighting || current != nil else { return }
        isHighlighting = false
        current = nil
        onAppearanceChanged?()
    }

    // MARK: - Stopping

    /// Stops a pass or a step's scan in flight, and leaves the index alone.
    public func cancelNavigation() {
        navigationFlag?.cancel()
        navigationFlag = nil
        passInFlight = nil
    }

    /// Stops the index in flight. What it has covered stays, and is true.
    public func stopIndexing() {
        indexFlag?.cancel()
        indexFlag = nil
        indexTask = nil
        indexActivity?.finish()
        indexActivity = nil
    }

    /// Stops everything in flight.
    public func cancel() {
        cancelNavigation()
        stopIndexing()
    }

    /// The content changed under the search: every position in the set is a
    /// guess now, so the set goes rather than shifts, and the next press scans
    /// afresh.
    public func invalidate() {
        cancel()
        guard matches != nil || current != nil || isHighlighting else { return }
        matches = nil
        current = nil
        isHighlighting = false
        onSetChanged?()
        onAppearanceChanged?()
    }

    // MARK: - Inside

    private var navigationFlag: FindCancelFlag?
    private var indexFlag: FindCancelFlag?
    private var indexTask: Task<Void, Never>?
    private var indexActivity: (any FindActivity)?

    private func placeholder(for query: Query, in content: Content) -> Matches {
        Matches(query: query, matchLength: content.matchLength(of: query),
                extent: content.extent, starts: [], indexedUpTo: 0)
    }

    /// Installs a new set, and shows it: a search was just started.
    private func install(_ set: Matches) {
        matches = set
        current = nil
        isHighlighting = true
        onSetChanged?()
        onAppearanceChanged?()
    }

    private func beginNavigation() -> (FindCancelFlag, (any FindActivity)?) {
        let flag = FindCancelFlag()
        navigationFlag = flag
        let activity = beginActivity? { [weak self] in self?.cancelNavigation() }
        return (flag, activity)
    }

    private func startIndexing(_ query: Query) {
        stopIndexing()
        guard let content else { return }
        let flag = FindCancelFlag()
        indexFlag = flag
        let activity = beginActivity? { [weak self] in self?.cancel() }
        indexActivity = activity
        let extent = content.extent
        let length = content.matchLength(of: query)
        let interval = publishInterval
        indexTask = Task { [weak self] in
            let stream = content.matchStarts(of: query, shouldCancel: { flag.isCancelled },
                                             progress: { activity?.report($0) })
            var builder = MatchSetBuilder(query: query, matchLength: length, extent: extent)
            var publishedUpTo: UInt64 = 0
            var lastPublish = Date.distantPast
            do {
                for try await batch in stream {
                    builder.add(batch.starts)
                    // On a cadence, not per batch: a common byte yields
                    // thousands of them, and each publish copies the index.
                    guard Date().timeIntervalSince(lastPublish) >= interval,
                          batch.scannedUpTo > publishedUpTo else { continue }
                    let filled = publishedUpTo..<batch.scannedUpTo
                    publishedUpTo = batch.scannedUpTo
                    lastPublish = Date()
                    self?.fill(builder.snapshot(indexedUpTo: batch.scannedUpTo), over: filled,
                               flag: flag)
                }
            } catch {
                // A failed read leaves the index where it got to: what landed
                // is true.
            }
            activity?.finish()
            guard let self, self.indexFlag === flag, !flag.isCancelled else { return }
            self.indexFlag = nil
            self.indexTask = nil
            self.indexActivity = nil
            self.fill(builder.finish(), over: publishedUpTo..<max(publishedUpTo, extent), flag: flag)
        }
    }

    /// The index reached further. Dropped when it is a superseded index's.
    private func fill(_ set: Matches, over range: Range<UInt64>, flag: FindCancelFlag) {
        guard !flag.isCancelled, let existing = matches, existing.query == set.query else { return }
        let hadMatches = !existing.isEmpty
        matches = set
        onFilled?(range)
        if !hadMatches, !set.isEmpty { onFoundSomething?(set.query) }
    }
}

/// A flag a scan on another thread reads to learn it should stop.
final class FindCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// One step through a set: the match at `index`, its range, and whether the
/// step came round the end of the content — a single match steps onto
/// itself, which is a wrap too.
public struct MatchStep: Equatable, Sendable {
    public let index: Int
    public let range: Range<UInt64>
    public let wrapped: Bool

    public init(index: Int, range: Range<UInt64>, wrapped: Bool) {
        self.index = index
        self.range = range
        self.wrapped = wrapped
    }
}
