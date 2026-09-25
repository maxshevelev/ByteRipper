import AppKit
import HelpBook

/// An instrument for working on a dump: it reads the open file, shows its own
/// UI in the window's left panel, marks zones in the dump, and can write back
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// A tool-module is a *type*, never an instance: what the app keeps is the list
/// of them, and what it makes when the user picks one is a session. Everything
/// here is what the Tools menu needs to draw the item before anything has been
/// opened.
///
/// Applicability is not here on purpose. The host offers every tool-module for
/// every file; whether there is a FIT table in this image is a question only
/// the tool-module can answer and only after reading, and the answer belongs in
/// its panel as a sentence rather than in the menu as a grey item that explains
/// nothing.
public protocol ToolModule {
    /// Stable, reverse-DNS, and never shown: it keys the panel's remembered
    /// width and identifies the module in the menu's state. Renaming one
    /// forgets that width, which is the whole cost of getting it wrong.
    static var identifier: String { get }
    /// The Tools menu item.
    static var title: String { get }
    /// How wide the panel opens the first time. The user's own width, once they
    /// drag the divider, outranks it from then on.
    static var preferredPanelWidth: CGFloat { get }

    /// The page behind the `?` in the panel's header: what this instrument is
    /// for, read while it is open.
    ///
    /// On the seam rather than inside the module because the button is the
    /// *panel's* chrome — the app draws the header — and a tool-module that
    /// drew its own would be a second `?` in a different place in every panel.
    /// Nil for a tool-module with nothing written about it yet, and the header
    /// then carries no button at all rather than one that opens a blank page.
    static var helpTopic: HelpTopicID? { get }

    /// Builds the session that runs this tool-module against one open file.
    /// Called on activation; the host lives at least as long as the session.
    @MainActor static func makeSession(host: any ToolHost) -> any ToolSession
}

extension ToolModule {
    /// A tool-module that names no page is one whose header carries no `?`.
    /// Defaulted so a new instrument compiles before anything has been written
    /// about it.
    public static var helpTopic: HelpTopicID? { nil }
}
