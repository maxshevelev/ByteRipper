import AppKit

extension NSImage {
    /// A system symbol filled with `color`: drawn as a mask and filled, so it
    /// keeps the shape the system draws — the mark of a filled octagon is a hole
    /// in it, not a second colour — and a dynamic `color` is resolved when the
    /// image is drawn, in the appearance it is drawn in.
    ///
    /// The one way the app tints a symbol it cannot hand to a control's
    /// `contentTintColor`: an alert's icon, a mark inside attributed text, a
    /// drag image. Painting its layers (`paletteColors`) is not it — a palette
    /// of one colour paints the mark over the hole.
    public static func tintedSymbol(
        _ name: String, configuration: NSImage.SymbolConfiguration, color: NSColor,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.accessibilityDescription = accessibilityDescription
        return tinted
    }
}
