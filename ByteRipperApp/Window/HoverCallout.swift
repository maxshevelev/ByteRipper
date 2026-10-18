import Cocoa

/// A small floating capsule — a glyph and a few words on the system tooltip's
/// grey, with a shadow — that names the thing under the pointer the moment the
/// pointer reaches it and goes the moment it leaves: Xcode's callout, not the
/// system tooltip.
///
/// The system tooltip is the wrong instrument for marks the pointer sweeps
/// across. It waits a second or more before it appears, the delay cannot be
/// changed (`NSToolTipManager` is private), and on a map where a dozen marks sit
/// within a few hundred points "point at each in turn" is exactly the gesture —
/// a delay per mark makes it unusable (§19.4.3, §20.3).
///
/// The glyph says what kind of thing is being named, in the shape and colour
/// that thing is drawn in: a bookmark's purple pentagon, a segment's swatch, the
/// two pieces a cut separates, a zone's bracket, a note's dashed frame. So the
/// callout is a legend — what the eye sees on the map is what the callout
/// shows beside the words.
///
/// An overlay in the window rather than a window of its own: added on top of the
/// content view, so there is no window ordering, no focus and no screen edge to
/// look after. The cost is that it cannot leave the window, which it never needs
/// to — it opens toward the middle of the view it describes.
///
/// The owner shows and hides it; the callout knows nothing about what it names.
/// The one rule it keeps by itself is that a window which stops being key takes
/// its callout away: the pointer's events stop arriving then, so nothing else
/// would ever say that the callout is now out of date.
///
/// Deliberately not interactive: `hitTest` returns nil, so a click under the
/// capsule reaches the view it is drawn over.
final class HoverCallout: NSView {
    /// What the callout is naming, which decides its glyph. The colours are the
    /// ones the thing itself is drawn with; the glyph makes them louder where
    /// they are washes, so they still read on the grey.
    enum Mark: Equatable {
        /// A bookmark (§20.4): the Offset column's purple pentagon.
        case bookmark
        /// A piece of the segment partition (§21.3), in its tint.
        case segment(NSColor)
        /// A cut (§21.2): the piece before it above the line, the one after it
        /// below — the boundary between two colours that it is.
        case cut(above: NSColor, below: NSColor)
        /// A tool-module's zone (§19.4.5), in its bracket's colour.
        case zone(NSColor)
        /// A note on the bytes (`AgentAnnotation`), in its author's hue.
        case annotation(NSColor)
    }

    static let font = NSFont.systemFont(ofSize: 13)
    /// The longest a line may run before it wraps: a note can be a paragraph.
    static let maximumTextWidth: CGFloat = 360
    /// The room between the capsule's ends and what it holds.
    static let horizontalPadding: CGFloat = 10
    /// The room above and below the lines.
    static let verticalPadding: CGFloat = 5
    /// The glyph's own column, and the room between it and the words.
    static let glyphWidth: CGFloat = 13
    static let glyphGap: CGFloat = 5
    /// How far the capsule stands off the thing it names.
    static let gap: CGFloat = 4
    /// The room around the capsule that the shadow is drawn into: the view is
    /// this much larger than the capsule on every side.
    static let shadowMargin: CGFloat = 6
    /// The rounding of the capsule's ends — half a single line's height, so
    /// one line reads as a pill and several as a rounded plate.
    static let maximumCornerRadius: CGFloat = 13

    /// Laid over the material to lift it: the tooltip's own grey is darker
    /// than a capsule that sits over a dump's white wants to be.
    static let wash = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 1, alpha: 0.45)
    }

    /// The capsule's edge: firmer than a separator, so the capsule holds its
    /// shape over bytes of any colour.
    static let rim = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.28)
            : NSColor(white: 0, alpha: 0.28)
    }

    /// What the capsule says; "" while it is not showing.
    private(set) var text = ""
    /// The glyph it wears; nil while it is not showing.
    private(set) var mark: Mark?

    /// Whether the capsule is on screen.
    var isShowing: Bool { superview != nil }

    /// The capsule itself, in its host's coordinates — the view's frame without
    /// the shadow's margin. For tests.
    var capsuleFrame: NSRect { frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    /// The tooltip's own grey: the system material, so the capsule is the
    /// platform's tooltip in everything but its timing, in either theme.
    private let material = NSVisualEffectView()
    private let content = CalloutContentView()
    private weak var observedWindow: NSWindow?
    private var resignKeyObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        material.material = .toolTip
        material.blendingMode = .withinWindow
        material.state = .active
        addSubview(material)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The text is what the pointer is over, and it says nothing a screen
    /// reader does not already get from the view it is drawn over.
    override func isAccessibilityElement() -> Bool { false }

    /// Shows `text`, with the glyph for `mark`, beside `anchor` — a rect in
    /// `view`'s coordinates — on the side of it facing the middle of `view`, so
    /// a mark in a left margin opens its callout to the right and one in a right
    /// margin to the left. A capsule that does not fit on that side opens on the
    /// other one, and either way it is kept inside the window. An empty text
    /// hides it.
    func show(_ text: String, mark: Mark?, near anchor: NSRect, of view: NSView) {
        guard !text.isEmpty, let window = view.window, let host = window.contentView else {
            hide()
            return
        }
        let anchorInHost = host.convert(anchor, from: view)
        let textSize = Self.textSize(text)
        let leading = mark == nil ? 0 : Self.glyphWidth + Self.glyphGap
        let size = NSSize(
            width: min(leading + textSize.width + 2 * Self.horizontalPadding, host.bounds.width),
            height: textSize.height + 2 * Self.verticalPadding)
        let capsule = Self.capsuleFrame(size: size, beside: anchorInHost,
                                        opensRight: anchor.midX <= view.bounds.midX,
                                        within: host.bounds)
        let frame = host.backingAlignedRect(capsule, options: .alignAllEdgesNearest)
            .insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin)
        // On top of whatever the window has gained since the last showing: a
        // view added later would otherwise draw over the capsule.
        if superview !== host || host.subviews.last !== self {
            removeFromSuperview()
            host.addSubview(self)
        }
        if text != self.text || mark != self.mark || frame != self.frame {
            self.text = text
            self.mark = mark
            self.frame = frame
            layOut()
        }
        observeKey(of: window)
    }

    /// Takes the capsule off screen. Cheap when it is not showing, so an owner
    /// can call it on every event after which a callout would be lying.
    func hide() {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
        observedWindow = nil
        guard isShowing else { return }
        removeFromSuperview()
        text = ""
        mark = nil
    }

    /// Where a capsule of `size` goes beside `anchor`: level with the anchor's
    /// middle, `gap` off the side `opensRight` names — or off the other side
    /// when that one runs out of `bounds` — and moved back inside `bounds` when
    /// it still does not fit.
    static func capsuleFrame(size: NSSize, beside anchor: NSRect, opensRight: Bool,
                             within bounds: NSRect) -> NSRect {
        let right = anchor.maxX + gap
        let left = anchor.minX - gap - size.width
        var x: CGFloat
        if opensRight {
            x = right + size.width <= bounds.maxX ? right : left
        } else {
            x = left >= bounds.minX ? left : right
        }
        x = max(bounds.minX, min(x, bounds.maxX - size.width))
        let y = max(bounds.minY, min(anchor.midY - size.height / 2, bounds.maxY - size.height))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The words' size, wrapped at `maximumTextWidth` and rounded up to whole
    /// points.
    static func textSize(_ text: String) -> NSSize {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attributes)
        return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private func layOut() {
        let capsule = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        let radius = min(capsule.height / 2, Self.maximumCornerRadius)
        material.frame = capsule
        material.maskImage = Self.maskImage(size: capsule.size, radius: radius)
        content.frame = capsule
        content.text = text
        content.mark = mark
        content.radius = radius
        content.needsDisplay = true
        layer?.shadowPath = CGPath(roundedRect: capsule, cornerWidth: radius, cornerHeight: radius,
                                   transform: nil)
    }

    private static func maskImage(size: NSSize, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    private func observeKey(of window: NSWindow) {
        guard observedWindow !== window else { return }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        observedWindow = window
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
}

/// What sits on the material: the wash, the rim, the glyph and the words.
private final class CalloutContentView: NSView {
    var text = ""
    var mark: HoverCallout.Mark?
    var radius: CGFloat = 0

    /// Flipped so the lines are laid out from the capsule's top, the way text is.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        HoverCallout.wash.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: radius - 0.5, yRadius: radius - 0.5)
        rim.lineWidth = 1
        HoverCallout.rim.setStroke()
        rim.stroke()

        var textX = HoverCallout.horizontalPadding
        if let mark {
            // Level with the first line, whatever follows it.
            let lineHeight = NSLayoutManager().defaultLineHeight(for: HoverCallout.font)
            let box = NSRect(x: textX, y: HoverCallout.verticalPadding,
                             width: HoverCallout.glyphWidth, height: lineHeight)
            drawGlyph(mark, in: box)
            textX = box.maxX + HoverCallout.glyphGap
        }
        (text as NSString).draw(
            with: NSRect(x: textX, y: HoverCallout.verticalPadding,
                         width: bounds.maxX - HoverCallout.horizontalPadding - textX,
                         height: bounds.height - 2 * HoverCallout.verticalPadding),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: HoverCallout.attributes)
    }

    /// The tints are washes made to sit under bytes; on the grey they need the
    /// louder shade the minimap's strip hovers with (§19.4.4).
    private func loud(_ color: NSColor) -> NSColor {
        HexTheme.saturatedHighlight(of: color, in: effectiveAppearance)
    }

    private func drawGlyph(_ mark: HoverCallout.Mark, in box: NSRect) {
        let (midX, midY) = (box.midX.rounded(), box.midY.rounded())
        switch mark {
        case .bookmark:
            // The Offset column's mark in small: a body with a blunt point.
            let body = NSRect(x: midX - 6, y: midY - 4.5, width: 8, height: 9)
            HexTheme.bookmarkColor.setFill()
            HexView.bookmarkMarkPath(body: body, tipReach: 4, radius: 1.5).fill()
        case .segment(let tint):
            let swatch = NSRect(x: midX - 4.5, y: midY - 4.5, width: 9, height: 9)
            loud(tint).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 1.5, yRadius: 1.5).fill()
            let edge = NSBezierPath(roundedRect: swatch.insetBy(dx: 0.25, dy: 0.25), xRadius: 1.5, yRadius: 1.5)
            edge.lineWidth = 0.5
            NSColor.separatorColor.setStroke()
            edge.stroke()
        case .cut(let above, let below):
            loud(above).setFill()
            NSBezierPath(roundedRect: NSRect(x: midX - 4.5, y: midY - 5, width: 9, height: 4),
                         xRadius: 1, yRadius: 1).fill()
            loud(below).setFill()
            NSBezierPath(roundedRect: NSRect(x: midX - 4.5, y: midY + 1, width: 9, height: 4),
                         xRadius: 1, yRadius: 1).fill()
            NSColor.labelColor.setFill()
            NSRect(x: midX - 5.5, y: midY - 0.75, width: 11, height: 1.5).fill()
        case .zone(let color):
            let bracket = NSBezierPath()
            bracket.move(to: NSPoint(x: midX + 2.5, y: midY - 5))
            bracket.line(to: NSPoint(x: midX - 2, y: midY - 5))
            bracket.line(to: NSPoint(x: midX - 2, y: midY + 5))
            bracket.line(to: NSPoint(x: midX + 2.5, y: midY + 5))
            bracket.lineWidth = 1.6
            color.setStroke()
            bracket.stroke()
        case .annotation(let color):
            // The note's own look in the dump: a light wash in a dashed frame.
            let frame = NSRect(x: midX - 5, y: midY - 4, width: 10, height: 8)
            let path = NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2)
            color.withAlphaComponent(0.25).setFill()
            path.fill()
            let dash: [CGFloat] = [2, 1.5]
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.lineWidth = 1.2
            color.setStroke()
            path.stroke()
        }
    }
}
