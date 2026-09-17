import Cocoa

/// Where a fragment panel sits in the area it covers
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// Pure, so the one rule the geometry has — how much of the file underneath
/// stays showing — is pinned without a window.
enum FragmentPanelLayout {
    /// How much of the panes behind is left showing above the panel.
    ///
    /// A pane header's height and a little over: enough for the name of the
    /// file the part came out of to stay readable while you work on the part.
    /// That is the whole reason the panel does not simply cover everything —
    /// a panel you cannot see the parent behind is a tab with a shadow.
    static let parentPeek: CGFloat = FilePaneView.headerHeight + 16

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
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: body.topAnchor),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
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
