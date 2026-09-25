import Foundation

/// The word for `key` in the language the app is currently speaking.
///
/// The key is the English text, so a site is localized by wrapping the literal
/// it already had:
///
///     titleLabel.stringValue = L("Drop files here")
///
/// A key with no translation yet comes back as itself, which is correct
/// English — never a blank label and never `settings.language.caption`. That
/// is the whole reason the key is the text.
public func L(_ key: String) -> String {
    Localization.current.string(key)
}

/// The word for `key` **in a particular context**, for the cases where one
/// English word is two words in another language.
///
///     L("Edit", context: "menu")     // Правка — the menu on the bar
///     L("Edit")                      // Изменить — the button in a form
///
/// English has one "Edit" and Russian has two, and the key is the English
/// text, so without this the two uses of the word fight over one entry and one
/// of them is wrong wherever it appears. The context is part of the key in the
/// catalogue — `"menu|Edit"` — and a language that does not need the
/// distinction simply does not write that entry: the lookup falls back to the
/// plain key, and then to the English text.
public func L(_ key: String, context: String) -> String {
    let catalogue = Localization.current
    return catalogue.entries[context + "|" + key] ?? catalogue.string(key)
}

/// The same, for a sentence with something in it.
///
///     L("Merge %1$@ into %2$@", piece, neighbour)
///
/// The placeholders are **positional**, and that is the whole point: a German
/// or a Russian sentence puts the subject and the object where its own grammar
/// wants them, not where English put them, and a translation that cannot
/// reorder what is poured into it is a translation that reads like a machine.
///
/// Substituted here rather than by `String(format:)`, which wants every
/// argument to be a `CVarArg` and formats an `Int` differently from a
/// `String`. What a call site passes is whatever it used to interpolate — an
/// offset, a count, a name — and interpolation is exactly what
/// `String(describing:)` does, so that is what this does. One rule, no types
/// to get right, and a migration of a few hundred sites that cannot silently
/// print `(null)`.
public func L(_ key: String, _ arguments: Any...) -> String {
    Localization.format(Localization.current.string(key), arguments)
}

/// Which language the app speaks, and the words it says in it.
///
/// One catalogue, loaded once per language, held behind a lock because the
/// words are read from wherever a string is built — the curator's tree is
/// built off the main actor, and a panel's rows on it.
public enum Localization {
    /// Posted when the language changes. The menu bar is rebuilt from it; a
    /// view that is already on screen is not, which is why the Settings tab
    /// offers to relaunch (`Design/LOCALIZATION.md`).
    public static let didChange = Notification.Name("dev.maxik.ByteRipper.languageDidChange")

    /// Where the choice is kept. The app's own defaults, under the key the
    /// Settings tab writes.
    public static let choiceKey = "AppLanguage"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalogue = Catalogue.empty
    nonisolated(unsafe) private static var loaded = false

    /// The catalogue in force, loading it on the first word asked for.
    static var current: Catalogue {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            catalogue = Catalogue.load(language: resolvedLanguage(), bundle: .module)
            loaded = true
        }
        return catalogue
    }

    /// The language the app is speaking now.
    public static var language: AppLanguage { current.language }

    /// What the user has chosen, as stored. `.system` until they choose
    /// otherwise.
    public static var choice: LanguageChoice {
        LanguageChoice(storedValue: defaults.string(forKey: choiceKey))
    }

    /// Where the choice is read from and written to. Replaceable so a test can
    /// drive the whole resolution without touching the user's own settings —
    /// the suite runs under its own domain, and this keeps even that honest.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    /// What the Mac reads, asked of the system unless a test says otherwise.
    nonisolated(unsafe) public static var preferredLanguages: [String] = Locale.preferredLanguages

    public static func resolvedLanguage() -> AppLanguage {
        choice.resolve(preferred: preferredLanguages)
    }

    /// Records the user's choice and reloads the words.
    ///
    /// Everything built after this speaks the new language; everything already
    /// on screen does not, and nothing here pretends otherwise — the change is
    /// announced and the Settings tab offers the relaunch that makes it whole.
    public static func set(_ newChoice: LanguageChoice) {
        guard newChoice != choice else { return }
        defaults.set(newChoice.storedValue, forKey: choiceKey)
        reload()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Re-reads the catalogue for whatever the choice now resolves to. Called
    /// by `set`, and by a test that changed the inputs behind it.
    public static func reload() {
        lock.lock()
        catalogue = Catalogue.load(language: resolvedLanguage(), bundle: .module)
        loaded = true
        lock.unlock()
    }

    /// Puts `arguments` into `format` at its positional placeholders.
    ///
    /// `%1$@` takes the first, `%2$@` the second, in whatever order the
    /// sentence needs them and however many times each appears — a language
    /// that has to say the file's name twice may. `%%` is a literal percent.
    /// A placeholder with no argument behind it is left as written rather than
    /// swallowed: a visible `%3$@` in a sentence is a translator's mistake
    /// that can be seen and fixed, and a silently dropped one is not.
    static func format(_ format: String, _ arguments: [Any]) -> String {
        guard !arguments.isEmpty else { return format }
        let texts = arguments.map { argument -> String in
            if let text = argument as? String { return text }
            if let convertible = argument as? CustomStringConvertible { return convertible.description }
            return String(describing: argument)
        }
        var result = ""
        var rest = Substring(format)
        while let percent = rest.firstIndex(of: "%") {
            result += rest[rest.startIndex..<percent]
            rest = rest[rest.index(after: percent)...]
            if rest.first == "%" {
                result += "%"
                rest = rest.dropFirst()
                continue
            }
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix("$@"),
                  let index = Int(digits), index >= 1, index <= texts.count
            else {
                result += "%"
                continue
            }
            result += texts[index - 1]
            rest = rest.dropFirst(digits.count + 2)
        }
        return result + rest
    }

    /// Every key the catalogue of `language` holds — what the coverage script
    /// and its tests compare against the keys the code asks for.
    public static func keys(in language: AppLanguage) -> Set<String> {
        Set(Catalogue.load(language: language, bundle: .module).entries.keys)
    }
}

/// One language's words: a flat map from the English text to the translation.
struct Catalogue: Sendable {
    let language: AppLanguage
    let entries: [String: String]

    static let empty = Catalogue(language: .fallback, entries: [:])

    /// The word for `key`, or the key itself — which is the English text, so
    /// an untranslated string reads correctly rather than reading as a key.
    func string(_ key: String) -> String {
        entries[key] ?? key
    }

    static func load(language: AppLanguage, bundle: Bundle) -> Catalogue {
        // English is the keys themselves: shipping a file that maps every
        // string to itself would be a file nobody can ever get wrong, and
        // 1200 lines of it.
        guard language != .fallback else { return Catalogue(language: language, entries: [:]) }
        guard let url = bundle.url(forResource: "Resources", withExtension: nil)?
            .appendingPathComponent("\(language.rawValue).lproj/Localizable.strings"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return Catalogue(language: language, entries: [:])
        }
        return Catalogue(language: language, entries: StringsFile.parse(text))
    }
}
