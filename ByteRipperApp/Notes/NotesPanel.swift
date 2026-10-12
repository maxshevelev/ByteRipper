import Cocoa
import HelpUI
import Localization

/// The tab's Notes panel: every note made on the files — by an agent or by
/// the person — as cards, in a panel of the dock beside the fragment panels
/// (`AgentAnnotationTools`).
///
/// It is there while there is a note, in every tab, and goes with the last
/// one. It has no ✕: it folds into its pill — by its ⌄, by Esc, by pulling
/// its header down — and its pill counts the agent's notes made while it was
/// out of view.
// help: window.notes
@MainActor
final class NotesPanel {
    let id: FragmentDock.PanelID
    let cards = AgentAnnotationCards()
    let header = NotesHeaderView()
    let view: FragmentPanelView

    init(id: FragmentDock.PanelID) {
        self.id = id
        cards.build()
        cards.scroll.borderType = .noBorder
        view = FragmentPanelView(header: header, content: cards.scroll)
        cards.onShow = { [weak self] id in self?.show(id) }
        cards.onOpenSite = { [weak self] annotation in self?.show(annotation.id) }
        cards.onRemove = { ids in
            let chosen = Set(ids)
            AgentAnnotationTools.current?.remove { chosen.contains($0.id) }
        }
        // help: window.notes.edit
        cards.onEdit = { [weak self] annotation in
            NoteForm.ask(L("Edit Annotation"), L("The title and the note change; the place stays."),
                         button: L("Save"), title: annotation.title, note: annotation.note,
                         in: self?.view.window) { title, note in
                AgentAnnotationTools.current?.update(annotation.id, title: title, note: note)
            }
        }
        cards.isOpen = { annotation in AgentAnnotationTools.current?.place(of: annotation) != nil }
    }

    /// The notes there are now.
    func refresh(_ notes: [AgentAnnotation]) {
        cards.show(notes)
    }

    /// Goes to note `id`'s place — its file brought forward or opened; a file
    /// moved or deleted since is said so.
    private func show(_ id: String) {
        guard let store = AgentAnnotationTools.current,
              let note = store.all().first(where: { $0.id == id }) else { return }
        if store.place(of: note) == nil, let url = note.file.url,
           !FileManager.default.fileExists(atPath: url.path) {
            let alert = NSAlert()
            alert.messageText = L("The file is not there")
            alert.informativeText = L("“%1$@” has been moved or deleted since the annotation was made.", url.path)
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        store.show(id)
    }
}

/// The Notes panel's title bar: its name, the `?` and the ⌄ that folds it.
/// Pulled down, it carries the panel down into its pill as a fragment
/// panel's header does.
final class NotesHeaderView: PullDownHandleView {
    var onCollapse: () -> Void = {}

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: L("Annotations"))
    private lazy var collapseButton = HeaderButton.make(
        symbol: "chevron.down", describes: L("Collapse panel"),
        tooltip: L("Collapse into the dock"), target: self, action: #selector(collapseTapped))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSImage(systemSymbolName: NotesPillSymbol.name, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let help = HelpButton.inline(for: .topic(.notes))
        for view in [icon, title, help, collapseButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: FragmentPanelView.headerHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            help.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            help.centerYAnchor.constraint(equalTo: centerYAnchor),
            collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            collapseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: HeaderButton.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func collapseTapped() { onCollapse() }

    /// The panel's name, for tests.
    var titleForTesting: String { title.stringValue }

    /// The ⌄, for tests.
    func collapse() { onCollapse() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        PaneHeaderView.headerRuleColor().setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// The picture of the Notes panel, on its pill and in its header.
enum NotesPillSymbol {
    static let name = "note.text"
}
