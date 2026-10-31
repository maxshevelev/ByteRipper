import AppKit

/// The navigator's marks, drawn as Xcode draws a symbol's kind: a glyph in
/// white on a small coloured square with rounded corners. A function's mark
/// says how far its review has got wherever the list shows one — a root of
/// the call tree, a call under it, a member of a review group — in the colour
/// of its level's heading, so the levels read apart before their names. A
/// fully reviewed function takes the colour function names have in the code;
/// purple is not used, since the app gives it to bookmarks.
///
/// The images draw when they are drawn, so a system colour follows the
/// appearance the row is drawn in.
enum CodeNavigatorIcon {
    /// What the square holds.
    enum Glyph: Equatable {
        /// A white letter on the filled square.
        case letter(String)
        /// The letter in the colour, in the square's outline.
        case framedLetter(String)
        /// A white symbol on the filled square.
        case symbol(String)
        /// A short name in a frame as wide as the name: a library function's
        /// kind — EDK2, AMD, Intel — drawn as the function stands to the
        /// library registry.
        case badge(String, BadgeStyle)
    }

    /// How a library badge is drawn: outlined for a library function the
    /// registry does not hold; filled for one that is the registry's entry;
    /// outlined with a dot for one the registry matched that is not its entry
    /// — edited since, differing, or in conflict.
    enum BadgeStyle: Equatable {
        case outlined, filled, dotted
    }

    /// A function's mark: a fully reviewed one, and any without a level of
    /// its own.
    static let function = (glyph: Glyph.letter("f"), color: CodeColors.function)
    /// A partly reviewed function: the same `f`, not yet filled in, in the
    /// partial heading's orange.
    static let partialFunction = (glyph: Glyph.framedLetter("f"), color: NSColor.systemOrange)
    /// A library routine: the badge of whose library it is, in the library
    /// heading's blue.
    static func library(_ name: String, style: BadgeStyle = .outlined) -> (glyph: Glyph, color: NSColor) {
        (.badge(name, style), .systemBlue)
    }

    /// How wide a mark is at `side`: a square, or a badge — its name and
    /// the frame's room on either side of it.
    static func width(of glyph: Glyph, side: CGFloat) -> CGFloat {
        guard case let .badge(name, style) = glyph else { return side }
        let ink = CTLineGetBoundsWithOptions(label(name, color: .labelColor, side: side), .useGlyphPathBounds)
        return (ink.width + 2 * badgeInset(side: side)).rounded(.up) + (style == .dotted ? dotRoom(side: side) : 0)
    }

    /// The dot's room beside a badge: it sits on the frame's corner, half
    /// outside it, and clear of the name.
    private static func dotSide(side: CGFloat) -> CGFloat { (side * 0.32).rounded() }
    private static func dotRoom(side: CGFloat) -> CGFloat { (dotSide(side: side) / 2).rounded(.up) + 1 }

    /// The room between a badge's frame and its name.
    private static func badgeInset(side: CGFloat) -> CGFloat {
        (side * 0.3).rounded()
    }

    /// A badge's name as a line: semibold, half the square's height.
    private static func label(_ name: String, color: NSColor, side: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: side * 0.5, weight: .semibold), .foregroundColor: color
        ]))
    }

    /// A review group's mark: the function names' colour for full, orange
    /// for partial, red for nothing done yet, blue for a library routine,
    /// grey where there is no level to have.
    static func group(_ group: CodeReaderState.FunctionGroup) -> (glyph: Glyph, color: NSColor) {
        switch group {
        case .full: (.symbol("checkmark"), CodeColors.function)
        case .partial: (.symbol("circle.lefthalf.filled"), .systemOrange)
        case .decompiled: (.symbol("gearshape"), .systemRed)
        case .library: (.symbol("books.vertical"), .systemBlue)
        case .noBody: (.symbol("minus"), .systemGray)
        case .unknown: (.symbol("questionmark"), .systemGray)
        }
    }

    /// The side of the square for a list read at `fontSize`: a little taller
    /// than the name's capitals, as Xcode's are beside a name.
    static func side(forFontSize fontSize: CGFloat) -> CGFloat {
        (fontSize + 3).rounded()
    }

    /// The mark at `side` points. `inverted` is the mark on a selected row:
    /// what is white there takes the colour and the colour turns white, so
    /// the mark still reads on the selection's own colour — except a library
    /// badge, which keeps its colours on a white plate.
    static func image(_ glyph: Glyph, color: NSColor, side: CGFloat, inverted: Bool = false) -> NSImage {
        let ground = inverted ? NSColor.white : color
        let ink = inverted ? color : NSColor.white
        let size = NSSize(width: width(of: glyph, side: side), height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let radius = (side * 0.26).rounded()
            switch glyph {
            case let .letter(letter):
                ground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                drawLetter(letter, color: ink, in: rect)
            case let .framedLetter(letter):
                let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                                         xRadius: radius - 0.5, yRadius: radius - 0.5)
                frame.lineWidth = 1.5
                ground.setStroke()
                frame.stroke()
                drawLetter(letter, color: ground, in: rect)
            case let .symbol(name):
                ground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                drawSymbol(name, color: ink, scale: 0.7, in: rect)
            case let .badge(name, style):
                // The frame and the name leave the dot its room on the right.
                let rect = style == .dotted
                    ? NSRect(x: rect.minX, y: rect.minY, width: rect.width - dotRoom(side: side), height: rect.height)
                    : rect
                // A badge keeps its own colours on a selected row, on a white
                // plate: inverted, a filled badge would read as the outlined
                // one beside it, and filled is what says the registry holds it.
                if inverted {
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 3.5, yRadius: 3.5).fill()
                }
                if style == .filled {
                    color.setFill()
                    let chip = inverted ? rect.insetBy(dx: 1.5, dy: 2.5) : rect.insetBy(dx: 0, dy: 1)
                    NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
                    drawLabel(name, color: .white, in: rect)
                } else {
                    let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5), xRadius: 3, yRadius: 3)
                    frame.lineWidth = 1
                    color.setStroke()
                    frame.stroke()
                    drawLabel(name, color: color, in: rect)
                }
                if style == .dotted {
                    // At the frame's top right corner, over its line, ringed
                    // in white so it reads off the frame.
                    // Centred on the frame's corner, its white ring inside the
                    // image: past the image's edge the ring would be cut,
                    // which shows on a selected row.
                    let dot = dotSide(side: side)
                    let spot = NSRect(x: rect.maxX - dot / 2 - 0.5, y: rect.maxY - dot - 1, width: dot, height: dot)
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: spot.insetBy(dx: -1, dy: -1)).fill()
                    color.setFill()
                    NSBezierPath(ovalIn: spot).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The letter centred by its own ink, not by the font's line: an `f`
    /// has an ascender and no descender, and would sit high in a line box.
    private static func drawLetter(_ letter: String, color: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let base = NSFont.systemFont(ofSize: rect.height * 0.74, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: [
            .font: font, .foregroundColor: color
        ]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A badge's name, centred by its ink in the frame made to fit it.
    private static func drawLabel(_ name: String, color: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = label(name, color: color, side: rect.height)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The symbol centred in `rect`, no larger than `scale` of it.
    private static func drawSymbol(_ name: String, color: NSColor, scale: CGFloat, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.56 / scale * 0.7,
                                                        weight: scale < 1 ? .bold : .regular)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let fit = min(rect.width * scale / max(symbol.size.width, 1), rect.height * scale / max(symbol.size.height, 1))
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
}

/// The triangle that opens a function's calls or a group's functions: a
/// chevron, as the sidebar of a current Mac app draws it, that turns down when
/// the row opens. A click turns it in a short animation; a row drawn again
/// sets it where it belongs without one.
final class CodeDisclosureButton: NSButton {
    private let chevron = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        setButtonType(.onOff)
        imagePosition = .noImage
        focusRingType = .none
        wantsLayer = true
        chevron.fillColor = nil
        chevron.lineWidth = 1.5
        chevron.lineCap = .round
        chevron.lineJoin = .round
        layer?.addSublayer(chevron)
        setAccessibilityRole(.disclosureTriangle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // A system colour resolves in the appearance the button draws in.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chevron.strokeColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side: CGFloat = 8
        chevron.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        chevron.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // ">" drawn symmetric about its middle, so a flipped layer draws the
        // same shape.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: side * 0.3, y: side * 0.08))
        path.addLine(to: CGPoint(x: side * 0.72, y: side * 0.5))
        path.addLine(to: CGPoint(x: side * 0.3, y: side * 0.92))
        chevron.path = path
        chevron.setAffineTransform(turn(state == .on))
        CATransaction.commit()
    }

    /// Down when open: a quarter turn the way that brings the point down in
    /// the layer's own geometry.
    private func turn(_ open: Bool) -> CGAffineTransform {
        guard open else { return .identity }
        let down: CGFloat = chevron.contentsAreFlipped() ? .pi / 2 : -.pi / 2
        return CGAffineTransform(rotationAngle: down)
    }

    /// Sets the chevron to `open`, turning it when `animated`.
    func setOpen(_ open: Bool, animated: Bool) {
        state = open ? .on : .off
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        chevron.setAffineTransform(turn(open))
        CATransaction.commit()
    }
}
