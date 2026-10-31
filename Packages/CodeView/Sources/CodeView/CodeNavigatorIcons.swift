import AppKit

/// The navigator's marks, drawn as Xcode draws a symbol's kind: a glyph in
/// white on a small coloured square with rounded corners. A function is an
/// `f` on purple wherever the list shows one — a root of the call tree, a
/// call under it, a member of a review group. A review group's heading
/// carries its level's colour, so the levels read apart before their names.
///
/// The images draw when they are drawn, so a system colour follows the
/// appearance the row is drawn in.
enum CodeNavigatorIcon {
    /// What the square holds.
    enum Glyph: Equatable {
        case letter(String)
        case symbol(String)
    }

    /// A function's mark.
    static let function = (glyph: Glyph.letter("f"), color: NSColor.systemPurple)

    /// A review group's mark: green for full, orange for partial, red for
    /// nothing done yet, blue for a library routine, grey where there is no
    /// level to have.
    static func group(_ group: CodeReaderState.FunctionGroup) -> (glyph: Glyph, color: NSColor) {
        switch group {
        case .full: (.symbol("checkmark"), .systemGreen)
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

    static func image(_ glyph: Glyph, color: NSColor, side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let radius = (side * 0.26).rounded()
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            switch glyph {
            case let .letter(letter):
                drawLetter(letter, in: rect)
            case let .symbol(name):
                drawSymbol(name, in: rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The letter centred by its own ink, not by the font's line: an `f`
    /// has an ascender and no descender, and would sit high in a line box.
    private static func drawLetter(_ letter: String, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let base = NSFont.systemFont(ofSize: rect.height * 0.74, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: [
            .font: font, .foregroundColor: NSColor.white
        ]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawSymbol(_ name: String, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.56, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let fit = min(1, rect.width * 0.7 / max(symbol.size.width, 1), rect.height * 0.7 / max(symbol.size.height, 1))
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
