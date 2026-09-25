import Foundation

/// A language the app ships, or the decision to follow the Mac.
///
/// Four cases and no `Locale`: what the app has is a small closed set of
/// translations, and a language it has not been translated into is not a
/// choice a user can usefully make. The raw value is the directory and the
/// `.lproj` the words are read from, so a language and its files cannot drift
/// apart.
public enum AppLanguage: String, CaseIterable, Sendable, Equatable {
    case english = "en"
    case russian = "ru"
    case german = "de"

    /// What the language is called **in itself** — a list of languages that
    /// names them in the language the reader is currently *not* reading is a
    /// list they have to translate before they can use it.
    public var ownName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        case .german: return "Deutsch"
        }
    }

    /// The language everything falls back to, word by word: every key exists
    /// in it, because the key *is* the English text.
    public static let fallback = AppLanguage.english
}

/// What the user chose in Settings: a language, or the Mac's own.
///
/// `.system` is a choice, not the absence of one — it means "follow the Mac",
/// and it keeps following it when the Mac's language changes. A bench that
/// sets its Mac to German and its tools to English is a real arrangement, and
/// so is the reverse, which is why the override exists at all.
public enum LanguageChoice: Equatable, Sendable {
    case system
    case fixed(AppLanguage)

    /// How the choice is stored. `"system"` rather than an empty string, so
    /// what is written down reads as the decision it is.
    public var storedValue: String {
        switch self {
        case .system: return "system"
        case .fixed(let language): return language.rawValue
        }
    }

    public init(storedValue: String?) {
        guard let storedValue, storedValue != "system",
              let language = AppLanguage(rawValue: storedValue)
        else {
            self = .system
            return
        }
        self = .fixed(language)
    }

    /// The language this choice comes out as, given what the Mac reads.
    ///
    /// The Mac's list is asked in order, and a regional name matches the plain
    /// language behind it: `de-AT` is German, because the region says nothing
    /// about which of three translations to show. A Mac set to a language the
    /// app does not have falls back to English rather than to its own first
    /// choice.
    public func resolve(preferred languages: [String]) -> AppLanguage {
        switch self {
        case .fixed(let language):
            return language
        case .system:
            for wanted in languages {
                if let exact = AppLanguage(rawValue: wanted) { return exact }
                let plain = String(wanted.prefix(while: { $0 != "-" && $0 != "_" }))
                if let language = AppLanguage(rawValue: plain) { return language }
            }
            return .fallback
        }
    }
}
