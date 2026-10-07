import Foundation

/// A command a tool-module offers in the dump's own context menu, under its
/// own name: right-click a byte, **UEFI Structure ▸ Show in Tree**
/// (`ToolSession.dumpActions(at:)`).
///
/// The other direction from the panel's own buttons. A button in the panel
/// acts on where the caret is, and a reader has to know that the caret is what
/// it means; a command in the dump's menu acts on the byte that was clicked,
/// which is what the reader was already pointing at.
///
/// The host draws the menu and owns its order — the tool-module's items come
/// together under one item named after the tool-module, so it is always clear
/// whose they are and the dump's own commands never move. What an item does is
/// the tool-module's alone.
public struct ToolDumpAction {
    /// What the item says.
    public var title: String
    /// A command that cannot run here is offered greyed rather than left out,
    /// so the menu still says the tool-module could do it.
    public var isEnabled: Bool
    /// Runs when the item is chosen, on the main actor, with the menu gone.
    public var perform: @MainActor () -> Void

    public init(title: String, isEnabled: Bool = true, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.perform = perform
    }
}
