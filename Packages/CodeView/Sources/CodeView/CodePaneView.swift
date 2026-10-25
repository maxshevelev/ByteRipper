import AppKit
import CodeAnalysis
import Localization
import ToolModuleKit

/// The pane beside a module's bytes: what the stored analysis says, and for now
/// the statement that its listing is still to come
/// (`Design/CODE_PANEL_PLAN.md`).
///
/// A reader, not a tool-module: it owns the content width and its own
/// selection, and it knows nothing about the UEFI tree or the store. The
/// artifact's functions and instructions replace the placeholder; the manifest
/// already names the module and the recipe, so the pane can say what it is
/// looking at from the first day.
@MainActor public final class CodePaneView: NSView {
    public init(manifest: AnalysisManifest) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = label(L("Code analysis"), font: ToolPanelFont.title())
        let module = label(manifest.module.name.isEmpty
                            ? manifest.recipe.id
                            : manifest.module.name,
                           font: ToolPanelFont.body(weight: .medium))
        let recipe = label(manifest.recipe.id, font: ToolPanelFont.body(),
                           color: .secondaryLabelColor)
        let note = label(L("The code listing is not drawn yet."),
                         font: ToolPanelFont.body(), color: .secondaryLabelColor)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0

        let stack = NSStackView(views: [title, module, recipe, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func label(_ text: String, font: NSFont,
                       color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
