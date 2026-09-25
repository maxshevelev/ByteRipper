import Foundation

/// The book, loaded once for the process.
///
/// Everything that shows help — the window, a `?` button, a panel's popover —
/// reads it from here, so there is one parse and one language per run. A book
/// that cannot be loaded comes back empty rather than stopping the app: help
/// that is missing is a page that says so, never a crash on a bench.
public enum Help {
    public static let shared: HelpBook = (try? HelpLoader.load()) ?? .unavailable
}

extension HelpBook {
    /// The book with nothing in it — what a build with broken resources hands
    /// the window, which then says the help is unavailable.
    public static let unavailable = HelpBook(language: HelpLoader.fallbackLanguage,
                                             sections: [], topics: [], terms: [])
    public var isEmpty: Bool { topics.isEmpty && terms.isEmpty }
}
