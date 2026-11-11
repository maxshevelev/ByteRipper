import Foundation

/// A search of the code panel as the history keeps it: the text, and the two
/// rules it was searched under (#41).
struct CodeQueryEntry: Equatable {
    var pattern: String
    var caseSensitive: Bool
    var wholeWord: Bool

    init(pattern: String, caseSensitive: Bool, wholeWord: Bool) {
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }

    init?(stored: [String: Any]) {
        guard let pattern = stored["pattern"] as? String, !pattern.isEmpty else { return nil }
        self.pattern = pattern
        caseSensitive = stored["caseSensitive"] as? Bool ?? false
        wholeWord = stored["wholeWord"] as? Bool ?? false
    }

    var storedValue: [String: Any] {
        ["pattern": pattern, "caseSensitive": caseSensitive, "wholeWord": wholeWord]
    }
}

/// The recent searches of the code panel, apart from the dump's (#41): a byte
/// pattern is noise in C, and a name is noise in a dump. What the two share is
/// the find string macOS keeps for every program (`FindPasteboard`), not the
/// history.
///
/// The same rules as `FindHistoryStore`: only a search that found something is
/// recorded, most recent first, one entry per text, at most `limit`.
enum CodeFindHistoryStore {
    static let userDefaultsKey = "CodeFindHistory"
    static let limit = 10

    /// Swappable so tests run against an isolated store.
    static var defaults: UserDefaults = AppDefaults.store

    static var recent: [CodeQueryEntry] {
        guard let raw = defaults.array(forKey: userDefaultsKey) as? [[String: Any]] else { return [] }
        return raw.compactMap(CodeQueryEntry.init(stored:))
    }

    static var mostRecent: CodeQueryEntry? { recent.first }

    static func clear() {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// Moves `entry` to the front, replacing an older one of the same text —
    /// the rules ride along, the latest search's winning. Returns whether the
    /// list changed.
    @discardableResult
    static func record(_ entry: CodeQueryEntry) -> Bool {
        var entry = entry
        entry.pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.pattern.isEmpty else { return false }
        let before = recent
        var entries = before.filter { $0.pattern != entry.pattern }
        entries.insert(entry, at: 0)
        let capped = Array(entries.prefix(limit))
        guard capped != before else { return false }
        defaults.set(capped.map(\.storedValue), forKey: userDefaultsKey)
        return true
    }
}
