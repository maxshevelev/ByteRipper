import AppPalette
import Cocoa

/// Draws one symbol at the size the picture actually is.
///
/// `NSImageView` is the obvious thing here and the wrong one: for a configured
/// symbol it reports an `intrinsicContentSize` of its own invention — 85 x 50.5
/// for a picture that is 85 x 82 — and a layout that believes that number gives
/// the view a frame half the height of the glyph, then centres the picture in
/// it, so the symbol is drawn out of the top and the bottom of its own slot. A
/// stack is exactly such a layout, which is how a notice's sign came to sit on
/// the words below it.
///
/// This view has no opinion of its own: its intrinsic size *is* the image's, so
/// what it asks for and what it draws cannot come apart.
final class SymbolView: NSView {
    var image: NSImage? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The colour the glyph is drawn in.
    var tint: NSColor = NoticeColors.icon {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        image?.size ?? NSSize(width: NSView.noIntrinsicMetric,
                              height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        // Through a tinted copy rather than `draw(in:)` alone: a symbol image is
        // a template and draws opaque black. `.sourceIn` keeps the glyph's shape
        // and takes both the colour *and* the alpha from `tint` — `.sourceAtop`
        // would keep the glyph's own full alpha and only wash the tint over it,
        // which turns a translucent grey into black.
        let size = image.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            self.tint.set()
            rect.fill(using: .sourceIn)
            return true
        }
        // At the picture's own size, centred: a frame a constraint made larger
        // or smaller than the image moves the glyph, and never stretches it.
        tinted.draw(in: NSRect(x: bounds.midX - size.width / 2,
                               y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
}

/// A short-lived notice over the window: a rounded frosted plate with a glyph
/// and a few lines, which fades in, holds, and fades out on its own.
///
/// For an answer that is about a *whole* operation rather than about the place
/// the user is looking — "Smart search tried these five encodings and none of
/// them found anything" (§11). The pane's status bar is the wrong place for
/// that: it is a strip beside the file's own numbers, sized for one line, and
/// the report here is a list. The plate is the shape the platform already uses
/// for exactly this — Xcode's build and test results — so it needs no
/// explaining.
///
/// A square, with the glyph above the lines and the whole thing centred: one
/// shape for every plate of the kind, so a confirmation and a report are the
/// same object seen twice rather than two things that have to be learned
/// separately. The side is whatever the content asked for, so the lines are
/// never squeezed into a column narrower than they were written for.
///
/// Deliberately not interactive: it reports and leaves. `hitTest` returns nil,
/// so a click on the dump underneath goes to the dump and the notice is never
/// something to dismiss.
final class TransientNoticeView: NSVisualEffectView {
    /// How long a plate with something to read holds before it fades. A `var`
    /// so a test can shorten it instead of sleeping through it.
    static var holdDuration: TimeInterval = 4
    /// How long a plate that is only a glyph holds. Shorter, because it is
    /// taken in at a glance and there is nothing to read: a wrap says "you are
    /// back at the top", and by the time it is understood it has done its job.
    static var glyphHoldDuration: TimeInterval = 0.9
    static let fadeInDuration: TimeInterval = 0.15
    static let fadeOutDuration: TimeInterval = 0.3
    /// The glyph on a plate that has something to read: the sign over the
    /// lines. Larger than an icon beside a label would be, because it is the
    /// half of the plate the eye lands on first — it reads as a sign over the
    /// words, not as a bullet beside them.
    static let symbolPointSize: CGFloat = 72
    /// The glyph on a plate that is nothing but the glyph — big enough to read
    /// as a sign rather than as an icon beside missing text.
    static let glyphPointSize: CGFloat = 76
    /// The room between the glyph and the lines under it.
    static let glyphToTextSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 22
    /// The plate's own padding, one number for all four sides — which is what
    /// makes the shape square rather than merely boxy.
    static let inset: CGFloat = 24

    private let symbolView = SymbolView()
    private let textStack = NSStackView()
    private var dismissWorkItem: DispatchWorkItem?

    /// What the plate says, for tests.
    private(set) var lines: [String] = []

    /// The glyph it was told to wear, for tests — what a plate about a control
    /// can be checked against: the sign on the plate and the sign on the button
    /// are the same one.
    private(set) var symbolName = ""

    /// The glyph the plate actually drew, for the test that a symbol named in
    /// code is one this system has.
    var symbolImageForTests: NSImage? { symbolView.image }
    /// A plate that is one large glyph and nothing else — a sign rather than a
    /// report (§11: a search that wrapped).
    convenience init(glyph symbol: String) {
        self.init(symbol: symbol, lines: [])
    }

    init(symbol: String, lines: [String]) {
        super.init(frame: .zero)
        material = .hudWindow
        // Within the window, not behind it: the plate frosts the dump it sits
        // over, which is what makes it read as being *in* the document rather
        // than as another window.
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0

        symbolName = symbol
        // The size is asked of the *image* rather than of the view, and the
        // image's size rather than the view's word for it. A configured symbol
        // is 85 x 82 at 72 points, but an `NSImageView` reports
        // `intrinsicContentSize` (85 x 50.5) — its own idea of the glyph, not
        // the picture's — so a stack that trusts it leaves the view half as tall
        // as the symbol it is holding, and the picture is then drawn from the
        // centre of that short frame, out of the top and bottom of the box the
        // eye reads as its place. `SymbolView` answers with the picture's own
        // size, so there is no such gap between what the view says and what it
        // draws.
        let pointSize = lines.isEmpty ? Self.glyphPointSize : Self.symbolPointSize
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize,
                                                                weight: .regular))
        // Grey, for the sign and for the words alike (`SymbolView.tint` starts
        // at `NoticeColors.icon`): a plate reports something the window has
        // already done, so it says it quietly rather than in the weight of a
        // warning, and as one object rather than a sign louder than its words.

        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 2
        self.lines = lines
        for (index, line) in lines.enumerated() {
            let label = NSTextField(labelWithString: line)
            // The first line names the operation, the rest are its findings —
            // one heading, then a list.
            label.font = index == 0
                ? .systemFont(ofSize: 14, weight: .semibold)
                : .systemFont(ofSize: 13)
            label.textColor = NoticeColors.icon
            // The plate is as wide as its widest line, so the only lines that
            // could come up short are the ones on a window too narrow to hold
            // them — and those the plate stops rather than clips.
            label.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(label)
        }

        // The glyph over the lines, both centred: the shape is a sign, and a
        // sign is read from the middle out.
        //
        // The spacing is a gap and a floor at once: the stack's own spacing keeps
        // the glyph and the words apart, and the glyph keeps its own height
        // rather than being compressed into whatever is left over — the two
        // together are what stop the sign from landing on the words.
        symbolView.setContentCompressionResistancePriority(.required, for: .vertical)
        // A plate that is only a glyph holds only the glyph: an empty stack of
        // lines would still take the spacing, and push the sign off centre.
        let content = NSStackView(views: lines.isEmpty ? [symbolView] : [symbolView, textStack])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = Self.glyphToTextSpacing
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Padding equal on all four sides leaves a plate as tall as its
        // content; the square is what makes that height its width as well, so
        // the same number of points sits between the content and every edge.
        // Preferred rather than required: on a window with no room for the
        // square, the cap the presenter puts on the width has to win, and a
        // required square against a required cap is an unsatisfiable pair that
        // AppKit would resolve by breaking whichever rule it happened to reach
        // last.
        let square = heightAnchor.constraint(equalTo: widthAnchor)
        square.priority = .defaultHigh - 1
        // Leading, trailing, centre: the stack spans the plate's content box and
        // is placed, not stretched. The trailing pin is what makes the plate as
        // wide as its widest line — the widest line sets the stack's width, and
        // the plate follows it by `inset` on each side. The centre is the whole
        // of the vertical placement: the square already makes the plate taller
        // than the words it holds, and pinning top and bottom as well would ask
        // those words to stretch into the difference. A centre is a position, so
        // the stack keeps its own height and the spare room falls evenly above
        // and below it.
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor,
                                             constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -Self.inset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            square,
        ])
        setAccessibilityRole(.staticText)
        // A glyph-only plate still has to say something to a reader who cannot
        // see it, and what it says is the thing it stands for.
        setAccessibilityLabel(lines.isEmpty ? symbol : lines.joined(separator: " "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A click here belongs to whatever is underneath: the notice is a report,
    /// not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fades in, holds, and fades out — then removes itself, so nothing owns
    /// it but the window it was shown in.
    func present(holdingFor hold: TimeInterval? = nil) {
        let duration = hold ?? (lines.isEmpty ? Self.glyphHoldDuration : Self.holdDuration)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced {
            alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
        }
        let dismiss = DispatchWorkItem { [weak self] in self?.dismiss(animated: !reduced) }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    func dismiss(animated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard animated else {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
        }
    }
}

/// Shows transient notices in a view, one at a time (§11).
///
/// The one place that decides where a plate of this kind goes, how it arrives
/// and leaves, and that a new one replaces the last rather than piling onto
/// it. Every such report — a Smart Search that found nothing, a search that
/// came round the end of the file — is shown through here, so they cannot
/// drift apart into two conventions.
@MainActor
final class TransientNoticePresenter {
    /// Where a plate's middle sits, as a fraction of the host's height **up
    /// from the bottom**: the lower third.
    ///
    /// Out of the way of the bytes being read, which are at the top of the
    /// window where the caret was left, and of the find bar above them — and
    /// still inside the window rather than at its edge, so it reads as the
    /// app's own answer and not as a system alert.
    static let verticalFraction: CGFloat = 1.0 / 3
    /// How much of the host's width a plate may take. A square plate is as
    /// tall as it is wide, so this is a bound on both.
    static let horizontalInset: CGFloat = 40

    private weak var host: NSView?
    /// The plate on screen, if any. Internal so tests can read what it says.
    private(set) var current: TransientNoticeView?

    init(host: NSView) {
        self.host = host
    }

    /// A plate with something to read: a glyph and a few lines.
    func show(symbol: String, lines: [String]) {
        show(TransientNoticeView(symbol: symbol, lines: lines))
    }

    /// A plate that is one large glyph and nothing else — a sign rather than a
    /// report.
    func show(glyph symbol: String) {
        show(TransientNoticeView(glyph: symbol))
    }

    /// Takes the notice off screen now.
    ///
    /// `animated` is false where a plate is being *replaced* — a cross-fade
    /// between two answers reads as a glitch — and true where the answer has
    /// simply gone stale, which is a fade the eye follows. Either way the
    /// presenter forgets it at once, so "is a notice showing?" is answered by
    /// the intent rather than by the fade.
    func dismiss(animated: Bool = true) {
        current?.dismiss(animated: animated)
        current = nil
    }

    private func show(_ notice: TransientNoticeView) {
        guard let host else { return }
        dismiss(animated: false)
        host.addSubview(notice)
        // Everything here is a constant against the host's *centre* — never a
        // relation to one of its edges. That is the whole reason the plate
        // cannot resize the window it is drawn in: the host's top and bottom
        // are the anchors the window's content column is chained to, so a plate
        // constrained to one of them is answered by the window growing taller.
        // Written the first time as an edge constraint, it turned a 180-point
        // window into a 310-point one. A centre, by contrast, is a position and
        // not a demand.
        //
        // The plate is not flipped, so a third of the way *up* the window is a
        // small y. Solved from the host's height rather than written as a
        // multiplier: the multiplier form measures from the *top*, and the
        // fraction is of the height above the bottom, so the two only agree by
        // way of a subtraction the API cannot express.
        let centreY = host.bounds.height * (1 - Self.verticalFraction)
        // The plate sits on that line while it fits there, and is pushed down
        // to sit inside the window when it does not — a short window gets a
        // plate lower than the lower third rather than one hanging off the
        // bottom edge. `lessThanOrEqualTo` *is* that rule: the plate's centre
        // may be at or above the line, so a plate whose top would leave the
        // window is moved down until it does not.
        let placement = NSLayoutConstraint(
            item: notice, attribute: .centerY, relatedBy: .lessThanOrEqual,
            toItem: host, attribute: .centerY, multiplier: 1,
            constant: centreY - host.bounds.midY)
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            placement,
            // What bounds the plate on a small window. The width cap is enough
            // on its own: the square, being preferred, gives way before this
            // does, so a window too narrow for the square gets a shorter plate
            // rather than a wider one.
            notice.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor,
                                          constant: -Self.horizontalInset),
        ])
        current = notice
        notice.present()
    }
}
