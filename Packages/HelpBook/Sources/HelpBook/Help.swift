import Foundation
import Localization

/// The book, loaded for the language the app is speaking.
///
/// Everything that shows help — the window, a `?` button, a panel's popover —
/// reads it from here, so there is one parse per language per run. A book that
/// cannot be loaded comes back empty rather than stopping the app: help that
/// is missing is a page that says so, never a crash on a bench.
///
/// It reloads when the language changes, because the help is the one part of
/// the app that *can* change language without a relaunch — every page is built
/// from the book each time it is shown, so there is nothing already on screen
/// wearing the old words except the page itself, and the window re-renders it.
public enum Help {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var book: HelpBook?
    nonisolated(unsafe) private static var bookLanguage: AppLanguage?

    public static var shared: HelpBook {
        let wanted = Localization.resolvedLanguage()
        lock.lock()
        defer { lock.unlock() }
        if let book, bookLanguage == wanted { return book }
        let loaded = (try? HelpLoader.load(language: wanted.rawValue)) ?? .unavailable
        book = loaded
        bookLanguage = wanted
        return loaded
    }

    /// Drops the loaded book, so the next reader gets the current language.
    /// The language setting calls this; a test that moved the inputs does too.
    public static func reload() {
        lock.lock()
        book = nil
        bookLanguage = nil
        lock.unlock()
    }
}

extension HelpBook {
    /// The book with nothing in it — what a build with broken resources hands
    /// the window, which then says the help is unavailable.
    public static let unavailable = HelpBook(language: HelpLoader.fallbackLanguage,
                                             sections: [], topics: [], terms: [])
    public var isEmpty: Bool { topics.isEmpty && terms.isEmpty }
}
