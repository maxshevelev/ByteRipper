import AppKit
import AppPalette

/// How a labelled value is drawn — the colour intent the side that knows the
/// fact behind a value decides (e.g. a File System State's status). The view
/// resolves each tone into the app's palette; a value carries `.standard`
/// unless it says otherwise.
///
/// Lived with the ME Analyzer's Summary model, then with the shared
/// presentation over it. It is here because it is the same kind of thing as
/// `ToolRowMarks`: a vocabulary two panels draw by, belonging to neither.
/// `MEFirmware`'s engine has no opinion on a colour, and a pure tool-module
/// target may not reach the other's presentation package — this is the one
/// place both can.
public enum ToolValueTone: Sendable, Equatable, Hashable {
    /// The ordinary label-colour value most rows carry.
    case standard
    /// A settled state — drawn green.
    case good
    /// A state in the middle of its lifecycle — drawn brown.
    case caution
    /// A failed state — drawn red.
    case bad

    /// Whether the value carries a status at all. One that does is drawn bold as
    /// well as coloured: the weight is what makes a state read at a glance
    /// rather than as one more line of text.
    public var isStatus: Bool { self != .standard }

    /// The colour the app draws it in.
    ///
    /// The tones are the app's meanings, so the colours are the app's palette
    /// (`SemanticColors`) rather than three shades mixed here: "Configured" in
    /// the ME panel and a granted permission in the UEFI one are the same green
    /// because they are the same statement.
    public var color: NSColor {
        switch self {
        case .standard: return SemanticColors.plain
        case .good: return SemanticColors.good
        case .caution: return SemanticColors.caution
        case .bad: return SemanticColors.bad
        }
    }

    /// The font a value with this tone is drawn in: hex is monospaced so offsets
    /// and sizes line up down a list, everything else is the body font, bold
    /// when the value carries a status.
    public func font(for value: String) -> NSFont {
        value.hasPrefix("0x")
            ? ToolPanelFont.monospacedDigits()
            : ToolPanelFont.body(weight: isStatus ? .bold : .regular)
    }

    /// The value as it is drawn: the text itself, and — ahead of it, for a tone
    /// that is a passed check — the tick that says so.
    ///
    /// In the attributed string rather than in a view beside the label, so the
    /// mark wraps and selects with what it marks: a value long enough to wrap
    /// carries its tick on the first line, and copying the row copies both.
    ///
    /// The tick and not a filled disc: at a label's size the disc's own tick is
    /// a few pixels across and the mark reads as a green dot on the row rather
    /// than as "this checks out".
    public func attributedValue(_ value: String) -> NSAttributedString {
        let font = font(for: value)
        let result = NSMutableAttributedString()
        if self == .good, let tick = NSImage(systemSymbolName: "checkmark",
                                             accessibilityDescription: "Done")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            ) {
            let attachment = NSTextAttachment()
            attachment.image = tick
            // Sat on the text's baseline, not above it.
            attachment.bounds = NSRect(x: 0, y: font.descender, width: tick.size.width,
                                       height: tick.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: value))
        result.addAttributes([.font: font, .foregroundColor: color],
                             range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Draws `field` the way the app draws a labelled value — the font, the
    /// colour, and the mark a passed check carries. The one call every panel
    /// makes, so the same fact cannot read two ways in two of them.
    public func draw(_ field: NSTextField, value: String) {
        field.attributedStringValue = attributedValue(value)
    }
}
