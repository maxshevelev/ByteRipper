import Cocoa

/// A text field that does not select its whole text when it gains focus: the
/// caret lands after the text, so what the field offers can be added to as
/// well as replaced. AppKit's default is to select it all. Also calls
/// `onTextChange` on every edit, so a form can re-validate as the text
/// changes.
///
/// The one copy of that focus behaviour: the address field (`AddressField`)
/// and the Fill sheet's byte field both are one of these.
@MainActor
class CaretAtEndTextField: NSTextField {
    /// Called on every edit — typing, deleting, replacing.
    var onTextChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused, let editor = currentEditor() as? NSTextView {
            let length = (stringValue as NSString).length
            editor.selectedRange = NSRange(location: length, length: 0)
        }
        return focused
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?()
    }
}
