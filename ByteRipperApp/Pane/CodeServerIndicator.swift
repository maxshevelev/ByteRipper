import AppPalette
import Cocoa
import HelpUI
import Localization
import Symbols

/// The head of a code screen's navigator says whether the analysis server
/// answers: a cloud; a brown one with an exclamation mark while its heartbeat is
/// late; a red one with a cross when the connection is lost. The sheets that
/// report a failed read come only when something was asked of the server; this
/// is its state at any moment. With the analyses kept on this Mac there is no
/// server to speak of, and it shows nothing.
// help: panel.code.server
final class CodeServerIndicator: NSImageView {
    private let location: CodeAnalysisLocation

    init(location: CodeAnalysisLocation? = nil) {
        let location = location ?? .shared
        self.location = location
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(locationChanged),
                                               name: CodeAnalysisLocation.didChange, object: location)
        show(location.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func locationChanged() {
        show(location.state)
    }

    private func show(_ state: CodeAnalysisLocation.State) {
        isPulsing = false
        removeAllSymbolEffects(options: .default, animated: false)
        let symbol: String
        // The warning's lines are heavier: at this size a thin mark on a thin
        // cloud is easily read as the ordinary one.
        var weight = NSFont.Weight.regular
        switch state {
        case .local:
            isHidden = true
            return
        case .connecting:
            // Not yet known either way, and under way: the system's own pulse.
            symbol = "icloud"
            contentTintColor = SemanticColors.quiet
            isPulsing = true
            ControlHelp.describe(self, L("Connecting to the analysis server…"))
        case .connected:
            if location.isServerDoubtful {
                symbol = "exclamationmark.icloud"
                weight = .bold
                contentTintColor = SemanticColors.caution
                ControlHelp.describe(self, location.serverHasNoHeartbeat
                    ? L("This analysis server sends no heartbeat, so a lost connection shows late: %1$@", location.serverAddress)
                    : L("The analysis server's heartbeat is late: %1$@", location.serverAddress))
            } else {
                symbol = "icloud"
                contentTintColor = SemanticColors.quiet
                ControlHelp.describe(self, L("The analysis server is available: %1$@", location.serverAddress))
            }
        case .refused(let reason), .unreachable(let reason):
            symbol = "xmark.icloud.fill"
            contentTintColor = SemanticColors.bad
            ControlHelp.describe(self, L("The analysis server is not available. %1$@", reason))
        }
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolName = symbol
        isHidden = false
        if isPulsing { addSymbolEffect(.pulse, options: .repeating, animated: true) }
    }

    /// Whether the cloud is pulsing, for a test; a view does not say.
    private(set) var isPulsing = false

    /// The symbol on show, for a test; an image does not say its name.
    private(set) var symbolName: String?
}
