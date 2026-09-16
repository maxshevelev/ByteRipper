import Cocoa

/// The pane status bar's main readout — the one field the whole line is drawn
/// in — with the caret's offset and the file size as the parts of it the pointer
/// acts on: putting the pointer on the size turns it into the exact count, a
/// right-click on the offset copies the address as the bar draws it, and a
/// right-click on the size copies the half that was clicked, in that half's own
/// format.
///
/// The bar is a single label because its parts share one truncation: a narrower
/// pane shortens the line from the tail, and the size goes with it. So a part's
/// own rectangle is recovered from character positions in the joined string
/// rather than from a view of its own, and the measurement is exact because the
/// bar's font is monospaced.
///
/// Internal, not private, so a test can read the regions and drive the seams
/// that a blocking menu loop would otherwise close.
final class StatusLabel: NSTextField {
    /// What the bar joins its parts with — and what the size's position is
    /// measured through. The label owns it because the label is what joins
    /// them.
    static let separator = "  ·  "

    /// How far the size's hit region reaches past its own text, on each side.
    ///
    /// A borderless field insets the text it draws by about 2.5 points, and
    /// nothing public reports that inset: `titleRect(forBounds:)` and
    /// `drawingRect(forBounds:)` both answer with the whole bounds (measured by
    /// rendering a highlighted range and scanning the pixels). Rather than
    /// predict the cell's drawing geometry, the region is padded enough to
    /// cover it — the separator either side of the size is five characters of
    /// space around a centred dot, some 34 points, so four points of overlap
    /// land on nothing.
    static let hitSlack: CGFloat = 4

    /// Which half of the exact form a pointer is on. The two are what a size
    /// can be put on a clipboard as: the hex address, or the decimal count.
    enum SizeForm {
        case hex
        case decimal
    }

    /// The caret's offset as the bar draws it (§3.4): the part of the line
    /// holding it, and the address's own text — the digits alone, without the
    /// word beside them, which is what a right-click on them copies.
    ///
    /// The digits are the bar's own, zero-padded to the width of the file's
    /// largest address, rather than a second formatting of the same number: the
    /// clipboard gets what the user read off the screen.
    struct Offset {
        let index: Int
        let digits: String
    }

    /// The hex half of the exact form — the address a size is written as, the
    /// way the bar writes every other number.
    static func hexSizeText(_ bytes: UInt64) -> String {
        String(format: "0x%llX", bytes)
    }

    /// The exact size, in the form the Details view writes one: the hex address
    /// and the decimal count in brackets beside it — "0x200000 (2097152
    /// bytes)". 64-bit formats on purpose: `%d` would truncate a file over
    /// 2 GB to its low half.
    static func exactSizeText(_ bytes: UInt64) -> String {
        "\(hexSizeText(bytes)) (\(bytes) bytes)"
    }

    /// What a right-click on one half of the exact form puts on the clipboard:
    /// that half on its own — the hex address **without** its `0x` prefix, or
    /// the decimal count without the word beside it.
    ///
    /// Bare hex on purpose, like the offset's own menu (§3.4) and the dump's
    /// "Copy offset" (§10.2), even though the readout it is copied from carries
    /// the prefix: the prefix belongs to the field the value is pasted into,
    /// and every offset field in the app takes it on the way in — so a copied
    /// `0x200000` would be pasted as `0x0x200000` or rejected outright.
    static func copyText(_ bytes: UInt64, as form: SizeForm) -> String {
        form == .hex ? String(format: "%llX", bytes) : String(bytes)
    }

    /// The room the bar gives the readout, asked for rather than handed over.
    ///
    /// The answer is the bar's own frames, and those are only final once the
    /// bar has laid its stack out — a width passed in would be a layout pass
    /// out of date by the time the readout needed it, which is a readout that
    /// can never offer the exact form. So the bar leaves a way to ask, and the
    /// readout asks when it is drawing (§3.4). Nil, or zero, for a readout with
    /// no bar of its own: it falls back to its own width.
    var roomProvider: (() -> CGFloat)?

    /// What the readout may occupy: the width the bar offers, or its own.
    private var room: CGFloat { max(roomProvider?() ?? 0, bounds.width) }

    /// Where the parts the pointer acts on sit in the line: the size as the bar
    /// draws it abbreviated, as it is drawn exact (the same left edge, and
    /// longer), where the hex half of the exact form ends, and where the
    /// caret's offset is drawn.
    private struct Geometry {
        let abbreviated: Range<CGFloat>
        let exact: Range<CGFloat>
        let exactHexEnd: CGFloat
        /// The address's digits — the tail of their part, which is where the
        /// pane draws them — or nil when the bar has no offset on it, or has
        /// had to cut one short.
        let address: Range<CGFloat>?
    }

    /// Builds the right-click menu for a size, given the form that was clicked
    /// on. Set by MainViewController, so the item puts it on the pasteboard
    /// through the controller's own clipboard code and resolves THIS pane.
    var sizeMenuProvider: ((UInt64, SizeForm) -> NSMenu)?

    /// Builds the right-click menu for the caret's offset, given the address as
    /// the bar draws it — which is what the item copies. Set by
    /// MainViewController, for the same reason as `sizeMenuProvider`.
    var offsetMenuProvider: ((String) -> NSMenu)?

    /// The size the bar is showing, and the line it is showing it in, kept so
    /// the geometry can be re-derived when the label's width changes.
    private var size: UInt64 = 0
    private var parts: [String] = []
    private var sizeIndex = 0
    private var offset: Offset?
    private var geometry: Geometry?
    /// The transient message while one is up (§11) — not this readout's line,
    /// and drawn in place of it until the next `show(parts:sizeIndex:fileSize:)`.
    private var message: String?
    /// Whether the bar is showing the exact form, which it does while the
    /// pointer is on the size.
    private(set) var isExpanded = false
    private var hoverArea: NSTrackingArea?

    /// Where the pointer can act on the size — the size as it is being drawn,
    /// at the label's own height — or nil when the size is not on screen. The
    /// height is not stored with the range because it is the label's, and the
    /// label has none until it has been laid out.
    var sizeRegion: NSRect? {
        guard let range = isExpanded ? geometry?.exact : geometry?.abbreviated else { return nil }
        return NSRect(x: range.lowerBound, y: 0,
                      width: range.upperBound - range.lowerBound, height: bounds.height)
    }

    /// Where the pointer can act on the caret's offset — the address digits as
    /// the bar draws them, at the label's own height — or nil when the bar is
    /// showing no offset, or has had to cut one short.
    var offsetRegion: NSRect? {
        guard let range = geometry?.address else { return nil }
        return NSRect(x: range.lowerBound, y: 0,
                      width: range.upperBound - range.lowerBound, height: bounds.height)
    }

    /// Fills the bar with `parts` — already formatted, joined with `separator`
    /// — recording that `parts[sizeIndex]` is the file size, whose value is
    /// `fileSize`, and which part of the line holds the caret's offset, if the
    /// bar is showing one at all.
    func show(parts: [String], sizeIndex: Int, fileSize: UInt64, offset: Offset? = nil) {
        self.parts = parts
        self.sizeIndex = sizeIndex
        size = fileSize
        self.offset = offset
        message = nil
        render()
    }

    /// Replaces the line with a transient message and leaves the pointer
    /// nothing to act on: while the message is up the size is not on screen,
    /// and a hover where it was would expand text that is not there (§11).
    func showTransient(_ message: String) {
        self.message = message
        isExpanded = false
        geometry = nil
        render()
    }

    /// The label's width is what decides where the line truncates, and its text
    /// is only drawn once the frame is real — so the geometry is resolved as
    /// the label is laid out as well as on every new line.
    override func layout() {
        super.layout()
        render()
    }

    /// Draws the line, with the exact form in place of the abbreviation while
    /// the pointer is on it, and re-derives where the size now is.
    private func render() {
        // A transient message is drawn instead of the line, not over it: the
        // parts still held here are the ones it replaced, and recomposing them
        // — which every layout pass would do — would take the message off
        // screen before its own timer does.
        if let message {
            stringValue = message
            refreshHoverArea()
            return
        }
        resolveGeometry()
        // A bar that has narrowed under an expanded size takes the exact form
        // with it: the readout shows what it can show whole, and nothing else.
        if isExpanded, !canExpand { isExpanded = false }
        var rendered = parts
        if isExpanded, rendered.indices.contains(sizeIndex) {
            rendered[sizeIndex] = Self.exactSizeText(size)
        }
        stringValue = rendered.joined(separator: Self.separator)
        refreshHoverArea()
    }

    /// Where each part of the line is drawn, in the label's own coordinates.
    ///
    /// The line truncates at its tail, so a part the label had to cut short is
    /// not on screen: it has no rectangle, and nothing on it to act on. That
    /// also settles the size as a whole — the size is measured before it can be
    /// hovered, and a size that is half drawn cannot be pointed at.
    private func resolveGeometry() {
        guard bounds.width > 0 else {
            geometry = nil
            return
        }
        let font = textFont
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        // A part's extent: the parts before it, each with their own separator,
        // then the one separator between the last of them and it.
        func part(_ index: Int) -> Range<CGFloat>? {
            guard parts.indices.contains(index) else { return nil }
            let prefix = parts[..<index].joined(separator: Self.separator)
            let lead = prefix.isEmpty ? 0 : width(prefix) + width(Self.separator)
            let end = lead + width(parts[index])
            guard end <= bounds.width else { return nil }
            return lead..<end
        }
        // The address is the tail of its part — the pane draws "Offset 0002E6",
        // digits last — so it is the part's end, less its own width.
        let address = offset
            .flatMap { offset in part(offset.index).map { $0.upperBound - width(offset.digits)..<$0.upperBound } }
            .map { max(0, $0.lowerBound - Self.hitSlack)..<($0.upperBound + Self.hitSlack) }
        guard let size = part(sizeIndex) else {
            geometry = nil
            return
        }
        let start = max(0, size.lowerBound - Self.hitSlack)
        geometry = Geometry(
            abbreviated: start..<(size.upperBound + Self.hitSlack),
            exact: start..<(size.lowerBound + width(Self.exactSizeText(self.size)) + Self.hitSlack),
            exactHexEnd: size.lowerBound + width(Self.hexSizeText(self.size)),
            address: address)
    }

    /// Whether the exact form fits in the room the bar offers. An expansion
    /// that would itself be cut off says less than the abbreviation it
    /// replaced — and it would chase its own tail: expanding, truncating,
    /// collapsing, expanding.
    private var canExpand: Bool {
        guard let geometry else { return false }
        return geometry.exact.upperBound - Self.hitSlack <= room
    }

    /// The area the pointer has to be in for the bar to answer at all: the size
    /// in both of its forms, clamped to the label.
    ///
    /// One area for both forms on purpose. The area must not change on the very
    /// gesture that changes the text, or AppKit would fire an exit and an enter
    /// for a pointer that never moved — and a pointer arriving from the right
    /// (the mode indicator is right beside the size) has to be able to walk
    /// leftwards onto the size and be noticed, which is what `mouseMoved` is
    /// there for.
    private var hoverRect: NSRect? {
        guard let geometry else { return nil }
        let end = min(max(geometry.abbreviated.upperBound, geometry.exact.upperBound), bounds.width)
        guard end > geometry.abbreviated.lowerBound else { return nil }
        return NSRect(x: geometry.abbreviated.lowerBound, y: 0,
                      width: end - geometry.abbreviated.lowerBound, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverArea()
    }

    /// `updateTrackingAreas` is AppKit's to call, so the work lives here: both
    /// it and every change of the line come through this.
    private func refreshHoverArea() {
        let rect = hoverRect ?? .zero
        guard rect != hoverArea?.rect else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard !rect.isEmpty else { return }
        let area = NSTrackingArea(rect: rect,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsAt(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        pointerIsAt(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { pointerIsAt(nil) }

    /// Puts the pointer on `point` — the label's own coordinates, as the
    /// tracking area reports them — or takes it away with nil. A test drives
    /// this instead of an event: an event's location is in window coordinates,
    /// and standing up a window to spell one would put AppKit's delivery on
    /// trial rather than the readout.
    func pointerIsAt(_ point: NSPoint?) {
        guard let point else {
            setExpanded(false)
            return
        }
        setExpanded(sizeRegion?.contains(point) ?? false)
    }

    private func setExpanded(_ expanded: Bool) {
        // Not offered where the exact form does not fit, so the two states can
        // never disagree about whether the size is on screen.
        let next = expanded && canExpand
        guard next != isExpanded else { return }
        isExpanded = next
        render()
    }

    /// The parts the pointer acts on are the label's whole mouse surface.
    /// Outside them the label does not take the event at all, so the rest of
    /// the bar behaves as it did before this readout was interactive: the click
    /// lands on the pane and focuses the dump (§3.3).
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hit testing walks down, so `point` is in the superview's coordinates
        // while the regions are the label's own.
        let point = convert(point, from: superview)
        guard sizeRegion?.contains(point) == true || offsetRegion?.contains(point) == true
        else { return nil }
        return super.hitTest(point)
    }

    /// A plain click on the size is a click on the bar like any other: it goes
    /// up the responder chain to the pane, which focuses the dump. The label
    /// takes the click only so that a right-click can mean something here.
    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    /// Right-click on one of the parts the pointer acts on: copy it in the form
    /// it was clicked in. The menus are built by the controller, which owns the
    /// pasteboard path.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let menu = offsetMenu(at: point) ?? sizeMenu(at: point) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The size's menu for a point in the label's coordinates, or nil when the
    /// point is not on the size. Split out of `rightMouseDown` because
    /// `popUpContextMenu` runs a blocking tracking loop no test can enter — the
    /// seam the hex dump's offset menu has for the same reason (§10.2).
    ///
    /// The pointer being on the size is what draws the exact form, so the two
    /// halves the right-click chooses between are the ones on screen: the hex
    /// address up to where it ends, and the decimal count after it.
    func sizeMenu(at point: NSPoint) -> NSMenu? {
        guard let region = sizeRegion, region.contains(point),
              let geometry else { return nil }
        return sizeMenuProvider?(size, point.x < geometry.exactHexEnd ? .hex : .decimal)
    }

    /// The offset's menu for a point in the label's coordinates, or nil when the
    /// point is not on the address. Split out of `rightMouseDown` for the same
    /// reason as `sizeMenu(at:)`.
    ///
    /// The address is copied as the bar draws it, so the item is titled with the
    /// value that will land on the clipboard rather than with the offset read
    /// again at click time, which the bar may have changed under the open menu
    /// (§3.4).
    func offsetMenu(at point: NSPoint) -> NSMenu? {
        guard let region = offsetRegion, region.contains(point), let offset else { return nil }
        return offsetMenuProvider?(offset.digits)
    }

    /// The font the text is measured in: the label's own, and the bar's
    /// monospaced 11-point as the fallback for a label laid out before its font
    /// was set.
    private var textFont: NSFont {
        font ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}

/// The status bar's OVR/INS indicator (§7.6) and the control that flips the
/// mode it names: the mode is read from this corner many times a session, and
/// sending the user to the menu bar to change the thing the readout is already
/// pointing at is the wrong shape for it.
final class TypingModeLabel: NSTextField {
    /// Flips this pane's typing mode. Set by the pane, which is what knows
    /// which pane the label belongs to.
    var onToggle: (() -> Void)?

    /// The click is consumed here rather than passed on: the pane's own handler
    /// focuses the dump, which is what makes the clicked pane active (§3.3).
    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    /// A pointer hand over the indicator: it is a control, and it should not
    /// have to be discovered by trying it.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
