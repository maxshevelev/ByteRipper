import Cocoa

/// Where a fragment panel sits in the area it covers
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// Pure, so the one rule the geometry has — how much of the file underneath
/// stays showing — is pinned without a window.
enum FragmentPanelLayout {
    /// How much of the pane header behind the panel the panel covers.
    ///
    /// A fifth. The overlap is what says the panel is laid *over* the file
    /// rather than docked beside it — a panel that cleared the header entirely
    /// would read as a second pane — and a fifth is enough to say so while
    /// leaving the header itself readable.
    static let headerCoveredShare: CGFloat = 0.2

    /// How much of the panes behind is left showing above the panel: the rest
    /// of that header.
    static var parentPeek: CGFloat { FilePaneView.headerHeight * (1 - headerCoveredShare) }

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

    /// How far down the pull has to have gone before the panel is treated as
    /// being on its way out rather than merely lifted for a look.
    ///
    /// Half. Down to there a release puts the panel back whatever the hand was
    /// doing — a tug to see what is underneath is a tug to see what is
    /// underneath, and it should cost nothing. Past it the panel is somewhere
    /// nobody drags it to by accident, and the last movement is taken as an
    /// instruction.
    static var commitFraction: CGFloat = 0.5

    /// The speed, in points a second, at which a movement reads as a flick
    /// rather than a drag — what lets a decisive swipe from the top put the
    /// panel away without dragging it all the way down.
    ///
    /// Nine hundred is about seven points a frame: not something a hand
    /// positioning a panel produces, and not something a shove fails to.
    static var flickSpeed: CGFloat = 900

    /// And a flick has to be a real shove, not a fast tremble: the movement
    /// that carries the speed must itself be this long, in points. Two points
    /// crossed in two milliseconds is arithmetic, not a gesture.
    static var flickDistance: CGFloat = 8

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

    /// What the last movement of a pull was: which way it went, how far, and
    /// how fast — measured over that movement itself rather than over a window
    /// of time, so a nudge followed by a pause is still a nudge.
    struct Movement: Equatable {
        var direction: Direction = .none
        var distance: CGFloat = 0
        var speed: CGFloat = 0

        /// Whether it was a flick rather than a hand placing the panel.
        var isFlick: Bool { distance >= flickDistance && speed >= flickSpeed }
    }

    /// What letting go means, given how far down the panel was pulled and what
    /// the hand last did.
    ///
    /// Two halves, because a pull means two different things depending where it
    /// ends up. **Near the top it is a look**: the panel goes back, whatever the
    /// hand was doing, unless the hand flicked it away — a decisive swipe is
    /// still a way to put the panel down without carrying it there. **Past the
    /// commit line the last movement is an instruction**: nudged up it springs
    /// back from anywhere, nudged down it carries on down, however long the
    /// hand rested before letting go.
    static func outcome(travelled: CGFloat, height: CGFloat, movement: Movement) -> Outcome {
        guard travelled >= height * commitFraction else {
            // A look behind costs nothing; only a flick down ends it.
            return movement.direction == .down && movement.isFlick ? .collapse : .springBack
        }
        return movement.direction == .up ? .springBack : .collapse
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

/// Where a panel lands when it folds into its pill, and where it grows from
/// when it comes back (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// Pure, because this is arithmetic that looks right and is not: a layer-backed
/// `NSView` anchors its layer at **(0, 0)**, not at the centre the way UIKit
/// does, so a translation worked out between centres sends the panel a long way
/// past the dock — left of the window and below it — while looking perfectly
/// reasonable in the source.
enum PanelLanding {
    /// What the layer's `transform` must be for a panel of `frame` to come down
    /// exactly on `target`. The scale is about the anchor point, which Core
    /// Animation applies for us; what is left to work out is where that anchor
    /// has to end up.
    static func transform(from frame: NSRect, on target: NSRect,
                          anchor: CGPoint) -> CGAffineTransform {
        let sx = frame.width > 0 ? target.width / frame.width : 1
        let sy = frame.height > 0 ? target.height / frame.height : 1
        let from = NSPoint(x: frame.minX + frame.width * anchor.x,
                           y: frame.minY + frame.height * anchor.y)
        let to = NSPoint(x: target.minX + target.width * anchor.x,
                         y: target.minY + target.height * anchor.y)
        return CGAffineTransform(translationX: to.x - from.x, y: to.y - from.y)
            .scaledBy(x: sx, y: sy)
    }

    /// Where a panel of `frame` actually ends up with `transform` on its layer
    /// — the arithmetic Core Animation does, written out so the landing can be
    /// checked without watching it.
    static func landed(_ frame: NSRect, with transform: CGAffineTransform,
                       anchor: CGPoint) -> NSRect {
        let ax = frame.minX + frame.width * anchor.x
        let ay = frame.minY + frame.height * anchor.y
        return NSRect(x: ax + (frame.minX - ax) * transform.a + transform.tx,
                      y: ay + (frame.minY - ay) * transform.d + transform.ty,
                      width: frame.width * transform.a,
                      height: frame.height * transform.d)
    }
}

/// The area a fragment panel slides in over: exactly the part of the window the
/// panes occupy, so the panel never covers the New Tab strip above it nor the
/// dock below it.
///
/// It clips, which an `NSView` does not do by itself — without it the panel
/// would be drawn across the dock on its way up and down.
///
/// **And while it holds a panel it is a wall.** Nothing the mouse does over the
/// area a panel covers may reach the panes behind it, and nothing is allowed to
/// reach them by travelling *past* it either: a click, a right-click, a scroll
/// or a gesture that the panel's own views do not want stops here rather than
/// climbing the responder chain to something that is still listening. The panes
/// look reachable — a strip of the file behind shows above the panel on purpose
/// — and looking reachable is exactly why the wall has to be explicit rather
/// than a consequence of who happens to be in front.
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
        guard isHoldingAPanel else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    // MARK: - The wall

    /// Whether a panel is over the panes. With none there the host is not in
    /// the way of anything, and every rule below stands down.
    private var isHoldingAPanel: Bool { !subviews.isEmpty }

    /// Takes the first click in an inactive window rather than letting it fall
    /// through: a window brought forward by clicking where a pane used to be
    /// must not act on that pane.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isHoldingAPanel }

    /// No menu of its own, and none from anything it covers.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    // Every way a mouse can speak, answered with silence. A view that does not
    // implement these passes them to the next responder, which is how an event
    // over a covered pane finds something behind that still wants it.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func pressureChange(with event: NSEvent) {}

    /// An arrow over everything it covers.
    ///
    /// Cursor rectangles are geometry, not hit testing: the split behind a
    /// panel goes on offering its resize cursor over a divider nobody can
    /// reach, which is the panes saying they are live when they are not. The
    /// panel's own views are subviews of this one, so their cursors still win
    /// over this one where they overlap.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard isHoldingAPanel else { return }
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
