import AppKit
import HelpBook

/// The question mark in a circle that opens the help at the page about what it
/// stands beside.
///
/// Two shapes, because the app has two kinds of place to put one and the
/// platform has a different answer for each:
///
/// - `standard()` is AppKit's own round help button, which is what belongs at
///   the bottom-left of a dialog, a form or a settings pane. It is the control
///   a Mac user already knows, so it is not redrawn by hand.
/// - `inline()` is a borderless `questionmark.circle` glyph, sized and tinted
///   like the other icon controls in a panel's chrome. A 28-point panel header
///   cannot hold a bezelled round button, and one drawn there would read as a
///   button somebody forgot to style.
///
/// Both carry the destination themselves, so a caller wires nothing: the button
/// knows its page and opens it.
@MainActor public final class HelpButton: NSButton {
    private let destination: HelpLink

    /// The platform's round `?`, for a form or a dialog.
    public static func standard(for link: HelpLink, tooltip: String? = nil) -> HelpButton {
        let button = HelpButton(destination: link)
        button.bezelStyle = .helpButton
        button.title = ""
        button.configure(tooltip: tooltip)
        return button
    }

    /// A quiet glyph, for a panel's own chrome.
    public static func inline(for link: HelpLink, tooltip: String? = nil,
                              pointSize: CGFloat = 12) -> HelpButton {
        let button = HelpButton(destination: link)
        button.image = NSImage(systemSymbolName: "questionmark.circle",
                               accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize,
                                                                 weight: .regular)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.configure(tooltip: tooltip)
        return button
    }

    private init(destination: HelpLink) {
        self.destination = destination
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(tooltip: String?) {
        target = self
        action = #selector(open)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
        let label = tooltip ?? Self.describe(destination)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
    }

    /// The page this button opens, for the tests that check a `?` points where
    /// it should.
    public var opens: HelpLink { destination }

    @objc private func open() {
        HelpPresenter.show(destination)
    }

    /// "Help: What the Colours Mean" — the destination's own title, so the
    /// tooltip says where the button goes rather than "Help".
    private static func describe(_ link: HelpLink) -> String {
        let book = Help.shared
        switch link {
        case .topic(let id):
            return "Help: " + (book.topic(id)?.title ?? id.rawValue)
        case .term(let id):
            return "Help: " + (book.term(id)?.name ?? id.rawValue)
        }
    }
}
