import Cocoa
import Localization

/// The tab's part in the notes: the count on its toolbar's Annotations
/// button, and the note the person adds from the dump's right-click menu.
extension MainViewController {
    /// The notes changed somewhere, or were looked at: the count of the
    /// agent's notes nobody has looked at follows.
    func notesChanged() {
        (view.window?.windowController as? MainWindowController)?.syncNotesBadge()
    }

    /// The toolbar's Annotations button, Window ▸ Annotations: the
    /// Annotations window, as a tab beside this one when it is closed.
    @objc func showNotesWindow(_ sender: Any?) {
        NotesWindowController.instance.show(tabbedWith: view.window)
    }

    /// Offset menu ▸ Add Annotation…: asks for a title and a note and puts them on
    /// the pane's selection.
    // help: menu.offset.note
    @objc func addNoteToSelection(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? PaneViewModel else { return }
        let selection = pane.hexSelection()
        guard !selection.isEmpty else { return }
        let range = selection.start..<selection.end
        NoteForm.ask(L("Add Annotation"),
                     L("The annotation is drawn over the selected bytes and listed in the Annotations window."),
                     button: L("Add"), in: view.window) { title, note in
            Task { @MainActor in
                _ = try? await AgentAnnotationTools.current?.addNote(title: title, note: note, on: range, of: pane)
            }
        }
    }
}

/// What Add Annotation… asks for: a title, and a note under it.
final class NoteForm: NSView {
    let titleField = NSTextField()
    let noteView = NSTextView()

    /// Asks for a title and a note — `title` and `note` filled in already
    /// when an annotation is edited — and hands them to `done` unless the
    /// person cancels or leaves the title empty.
    static func ask(_ message: String, _ information: String, button: String, title: String = "", note: String = "",
                    in window: NSWindow?, done: @escaping (String, String) -> Void) {
        let form = NoteForm()
        form.titleField.stringValue = title
        form.noteView.string = note
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.accessoryView = form
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = form.titleField
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let (title, note) = form.values
            guard !title.isEmpty else { return }
            done(title, note)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        titleField.placeholderString = L("Title")
        titleField.frame = NSRect(x: 0, y: 116, width: 320, height: 22)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 108))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        noteView.frame = scroll.contentView.bounds
        noteView.autoresizingMask = [.width]
        noteView.isRichText = false
        noteView.font = .systemFont(ofSize: NSFont.systemFontSize)
        noteView.setAccessibilityLabel(L("Note"))
        scroll.documentView = noteView
        addSubview(titleField)
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The title and the note, trimmed and cut to what a note holds.
    var values: (title: String, note: String) {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = noteView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(title.prefix(AgentAnnotationTools.maxTitle)), String(note.prefix(AgentAnnotationTools.maxNote)))
    }
}
