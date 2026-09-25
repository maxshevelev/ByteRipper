import Cocoa
import HelpUI

/// The small symbol buttons at the trailing end of a panel's header: the ✕ that
/// closes it, and the ⌄ that folds a fragment panel into its pill.
///
/// One factory because the headers are read as one piece of chrome, and built
/// separately they drifted — the hex panel's ✕ was a 10 pt semibold glyph in a
/// grey tint beside the tool panel's plain one, which is the same mark twice in
/// two sizes rather than one mark.
@MainActor enum HeaderButton {
    /// The side of the square each of them occupies. The glyph itself is left at
    /// the system's own size: it is the size everything else in the chrome is
    /// drawn at, and a symbol shrunk below it stops looking like the chrome and
    /// starts looking like a mistake.
    static let side: CGFloat = 16

    /// - Parameters:
    ///   - describes: what the button *is* — its name, which is what a screen
    ///     reader says and what a test finds it by.
    ///   - tooltip: what it *does*, when that is a longer sentence than the
    ///     name. Left out, the name serves as both, which is the common case.
    ///
    /// Both go in through `ControlHelp`, the one door a control's words come
    /// from: before it, a button set its tooltip in one place and its
    /// accessibility label in another, and the two drifted.
    static func make(symbol: String, describes name: String, tooltip: String? = nil,
                     target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        button.imagePosition = .imageOnly
        // The default button type dims the glyph while it is held, which is the
        // whole of the press feedback these have; `.momentaryChange` swapped in
        // an `alternateTitle` that was never set, so a press showed nothing.
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = target
        button.action = action
        ControlHelp.describe(button, name: name, tooltip: tooltip ?? name)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}
