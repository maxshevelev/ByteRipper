import Cocoa
import HelpUI
import Localization

/// The head of a code screen's navigator says whether the analysis server
/// answers: a cloud, or a red cloud struck through. The sheets that report a
/// failed read come only when something was asked of the server; this is its
/// state at any moment. With the analyses kept on this Mac there is no server
/// to speak of, and it shows nothing.
// help: panel.code.server
final class CodeServerIndicator: NSImageView {
    private let location: CodeAnalysisLocation

    init(location: CodeAnalysisLocation = .shared) {
        self.location = location
        super.init(frame: .zero)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
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
        let symbol: String
        switch state {
        case .local:
            isHidden = true
            return
        case .connecting:
            // Not yet known either way: neither a promise nor an alarm.
            symbol = "cloud"
            contentTintColor = .tertiaryLabelColor
            ControlHelp.describe(self, L("Connecting to the analysis server…"))
        case .connected:
            symbol = "cloud"
            contentTintColor = .secondaryLabelColor
            ControlHelp.describe(self, L("The analysis server is available: %1$@", location.serverAddress))
        case .refused(let reason), .unreachable(let reason):
            symbol = "cloud.slash"
            contentTintColor = .systemRed
            ControlHelp.describe(self, L("The analysis server is not available. %1$@", reason))
        }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolName = symbol
        isHidden = false
    }

    /// The symbol on show, for a test; an image does not say its name.
    private(set) var symbolName: String?
}
