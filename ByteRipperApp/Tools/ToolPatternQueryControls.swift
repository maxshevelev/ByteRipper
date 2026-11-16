import Cocoa
import ByteRipperCore
import ToolModuleKit

/// The Find bar's pattern controls, handed to a tool-module that searches
/// bytes (`ToolPatternQuery`): the same field, menu, encoding, Smart Search and
/// case toggle (`PatternQueryControls`), so the recent queries and the pattern
/// library are the dump's own, and keeping a pattern or managing the library
/// opens the same sheet and the same form.
///
/// What it adds is the translation the module needs: the field's request as
/// the attempts to make, in order, and what came of them back into the
/// controls.
@MainActor
final class ToolPatternQueryControls: ToolPatternQuery {
    let controls = PatternQueryControls()
    let view: NSView
    var onSubmit: (() -> Void)?
    var onEdited: (() -> Void)?
    var onProblem: ((String?, String?) -> Void)?

    /// Whether the search about to run is one to remember if it finds
    /// anything: a typed one is, a row picked out of the menu is not (§11).
    private var recording = true

    init(owner: MainViewController?) {
        let row = NSStackView(views: controls.views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        for control in controls.views where control !== controls.patternField {
            control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            control.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        controls.patternField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.patternField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.patternField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        view = row

        controls.onSubmit = { [weak self] in
            self?.recording = true
            self?.onSubmit?()
        }
        controls.onPicked = { [weak self] in
            self?.recording = false
            self?.onSubmit?()
        }
        controls.onPatternEdited = { [weak self] in self?.onEdited?() }
        controls.onPatternError = { [weak self] label, detail in self?.onProblem?(label, detail) }
        controls.onError = { [weak self] message in self?.onProblem?(message, message) }
        controls.onAddToFavorites = { [weak owner] entry in owner?.askToKeepPattern(entry) }
        controls.onManageFavorites = {
            (NSApp.delegate as? AppDelegate)?.showFavoritePatternSettings()
        }
        controls.reloadStandingChoices()
    }

    var text: String {
        get { controls.text }
        set { controls.text = newValue }
    }

    func attempts() -> [ToolPatternAttempt]? {
        let records = recording
        recording = true
        // The field is read as the dump's bar reads it — `24 ?? 4D 49` is
        // bytes with a hole in them, in hex and in Smart Search's hex attempt
        // alike — so a pattern finds in a panel what it finds in the dump.
        guard let request = controls.searchRequest() else { return nil }  // said through onProblem
        controls.noteSearchStarted(recording: records)
        switch request {
        case .pattern(let pattern, let folding):
            controls.normalizeHexText(of: pattern)
            return [Self.attempt(pattern, folding: folding, encoding: pattern.encoding)]
        case .smart(let text, let caseSensitive, let preferring):
            let attempts = SmartSearch.attempts(for: text, caseSensitive: caseSensitive, preferring: preferring)
            guard !attempts.isEmpty else {
                controls.reportNoUsablePattern()
                return nil
            }
            return attempts.map { Self.attempt($0.pattern, folding: $0.folding, encoding: $0.encoding) }
        }
    }

    private static func attempt(_ pattern: SearchPattern, folding: CaseFolding,
                                encoding: SearchEncoding) -> ToolPatternAttempt {
        ToolPatternAttempt(pattern: MaskedPattern(pattern, folding: folding),
                           encoding: encoding.rawValue, encodingName: encoding.displayName)
    }

    func found(encoding: String) {
        guard let encoding = SearchEncoding(rawValue: encoding) else { return }
        if controls.isSmartSearchEnabled { controls.adopt(encoding: encoding) }
        controls.recordFoundSearch(encoding: encoding)
    }

    func focus() {
        controls.focus()
    }

    func adoptFindPasteboard(intoEmptyField: Bool) -> Bool {
        controls.adoptFindPasteboard(intoEmptyField: intoEmptyField)
    }

    func applyFont(_ font: NSFont) {
        controls.patternField.font = font
        controls.encodingPopup.font = font
    }
}
