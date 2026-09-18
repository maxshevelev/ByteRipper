import Cocoa

/// Where a fragment panel sits in the area it covers
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// Pure, so the one rule the geometry has — how much of the file underneath
/// stays showing — is pinned without a window.
enum FragmentPanelLayout {
    /// How much of the panes behind is left showing above the panel.
    ///
    /// Half a pane header: the panel's top edge cuts the header of the file the
    /// part came out of in half. Enough of it shows to say what is behind and
    /// which file it is, and the overlap is what says the panel is laid *over*
    /// that file rather than docked beside it. A panel you cannot see the
    /// parent behind is a tab with a shadow; one that clears the header
    /// entirely reads as a second pane.
    static let parentPeek: CGFloat = FilePaneView.headerHeight / 2

    /// The panel never folds itself smaller than this by being in a short
    /// window: below it there is no room for a header, a row of bytes and a
    /// status bar, and showing the parent matters less than showing the part.
    static let minimumPanelHeight: CGFloat = 160

    /// The panel's height in an area `hostHeight` tall.
    ///
    /// The peek is what gives way when the window is short: full peek while the
    /// panel can still be useful, then as much peek as is left over, then none
    /// at all in an area smaller than the minimum — where the panel takes what
    /// there is rather than hanging off the bottom.
    static func panelHeight(hostHeight: CGFloat) -> CGFloat {
        guard hostHeight > 0 else { return 0 }
        let wanted = hostHeight - parentPeek
        guard wanted < minimumPanelHeight else { return wanted }
        return min(hostHeight, minimumPanelHeight)
    }
}

/// What letting go of a pulled-down panel means
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// Pure, so the feel of it can be tuned and pinned without a mouse. The rule is
/// the one every sheet uses: a deliberate flick puts it away whatever distance
/// it covered, and a slow drag has to have gone far enough to count.
enum PullDown {
    /// How far the hand has to move for it to count as a movement with a
    /// direction, in points.
    ///
    /// Two: a hand holding something still trembles by a point, and every
    /// deliberate nudge clears this at once. It is a distance rather than a
    /// speed on purpose — a nudge up and then a pause before letting go is
    /// still a nudge up, and reading a speed at the moment of release would
    /// answer "stopped" and forget which way the hand had gone.
    static var movementThreshold: CGFloat = 2

    /// How much of the panel's own height a pull that never moved anywhere has
    /// to have covered to count as putting it away. The fallback for a gesture
    /// with no direction at all, which the drag threshold makes nearly
    /// impossible — it is here so the rule is total.
    static var dismissFraction: CGFloat = 0.35

    /// Which way the hand last went.
    enum Direction: Equatable {
        case down
        case up
        /// It never moved far enough to say.
        case none

        /// The direction of a movement of `offset` points, negative being down,
        /// or `nil` when it is too small to be one.
        static func of(offset: CGFloat) -> Direction? {
            guard abs(offset) >= movementThreshold else { return nil }
            return offset < 0 ? .down : .up
        }
    }

    /// How much of an upward pull the panel actually takes. It is already at
    /// the top, so this is resistance, not travel — enough to answer the hand
    /// without pretending there is somewhere to go.
    static var upwardResistance: CGFloat = 0.25
    /// And it never rises more than this, however hard it is pulled.
    static var upwardLimit: CGFloat = 40

    enum Outcome: Equatable {
        /// Back where it was, as if nothing had happened.
        case springBack
        /// Down into its pill.
        case collapse
    }

    /// What letting go means: `direction` is the way the hand last went,
    /// `travelled` how far down the panel was pulled from its resting place,
    /// `height` the panel's own height.
    ///
    /// **The last movement decides, and nothing else does.** Nudged down, the
    /// panel carries on down; nudged up, it goes back up — from anywhere,
    /// whatever distance the pull had covered, and however long the hand rested
    /// before letting go. The panel finishing the movement the hand made is
    /// what makes the gesture feel like one movement rather than a vote.
    ///
    /// Distance answers only for a pull with no direction at all.
    static func outcome(travelled: CGFloat, height: CGFloat, direction: Direction) -> Outcome {
        switch direction {
        case .down: return .collapse
        case .up: return .springBack
        case .none: return travelled >= height * dismissFraction ? .collapse : .springBack
        }
    }

    /// Where the panel sits while the pointer has moved `offset` from where it
    /// was grabbed (negative is down), given its resting top.
    ///
    /// Downward it follows the hand exactly. Upward it gives a quarter and
    /// stops, because there is nothing above to reveal.
    static func position(restingY: CGFloat, offset: CGFloat) -> CGFloat {
        guard offset > 0 else { return restingY + offset }
        return restingY + min(offset * upwardResistance, upwardLimit)
    }
}

/// The area a fragment panel slides in over: exactly the part of the window the
/// panes occupy, so the panel never covers the New Tab strip above it nor the
/// dock below it.
///
/// It clips, which an `NSView` does not do by itself — without it the panel
/// would be drawn across the dock on its way up and down.
final class FragmentPanelHost: NSView {
    /// Called after every layout pass, so whoever owns the panels can re-place
    /// them: the panels are positioned by frame arithmetic rather than by
    /// constraints, because they are animated by their frames.
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Transparent to the pointer while it is holding nothing. The host lies
    /// over the panes whenever a panel is up, and an empty one that still
    /// swallowed clicks would make the dump unreachable the moment a panel had
    /// been opened and folded again.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !subviews.isEmpty else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// An arrow over everything it covers.
    ///
    /// Cursor rectangles are geometry, not hit testing: the split behind a
    /// panel goes on offering its resize cursor over a divider nobody can
    /// reach, which is the panes saying they are live when they are not. The
    /// panel's own views are subviews of this one, so their cursors still win
    /// over this one where they overlap.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !subviews.isEmpty else { return }
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// One fragment panel: the chrome around a `DocumentSurface`, and the thing
/// that is actually animated (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// It carries no header of its own. The header with the part's name and the
/// link back to the parent is the pane's own, inside the surface — the
/// requirement that the panel look like an ordinary hex panel is met by it
/// being one.
final class FragmentPanelView: NSView {
    static let cornerRadius: CGFloat = 10

    /// How far the shadow reaches onto the panes above.
    static let shadowRadius: CGFloat = 14

    /// The rounded, clipped body. Separate from the panel itself because one
    /// layer cannot both clip its content to a corner radius and cast a shadow
    /// outside its own bounds.
    private let body = NSView()

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        // Cast upward, onto the file the part came out of. In a view that is
        // not flipped a positive offset is towards the top of the screen.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = Self.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: 3)

        body.wantsLayer = true
        body.layer?.masksToBounds = true
        body.layer?.cornerRadius = Self.cornerRadius
        // Only the top corners: the bottom edge meets the dock, and a rounded
        // corner there would show the panes through a notch that means nothing.
        body.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        body.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(body)
        // The panel is placed by frame arithmetic — it is what the slide
        // animates — and so is everything in it, down to the surface's split.
        // Constraints from a frame-positioned panel into a view controller's
        // own view do not resolve: the surface's split stayed at zero while the
        // body around it took the panel's size, which is a whole panel of
        // nothing.
        content.translatesAutoresizingMaskIntoConstraints = true
        body.addSubview(content)
    }

    override func layout() {
        super.layout()
        body.frame = bounds
        // The surface's split is the body's one subview, and it fills it.
        for held in body.subviews { held.frame = body.bounds }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The panel fills its host but for the peek left at the top, and sits on
    /// the host's bottom edge — which is the dock's top edge.
    static func restingFrame(in host: NSView) -> NSRect {
        let height = FragmentPanelLayout.panelHeight(hostHeight: host.bounds.height)
        return NSRect(x: 0, y: 0, width: host.bounds.width, height: height)
    }

    /// Where the panel waits before it rises and where it goes when it folds:
    /// the same frame, moved down by its own height, which puts it under the
    /// dock and out of the clipped area.
    static func foldedFrame(in host: NSView) -> NSRect {
        var frame = restingFrame(in: host)
        frame.origin.y = -frame.height
        return frame
    }

    /// The colours are resolved into the layer, so a theme change has to put
    /// them in again.
    override func updateLayer() {
        super.updateLayer()
        body.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            body.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
