import Foundation

/// The files opened most recently, most recent first, for File ▸ Open Recent.
///
/// A separate list from `SandboxBookmarkStore`'s ordering: that store is a
/// write-access cache (capped at 300, it also records Save As destinations, and
/// it prunes for liveness) and a recent-files menu wants a short list of what
/// the user actually *opened*. Recorded on a successful open, right beside the
/// bookmark's own record, so the two stay in step.
///
/// Local by design: the list lives in `UserDefaults` like the find bar's
/// history, and is not published to a shared file (`FavoritePatternStore`
/// keeps its list as a file because it syncs across machines; recents do not).
enum RecentFilesStore {
    static let userDefaultsKey = "RecentFiles"

    /// How many opened files the menu is worth showing. More than a reader
    /// re-opens from memory, and the menu's width is not an argument for
    /// hundreds of rows.
    static let limit = 10

    /// The defaults domain the list lives in. Swappable so a test run against
    /// an isolated store instead of the real app's defaults (`AppDefaults`).
    static var defaults: UserDefaults = AppDefaults.store

    /// The opened paths, standardized, most recent first.
    static var recent: [String] {
        defaults.array(forKey: userDefaultsKey) as? [String] ?? []
    }

    /// Forgets every recent file — **Clear Menu** in File ▸ Open Recent.
    static func clear() {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// Drops paths whose file is no longer on disk. A row that cannot be
    /// opened is a greyed ghost in the menu, and the ghost outlives the file
    /// by exactly as long as the list is not touched — which can be forever.
    ///
    /// Called at launch, the way `SandboxBookmarkStore.pruneNow` is for the
    /// bookmarks: the two lists are independent, so one's pruning does not
    /// reach the other's dead weight.
    static func pruneMissing() {
        let kept = recent.filter { FileManager.default.fileExists(atPath: $0) }
        guard kept.count != recent.count else { return }
        defaults.set(kept, forKey: userDefaultsKey)
    }

    /// Records a successful open: moves the path to the front, dropping any
    /// older entry for the same path, and capping the list at `limit`.
    ///
    /// Returns whether the list actually changed. Re-opening the file already
    /// at the front changes nothing, and that is the common case: the open
    /// pipeline records on every success, and the caller would otherwise
    /// rewrite the list for nothing.
    @discardableResult
    static func record(_ url: URL) -> Bool {
        // Standardized to match `SandboxBookmarkStore`'s keying, so the path a
        // recent row carries and the path its bookmark is filed under are the
        // same string.
        let path = url.standardizedFileURL.path
        let before = recent
        var entries = before.filter { $0 != path }
        entries.insert(path, at: 0)
        let capped = Array(entries.prefix(limit))
        guard capped != before else { return false }
        defaults.set(capped, forKey: userDefaultsKey)
        return true
    }
}
