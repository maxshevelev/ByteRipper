import Cocoa
import ALSplitView

/// One content surface: the three-pane composite a document is looked at
/// through — the tool-module's panel on the left, the dump in the middle, the
/// minimap on the right — together with the split that shares the width
/// between them and the rules for how much each panel may take
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
///
/// The window's own content is one of these. A fragment panel, when it arrives,
/// is another: the requirement that a panel carry its own header, its own
/// minimap and its own tool panel is the requirement that it be a surface, and
/// this type is what makes there be more than one.
///
/// **Its view is the split itself.** There is no wrapper view around it, so the
/// composite can be dropped wherever a view goes — the window's content
/// container today, a sliding panel next — without a layer of nothing in
/// between.
///
/// What is here is the geometry and the pieces: what a surface can answer on
/// its own. What feeds them — which bytes the map draws, what the search
/// marked, which pane is active — is still the tab's, and still lives in
/// `MainViewController`, which installs those closures on the surface it owns.
@MainActor final class DocumentSurface: NSViewController {
    /// The tab this surface belongs to. Every surface of a tab has the same
    /// host: what differs between them is the panes they show, not who they
    /// answer to.
    private weak var host: MainViewController?

    /// The vertical split sharing the content area between the panels and the
    /// panes. The panes are the `.fill` pane and each panel a `.fixed` one, so
    /// a panel keeps the width the user chose while the panes absorb resizes;
    /// hidden just means a panel is fixed at zero width.
    let panelSplit = ALSplitView()

    /// The middle pane: whatever the mode puts on screen — the empty state, one
    /// file pane, or the comparison.
    let contentHost = NSView()

    /// The right-hand minimap (§19).
    let minimapView = MinimapView()

    /// The map plus its chrome — the header's mode switch and the status bar's
    /// rebuild progress (§19.2).
    private(set) lazy var minimapPanel = MinimapPanelView(mapView: minimapView)

    /// The tool-module panel and the session behind it
    /// (`Design/TOOL_MODULES_PLAN.md`).
    ///
    /// Its `owner` is the tab rather than this surface, which is right for the
    /// window's own surface and is what a fragment panel will have to change:
    /// the controller asks its owner for "pane 1" and "pane 2", and a fragment
    /// surface has one pane that is neither.
    private(set) var tools = ToolController()

    /// Whether the minimap panel is shown. Drives the split's divider clamp:
    /// while hidden, the clamp pins the divider to the trailing edge so the
    /// panel sits at zero width and the dump reclaims the content area (§19).
    ///
    /// Set through `MainViewController.setMinimapPanelVisible`, which owns what
    /// a change means — the maps and the viewport are stale while the panel is
    /// closed, and a show has to refresh them.
    var minimapPanelVisible = false

    // MARK: - Where each panel sits

    /// Where each panel sits in `panelSplit`, and which divider borders it.
    /// Named rather than written as 0/1/2 at a dozen call sites: the split
    /// gained a third pane once already, and every index moved with it.
    static let toolPaneIndex = 0
    static let contentPaneIndex = 1
    static let minimapPaneIndex = 2
    /// The divider at `i` is between panes `i` and `i + 1`.
    static let toolDividerIndex = 0
    static let minimapDividerIndex = 1

    // MARK: - The minimap panel's width

    /// Where the minimap panel width is persisted. Swappable so the suite does
    /// not write the user's real preference.
    static var minimapDefaults: UserDefaults = .standard
    /// `UserDefaults` key for the user's chosen minimap width (§19).
    static let minimapWidthDefaultsKey = "MinimapPanelWidth"
    /// The minimap keeps at least this width when shown (§19).
    static let minimapMinPanelWidth: CGFloat = 120
    /// The minimap never grows beyond this width (§19), so it stays a compact
    /// overview column beside the hex panes no matter how wide the window gets.
    static let minimapMaxPanelWidth: CGFloat = 240

    /// The panel width the user last chose (or the built-in minimum), clamped
    /// to the legal [min, max] band. The caller is responsible for clamping to
    /// what the split can actually hold (`setMinimapPanelWidth` already does),
    /// so this also serves zoom-to-fit, which wants the preferred width
    /// regardless of how small the window is right now.
    var minimapPreferredPanelWidth: CGFloat {
        let stored = Self.minimapDefaults.object(forKey: Self.minimapWidthDefaultsKey) as? NSNumber
        let preferred = stored.map { CGFloat($0.doubleValue) } ?? Self.minimapMinPanelWidth
        return min(max(preferred, Self.minimapMinPanelWidth), Self.minimapMaxPanelWidth)
    }

    // MARK: - Life

    /// Assembles the composite at birth rather than on the first layout: a
    /// caller that reaches for `panelSplit` before the view controller's view
    /// has been asked for should not find an empty split, and everything here
    /// is plain views with no lifecycle of their own.
    init(host: MainViewController) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        tools.owner = host
        wireToolPanel()
        assemble()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = panelSplit
    }

    private func wireToolPanel() {
        // The panel's ✕ is Tools ▸ None by another route.
        tools.panel.onClose = { [weak self] in self?.tools.activate(nil) }
        // A file dropped on the panel replaces the file the panel is reading —
        // the same thing, through the same door, as dropping it on that pane's
        // Replace Current File band.
        tools.panel.onDropFiles = { [weak self] urls in
            guard let self, let host = self.host, let pane = self.tools.boundPane else { return }
            host.openFiles(into: host.paneIndex(of: pane), urls: urls)
        }
        // A pane dropped on the panel moves the tool onto it.
        tools.panel.onDropPane = { [weak self] dragID in
            guard let self, let host = self.host,
                  let index = host.paneIndex(withDragID: dragID) else { return }
            self.tools.rebind(to: index == 0 ? host.windowModel.pane1 : host.windowModel.pane2)
        }
        // A pane chosen in the header's selector moves it, by the same door.
        tools.panel.onSelectPane = { [weak self] index in
            self?.tools.selectPane(at: index)
        }
        tools.panel.paneDropTitle = { [weak self] dragID in
            self?.tools.paneDropTitle(forPaneWith: dragID)
        }
    }

    /// The panel split: the tool-module's panel on the left
    /// (`Design/TOOL_MODULES_PLAN.md`), the mode content in the middle, the
    /// minimap panel on the right. Both side panels start collapsed — neither
    /// is shown on launch — and each is opened by its own command. The clamp
    /// owns each divider's legal range, and a divider move persists that
    /// panel's width.
    ///
    /// Both panels are in the split from the start rather than added when
    /// shown: a pane added mid-life moves every divider index under everything
    /// that holds one.
    private func assemble() {
        panelSplit.translatesAutoresizingMaskIntoConstraints = false
        panelSplit.isVertical = true
        panelSplit.dividerThickness = 1
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        minimapPanel.translatesAutoresizingMaskIntoConstraints = false
        panelSplit.addPane(tools.panel)
        panelSplit.addPane(contentHost)
        // The panel, not the bare map: its header carries the mode switch and
        // its status bar the rebuild's progress, and together they align the map
        // with the dump beside it (§19.2).
        panelSplit.addPane(minimapPanel)
        // The panes fill whatever the panel doesn't take; the panel starts
        // collapsed at zero width, so the hex panes get the whole content area
        // until the minimap is shown (§19). A show that landed before the view
        // loaded found no panes to park a policy in (`setPaneLayout` is a
        // no-op on an empty split), so the initial policy reads the visibility
        // flag and opens the panel at its width on the first layout.
        panelSplit.setPaneLayout(.fixed(0), at: Self.toolPaneIndex)
        panelSplit.setPaneLayout(.fill, at: Self.contentPaneIndex)
        panelSplit.setPaneLayout(.fixed(minimapPanelVisible ? minimapPreferredPanelWidth : 0),
                                 at: Self.minimapPaneIndex)
        // The clamp owns the divider's legal range (§19). While the panel is
        // shown, a drag never shrinks the minimap below its minimum nor grows
        // it past its maximum. While it is hidden and no show/hide animation is
        // gliding, the clamp pins the divider to the trailing edge: the panel
        // stays collapsed at zero width, and a drag on the divider cannot open
        // it (only the toolbar/menu toggle can). The animation is exempt — it
        // needs the full range to glide the divider to the edge on a hide.
        panelSplit.clampDividerPosition = { [weak self] index, position in
            guard let self else { return position }
            guard !self.panelSplit.isAnimatingDivider else { return position }
            let total = self.panelSplit.bounds.width
            let thickness = self.panelSplit.dividerThickness
            if index == Self.toolDividerIndex {
                // The tool panel's own rule, and it needs to know what the
                // minimap is taking: the dump's minimum is what the panel may
                // not eat into, and the minimap has already taken its share.
                return self.tools.clampPanelDivider(position, total: total,
                                                    dividers: thickness * 2,
                                                    minimapWidth: self.currentMinimapWidth())
            }
            guard self.minimapPanelVisible else {
                // Pinned flat against the trailing edge: a hidden panel is a
                // pane of zero width, and the position that leaves nothing
                // below this divider is not the free axis once the tool
                // panel's divider sits above it.
                return self.panelSplit.maximumDividerPosition(at: index)
            }
            // The minimap is the last pane, so its width is what is left after
            // this divider whatever precedes it — the same arithmetic as when
            // it was the only panel.
            let maxPanel = min(Self.minimapMaxPanelWidth, max(0, total - thickness))
            let minPosition = max(0, total - maxPanel - thickness)
            let maxPosition = max(0, total - Self.minimapMinPanelWidth - thickness)
            return min(max(position, minPosition), maxPosition)
        }
        // A divider move — a drag or a programmatic sizing — makes that panel's
        // new width the user's preferred width for its next show (§19,
        // Design/TOOL_MODULES_PLAN.md).
        panelSplit.onDividerMoved = { [weak self] index, position in
            guard let self else { return }
            if index == Self.toolDividerIndex {
                self.tools.persistPanelWidth(position)
            } else {
                self.persistMinimapPanelWidth(position: position)
            }
        }
    }

    // MARK: - What the surface shows

    /// Puts `newView` in the middle pane, replacing whatever was there — the
    /// empty state, one file pane, or a comparison.
    func setContent(_ newView: NSView) {
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        newView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            newView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            newView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
    }

    // MARK: - Panel widths

    /// The minimap panel's width as the split currently has it — what the tool
    /// panel's clamp has to leave alone.
    func currentMinimapWidth() -> CGFloat {
        let total = panelSplit.bounds.width
        guard total > 0 else { return 0 }
        return max(0, total - panelSplit.dividerPosition(at: Self.minimapDividerIndex)
                   - panelSplit.dividerThickness)
    }

    /// The tool panel's width as the split currently has it.
    func toolPanelWidth() -> CGFloat {
        guard panelSplit.bounds.width > 0 else { return 0 }
        return panelSplit.dividerPosition(at: Self.toolDividerIndex)
    }

    /// Moves the first divider so the tool panel gets `width` points, animating
    /// unless reduced motion or a snap. `windowResize` is the window move that
    /// belongs to this change, driven by the panel animation's own tick so the
    /// window edge and the panel edge move as one thing (§19).
    func setToolPanelWidth(_ width: CGFloat, animated: Bool,
                           windowResize: ((CGFloat) -> Void)? = nil) {
        let total = panelSplit.bounds.width
        guard total > 0 else {
            // No bounds yet: park the width in the pane's policy and let the
            // first layout place the divider from it.
            panelSplit.setPaneLayout(.fixed(max(0, width)), at: Self.toolPaneIndex)
            windowResize?(1)
            return
        }
        let target = max(0, min(width, panelSplit.axisAvailable()))
        if animated {
            panelSplit.animateLeadingPaneSize(to: target, onTick: windowResize)
        } else {
            panelSplit.setDividerPosition(target, at: Self.toolDividerIndex)
            windowResize?(1)
        }
    }

    /// Moves the divider so the minimap panel gets `width` points (clamped to
    /// the split's room and the legal band by the split's divider clamp),
    /// animating unless reduced motion or the distance is a snap.
    /// `windowResize`, when given, is the window move that belongs to this
    /// width change — the growth or shrink that keeps the hex content area's
    /// width (§19). It takes a progress in 0…1 and is driven by the panel
    /// animation's own tick, so the two never drift apart; unanimated, it is
    /// called with 1.
    func setMinimapPanelWidth(_ width: CGFloat, animated: Bool = false,
                              windowResize: ((CGFloat) -> Void)? = nil) {
        let total = panelSplit.bounds.width
        guard total > 0 else {
            // No bounds yet: park the width in the panel's policy; the first
            // layout places the divider from it. The minimap's own pane —
            // this said `at: 1` until the surface was extracted, an index left
            // over from when the split had two panes and the minimap was the
            // second, which parked the minimap's width on the CONTENT pane.
            panelSplit.setPaneLayout(.fixed(max(0, width)), at: Self.minimapPaneIndex)
            windowResize?(1)
            return
        }
        let thickness = panelSplit.dividerThickness
        let target = max(0, min(width, total - thickness))
        if animated {
            // The divider is eased by the panel's WIDTH — the position is
            // re-derived from the live bounds on every step, the way the
            // divider drag does it — which is what lets the window grow
            // underneath the animation without the panel losing its place.
            panelSplit.animateTrailingPaneSize(to: target, onTick: windowResize)
        } else {
            panelSplit.setDividerPosition(total - target - thickness, at: Self.minimapDividerIndex)
            windowResize?(1)
        }
    }

    /// Persists the panel's current width as the user's preferred width for the
    /// next show. Only while the panel is shown and within the legal range: a
    /// transient layout (e.g. mid-animation) whose panel width is absurd would
    /// poison the next reveal if persisted.
    func persistMinimapPanelWidth(position: CGFloat) {
        guard minimapPanelVisible else { return }
        let panelWidth = panelSplit.bounds.width - position - panelSplit.dividerThickness
        guard panelWidth >= Self.minimapMinPanelWidth,
              panelWidth <= Self.minimapMaxPanelWidth else { return }
        Self.minimapDefaults.set(panelWidth, forKey: Self.minimapWidthDefaultsKey)
    }
}
