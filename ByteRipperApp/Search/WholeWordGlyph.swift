import AppKit

/// The whole-word toggle's glyph (#41): "ab" over a bracket, as the editors
/// readers know draw it. SF Symbols has no such sign, so it is drawn here — a
/// template image, tinted by the button like the symbols beside it, and as
/// tall as `textformat` at the same size, so the toggles stand in one line.
enum WholeWordGlyph {
    static func image(pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
        let reference = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))?.size
        let size = NSSize(width: ceil(pointSize * 1.45), height: ceil(reference?.height ?? pointSize) + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            // The bracket's stroke carries the weight, as the letters do.
            let line = weight == .semibold ? pointSize / 9 : pointSize / 12
            let bracketY = line / 2 + 0.5
            let rise = pointSize * 0.22
            let inset = line / 2 + pointSize * 0.06
            let bracket = NSBezierPath()
            bracket.move(to: NSPoint(x: inset, y: bracketY + rise))
            bracket.line(to: NSPoint(x: inset, y: bracketY))
            bracket.line(to: NSPoint(x: rect.width - inset, y: bracketY))
            bracket.line(to: NSPoint(x: rect.width - inset, y: bracketY + rise))
            bracket.lineWidth = line
            bracket.lineJoinStyle = .round
            bracket.lineCapStyle = .round
            NSColor.black.setStroke()
            bracket.stroke()
            let font = NSFont.systemFont(ofSize: pointSize * 0.95, weight: weight)
            let text = NSAttributedString(string: "ab", attributes: [.font: font,
                                                                     .foregroundColor: NSColor.black])
            let baseline = bracketY + line + 1.2
            text.draw(at: NSPoint(x: (rect.width - text.size().width) / 2, y: baseline + font.descender))
            return true
        }
        image.isTemplate = true
        return image
    }
}
