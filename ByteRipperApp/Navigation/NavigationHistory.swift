import Foundation

/// The places a tab's jumps have left behind, and the way back to them (§10.6).
///
/// A jump — Go To, a difference, a search result, a click on the minimap —
/// records the place it leaves. **Back** returns to the last such place and
/// keeps the one it left on the forward stack; **Forward** goes the other way.
/// Walking the history records nothing of its own, and a new jump clears the
/// forward stack, the way a browser's history does.
///
/// What counts as a jump is decided by the callers, not here: an arrow key or
/// a scroll is not one, and a history that filled up a row at a time would be
/// one nobody could use.
///
/// Generic over the place, so it is tested without a document. A place can
/// stop being reachable — its file closed, another file opened in its pane —
/// and the walk steps over such places rather than landing nowhere.
struct NavigationHistory<Place: Equatable> {
    /// How far back the history reaches. A bench session makes many jumps, but
    /// nobody walks fifty of them back.
    static var capacity: Int { 50 }

    private(set) var backStack: [Place] = []
    private(set) var forwardStack: [Place] = []

    /// A jump is leaving `place`. Nothing is recorded when the last place
    /// recorded is this one: two jumps from the same spot are one way back.
    mutating func record(leaving place: Place) {
        forwardStack.removeAll()
        guard backStack.last != place else { return }
        backStack.append(place)
        if backStack.count > Self.capacity {
            backStack.removeFirst(backStack.count - Self.capacity)
        }
    }

    /// Whether Back has somewhere to go from `current`.
    func canGoBack(from current: Place, isReachable: (Place) -> Bool) -> Bool {
        backStack.contains { $0 != current && isReachable($0) }
    }

    func canGoForward(from current: Place, isReachable: (Place) -> Bool) -> Bool {
        forwardStack.contains { $0 != current && isReachable($0) }
    }

    /// The place Back goes to from `current`, or nil when there is none. The
    /// places stepped over — unreachable, or the one the user is already on —
    /// are dropped; `current` goes onto the forward stack.
    mutating func goBack(from current: Place, isReachable: (Place) -> Bool) -> Place? {
        guard let place = Self.pop(&backStack, skipping: current, isReachable) else { return nil }
        forwardStack.append(current)
        return place
    }

    mutating func goForward(from current: Place, isReachable: (Place) -> Bool) -> Place? {
        guard let place = Self.pop(&forwardStack, skipping: current, isReachable) else { return nil }
        backStack.append(current)
        return place
    }

    mutating func removeAll() {
        backStack.removeAll()
        forwardStack.removeAll()
    }

    private static func pop(_ stack: inout [Place], skipping current: Place,
                            _ isReachable: (Place) -> Bool) -> Place? {
        guard stack.contains(where: { $0 != current && isReachable($0) }) else { return nil }
        while let place = stack.popLast() {
            if place != current && isReachable(place) { return place }
        }
        return nil
    }
}
