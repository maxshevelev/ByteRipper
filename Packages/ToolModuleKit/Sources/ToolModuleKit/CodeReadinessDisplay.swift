import Foundation

/// Whether a tree row with a stored code analysis wears the readiness circle
/// (empty, half filled, filled: how far the module's review has got) or the
/// plain code-analysis mark every such row wore before the review was graded.
///
/// The switch is in Settings ▸ Code Analysis. A tool-module never links the
/// app, so — as with `ToolPanelFont` — the key and the notification are spelled
/// here, and the app's settings tab writes through `set`. The value is read
/// live, by the cell as it is drawn: a panel only has to reload its rows when
/// `didChange` arrives.
public enum CodeReadinessDisplay {
    /// The `UserDefaults` key the Settings checkbox writes.
    public static let showsReadinessKey = "ShowsCodeReadiness"

    /// Posted after the switch moves, so a panel on screen redraws its rows.
    public static let didChange = Notification.Name("CodeReadinessDisplayDidChange")

    /// The plain mark a row wears with the circle switched off: the curly
    /// braces the badge was before the review had a grade.
    public static let plainSymbol = "ellipsis.curlybraces"

    /// Whether the circle is drawn. On with nothing stored: `object(forKey:)`
    /// tells "never set" from "set to false", which `bool(forKey:)` does not.
    public static var showsReadiness: Bool {
        ToolPanelFont.defaults.object(forKey: showsReadinessKey) as? Bool ?? true
    }

    public static func set(showsReadiness: Bool) {
        ToolPanelFont.defaults.set(showsReadiness, forKey: showsReadinessKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Calls `handler` on the main queue whenever the switch moves; the caller
    /// keeps the token.
    public static func observe(
        _ handler: @escaping @Sendable @MainActor () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
