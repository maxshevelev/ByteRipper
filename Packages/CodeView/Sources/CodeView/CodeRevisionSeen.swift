import CodeAnalysis
import Foundation

/// The revision each function was last seen at, and the code it had then —
/// kept between launches, per module and reading (recipe). With it the panel
/// knows, when it opens, which functions changed while the app was closed: a
/// function whose code reads otherwise than it did when the reader last saw
/// it is new to them, and shows the mark and the comparison it stands for.
///
/// The artifact itself is not kept: the revision in a record names the code in
/// the store, and that is read again when the mark is put up.
public struct SeenRecord: Codable, Equatable, Sendable {
    /// The revision the reader last saw the function at.
    public var revision: Int
    /// The function as it read then: a digest of its name, signature and C.
    public var fingerprint: String

    public init(revision: Int, fingerprint: String) {
        self.revision = revision
        self.fingerprint = fingerprint
    }

    /// The digest that stands for a function's code in a record.
    public static func fingerprint(name: String, signature: String?, c: String?) -> String {
        CodeArtifact.fingerprint(name: name, signature: signature, c: c)
    }
}

/// The records kept between launches: `"<module>/<recipe>": ["0x9A0629E": …]`.
@MainActor
public enum CodeRevisionSeen {
    private static let key = "CodeRevisionSeen"

    private static func load() -> [String: [String: SeenRecord]] {
        guard let data = CodePaneView.defaults.data(forKey: key),
              let seen = try? JSONDecoder().decode([String: [String: SeenRecord]].self, from: data) else {
            return [:]
        }
        return seen
    }

    /// What was kept for one reading: each function's entry and its record.
    public static func records(module: SHA256Digest, recipe: String) -> [String: SeenRecord] {
        load()[name(module: module, recipe: recipe)] ?? [:]
    }

    /// Keeps a reading's records; a reading with none is taken out of the store.
    public static func save(_ records: [String: SeenRecord], module: SHA256Digest, recipe: String) {
        var all = load()
        if records.isEmpty {
            all.removeValue(forKey: name(module: module, recipe: recipe))
        } else {
            all[name(module: module, recipe: recipe)] = records
        }
        if let data = try? JSONEncoder().encode(all) {
            CodePaneView.defaults.set(data, forKey: key)
        }
    }

    // MARK: - Whether the marks are kept at all

    /// The `UserDefaults` key Settings ▸ Code Analysis writes.
    public static let tracksNewMarksKey = "TracksNewCodeMarks"

    /// Posted after the switch moves, so a pane on screen follows it.
    public static let trackingDidChange = Notification.Name("CodeNewMarkTrackingDidChange")

    /// Whether a function or a description a revision changed is put up as
    /// New. On with nothing stored: `object(forKey:)` tells "never set" from
    /// "set to false".
    ///
    /// Off means every change counts as read the moment it is on screen: no
    /// mark, no banner, and the records go on being written — each pane drawn
    /// records what it shows as seen at its revision. Switching the marks off
    /// forgets every reading's records: a reading with none is a first open,
    /// which is seeded as seen and marks nothing. So a module not opened while
    /// the marks were off is not, once they are on again, marked for every
    /// change it took in that time; a module opened then is as far along as
    /// what was on screen. With the marks back on, the next revision that
    /// changes a function marks it, as before.
    public static var tracksNewMarks: Bool {
        CodePaneView.defaults.object(forKey: tracksNewMarksKey) as? Bool ?? true
    }

    public static func set(tracksNewMarks: Bool) {
        let was = self.tracksNewMarks
        CodePaneView.defaults.set(tracksNewMarks, forKey: tracksNewMarksKey)
        // Forgotten before the panes hear of it: each then records its own
        // reading as seen, and that record stays.
        if was, !tracksNewMarks { clear() }
        NotificationCenter.default.post(name: trackingDidChange, object: nil)
    }

    /// Calls `handler` on the main queue whenever the switch moves; the caller
    /// keeps the token.
    public static func observeTracking(
        _ handler: @escaping @Sendable @MainActor () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: trackingDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// For a test: forget everything kept.
    static func clear() {
        CodePaneView.defaults.removeObject(forKey: key)
    }

    private static func name(module: SHA256Digest, recipe: String) -> String {
        "\(module.hex)/\(recipe)"
    }
}
