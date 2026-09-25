import Cocoa
import Localization

/// How wide a Settings tab has to be.
///
/// Every tab pinned itself to 480 pt — a number measured against the English
/// toolbar labels. The labels are translated, and a translated label is
/// routinely half again as wide as its original: "Text Decoding" against
/// «Декодирование текста», "Layout" against «Расположение файловых панелей».
/// At 480 pt the Russian and German toolbars could not lay eight buttons out,
/// so AppKit did what it does and folded the last of them into the overflow
/// chevron — the tabs were still reachable, but not visible, and which ones
/// disappeared depended on the language.
///
/// So the floor is measured rather than written down: the tabs are as wide as
/// the widest thing in the window needs, whatever language it is in.
@MainActor enum SettingsMetrics {
    /// What the layout was designed to; still the floor in English.
    static let baseWidth: CGFloat = 480

    /// What a preference-style toolbar item takes beside its label.
    ///
    /// Measured, not guessed: AppKit lays each item out at the label's width
    /// plus 8 pt for the label view and 4 pt for the item around it. At 11 pt
    /// "Appearance" is 62.95 pt of text and the item comes out 75 pt wide.
    private static let itemPadding: CGFloat = 12

    /// No item is narrower than its 32 pt icon and that icon's own padding,
    /// however short the word under it.
    private static let minimumItemWidth: CGFloat = 44

    /// What the toolbar keeps at each end. The items are centred, and below
    /// 16 pt a side AppKit starts folding the last of them into the overflow
    /// chevron: with the English labels, eight items appear at 590 pt and
    /// seven at 580.
    private static let edgeInset: CGFloat = 18

    /// The width the toolbar needs for `labels`, all of them shown as buttons.
    static func toolbarWidth(for labels: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let total = labels.reduce(CGFloat.zero) { running, label in
            let text = (label as NSString).size(withAttributes: [.font: font]).width
            return running + max(minimumItemWidth, (text + itemPadding).rounded(.up))
        }
        return total + 2 * edgeInset
    }

    /// The width a tab's content should take: its own preferred width, or the
    /// toolbar's need, whichever is larger.
    static func width(preferring preferred: CGFloat = baseWidth) -> CGFloat {
        max(preferred, toolbarWidth(for: SettingsWindowController.toolbarLabels))
    }

    /// One tab's width constraint, and what it was made for.
    ///
    /// The view is held weakly and the constraint is asked nothing about it:
    /// `NSLayoutConstraint.firstItem` is `unowned(unsafe)`, so reading it
    /// after the view has gone is a dangling pointer, not a nil — which is a
    /// crash rather than an empty slot. The weak view is how a dead entry is
    /// recognised.
    private final class Pin {
        weak var view: NSView?
        let constraint: NSLayoutConstraint
        let preferred: CGFloat

        init(view: NSView, constraint: NSLayoutConstraint, preferred: CGFloat) {
            self.view = view
            self.constraint = constraint
            self.preferred = preferred
        }
    }

    private static var pinned: [Pin] = []

    /// A width constraint for a tab's root view that this type keeps up to
    /// date. Activate it with the tab's other constraints.
    static func pinnedWidth(of view: NSView,
                            preferring preferred: CGFloat = baseWidth) -> NSLayoutConstraint {
        let constraint = view.widthAnchor.constraint(equalToConstant: width(preferring: preferred))
        pinned.append(Pin(view: view, constraint: constraint, preferred: preferred))
        return constraint
    }

    /// Measures again and moves every pinned tab to the new width.
    ///
    /// The width depends on two things that can change under a running app:
    /// the translated labels, and `NSFont.smallSystemFontSize`, which follows
    /// the system's UI font. Measuring once at construction would pin the
    /// window to whatever was true when the tab was first built.
    static func refresh() {
        pinned.removeAll { $0.view == nil }
        for pin in pinned {
            let width = width(preferring: pin.preferred)
            if pin.constraint.constant != width { pin.constraint.constant = width }
        }
    }
}
