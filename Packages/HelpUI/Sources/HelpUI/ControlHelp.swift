import AppKit

/// The one way a control says what it does.
///
/// A button can explain itself in two places — its tooltip and its
/// accessibility label — and they answer the same question: *what does this
/// do?* Set separately they drift, and they had: of the controls in this app,
/// twenty said it in both places, thirty-nine had only a tooltip, and
/// thirty-four only an accessibility label (measured). A sighted user and a
/// VoiceOver user were reading two different apps, and the toolbar's Prev/Next
/// Difference buttons had no tooltip at all while every button beside them did.
///
/// So there is one phrase per control and one call that puts it everywhere it
/// belongs. Every button, segmented control, popup and toolbar item goes
/// through this — that is the rule, and `Design/LOCALIZATION.md` carries it
/// beside the rule that the phrase is translated like any other word.
///
/// **Not for labels.** A label's text is already what a screen reader reads,
/// and giving it a label as well makes it say the sentence twice. A label with
/// a tooltip sets `toolTip` directly; that is the one exception and it is
/// deliberate.
@MainActor public enum ControlHelp {
    /// Gives `control` the phrase it explains itself with.
    ///
    /// The phrase is a *sentence about the action*, not the control's name:
    /// "Go to an offset or a bookmark", not "Go To". Where the control also
    /// carries a visible title, that title stays what it is — this is the
    /// longer answer, for a reader who hovered or who cannot see the icon.
    ///
    /// `nil` takes the phrase away, in both places at once: a control with
    /// nothing to say now must not keep a stale sentence in one of them.
    public static func describe(_ control: NSView, _ phrase: String?) {
        control.toolTip = phrase
        control.setAccessibilityLabel(phrase)
    }

    /// For the few controls whose *name* and whose *explanation* are not the
    /// same sentence.
    ///
    /// A toggle is the case: a screen reader should say what the control is
    /// ("Case Sensitive") and then its state, while the tooltip has room to
    /// say what each state does ("Case Sensitive — matching exactly"). Reading
    /// the whole sentence as the control's name is worse for a VoiceOver user,
    /// not better, which is why this overload exists rather than one phrase
    /// being forced on everything.
    ///
    /// It is still the one door: a control gets both of its words here, and
    /// never one of them in one place and one in another.
    public static func describe(_ control: NSView, name: String, tooltip: String?) {
        control.toolTip = tooltip
        control.setAccessibilityLabel(name)
    }

    /// The same for a toolbar item, which is not a view.
    ///
    /// A toolbar item keeps its own short `label` — the word under the icon,
    /// which the toolbar lays out and which has room for two or three
    /// syllables — and takes the phrase as its tooltip.
    public static func describe(_ item: NSToolbarItem, _ phrase: String?) {
        describe(item, name: item.label, tooltip: phrase)
    }

    /// A toolbar item's *name* is the word under its icon and its *tooltip* is
    /// the sentence: they are almost never the same, so this is the form the
    /// toolbar actually uses.
    ///
    /// AppKit builds the button for an item that has no view of its own, and
    /// names it from `label`; for one that hosts a control, the control is
    /// what a screen reader lands on and it is named here. Either way the name
    /// stays the short word — "Prev Diff", not "Go to the previous difference
    /// between the files", which is what a reader would otherwise have to
    /// listen to before every press.
    public static func describe(_ item: NSToolbarItem, name: String, tooltip: String?) {
        item.toolTip = tooltip
        if let view = item.view { describe(view, name: name, tooltip: tooltip) }
    }
}
