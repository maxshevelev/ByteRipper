import AppKit
import HelpBook

/// The one door to the help, for the app and for every tool-module.
///
/// A shared object rather than something passed along a seam: help is not a
/// document's business, it belongs to no pane, and threading a help router
/// through `ToolHost` would make every tool-module's contract carry a service
/// that has nothing to do with reading a dump. What a panel needs is exactly
/// `HelpPresenter.show(.term(...))`.
///
/// The window is built the first time it is asked for and kept: closing it
/// keeps the reader's place.
@MainActor public enum HelpPresenter {
    private static var controller: HelpWindowController?

    /// The window, made if this is the first time.
    public static var window: HelpWindowController {
        if let controller { return controller }
        let made = HelpWindowController()
        controller = made
        return made
    }

    /// Opens the help at `link`.
    public static func show(_ link: HelpLink) {
        window.reveal(link)
    }

    public static func show(topic: HelpTopicID) { show(.topic(topic)) }
    public static func show(term: HelpTermID) { show(.term(term)) }

    /// The book everything reads. Settable so a test can present a book of its
    /// own without touching the resources.
    public static var book: HelpBook { Help.shared }

    /// Whether the book knows this term — what a panel asks before it offers a
    /// `?` for a row.
    public static func hasTerm(_ id: HelpTermID) -> Bool { book.term(id) != nil }

    /// Throws the window away. For tests, which must not leave a window on the
    /// screen for the next class.
    public static func reset() {
        controller?.close()
        controller = nil
    }
}
