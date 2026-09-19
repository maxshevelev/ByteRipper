import Cocoa

/// The small symbol buttons at the trailing end of a panel's header: the ✕ that
/// closes it, and the ⌄ that folds a fragment panel into its pill.
///
/// One factory because the headers are read as one piece of chrome, and built
/// separately they drifted — the hex panel's ✕ was a 10 pt semibold glyph in a
/// grey tint beside the tool panel's plain one, which is the same mark twice in
/// two sizes rather than one mark.
enum HeaderButton {
    /// The side of the square each of them occupies. The glyph itself is left at
    /// the system's own size: it is the size everything else in the chrome is
    /// drawn at, and a symbol shrunk below it stops looking like the chrome and
    /// starts looking like a mistake.
    static let side: CGFloat = 16

    static func make(symbol: String, label: String, tooltip: String,
                     target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        // The default button type dims the glyph while it is held, which is the
        // whole of the press feedback these have; `.momentaryChange` swapped in
        // an `alternateTitle` that was never set, so a press showed nothing.
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = target
        button.action = action
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}
