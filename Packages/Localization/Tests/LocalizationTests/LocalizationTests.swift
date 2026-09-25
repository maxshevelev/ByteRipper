import XCTest
@testable import Localization

/// Which language the app comes out speaking, given what the Mac reads and
/// what the user chose.
final class LanguageChoiceTests: XCTestCase {
    func testAFixedChoiceIgnoresTheMac() {
        XCTAssertEqual(LanguageChoice.fixed(.german).resolve(preferred: ["ru", "en"]), .german)
    }

    func testFollowingTheMacTakesItsFirstLanguageTheAppHas() {
        XCTAssertEqual(LanguageChoice.system.resolve(preferred: ["ru-RU", "en"]), .russian)
        XCTAssertEqual(LanguageChoice.system.resolve(preferred: ["fr", "de"]), .german)
    }

    /// A region says nothing about which of three translations to show.
    func testARegionMatchesThePlainLanguage() {
        XCTAssertEqual(LanguageChoice.system.resolve(preferred: ["de-AT"]), .german)
        XCTAssertEqual(LanguageChoice.system.resolve(preferred: ["ru_RU"]), .russian)
    }

    /// A Mac reading a language the app does not have gets English, not the
    /// app's guess at the nearest thing.
    func testAnUnknownLanguageFallsBackToEnglish() {
        XCTAssertEqual(LanguageChoice.system.resolve(preferred: ["ja", "ko"]), .english)
        XCTAssertEqual(LanguageChoice.system.resolve(preferred: []), .english)
    }

    func testTheChoiceSurvivesBeingWrittenDown() {
        for choice: LanguageChoice in [.system, .fixed(.english), .fixed(.russian), .fixed(.german)] {
            XCTAssertEqual(LanguageChoice(storedValue: choice.storedValue), choice)
        }
        // Anything else that turns up in the defaults is "follow the Mac",
        // which is the state a fresh install is in.
        XCTAssertEqual(LanguageChoice(storedValue: nil), .system)
        XCTAssertEqual(LanguageChoice(storedValue: "klingon"), .system)
    }

    /// A list of languages names each one in itself: a reader looking for
    /// their own language must not have to read another one to find it.
    func testEachLanguageNamesItselfInItself() {
        XCTAssertEqual(AppLanguage.russian.ownName, "Русский")
        XCTAssertEqual(AppLanguage.german.ownName, "Deutsch")
        XCTAssertEqual(AppLanguage.english.ownName, "English")
    }
}

/// The catalogue: what a word comes out as, and what happens when nobody has
/// translated it.
final class CatalogueTests: XCTestCase {
    private func withLanguage(_ choice: LanguageChoice, _ body: () -> Void) {
        let defaults = UserDefaults(suiteName: "LocalizationTests")!
        defaults.removePersistentDomain(forName: "LocalizationTests")
        let savedDefaults = Localization.defaults
        Localization.defaults = defaults
        defaults.set(choice.storedValue, forKey: Localization.choiceKey)
        Localization.reload()
        body()
        Localization.defaults = savedDefaults
        Localization.reload()
    }

    func testAKeyWithATranslationIsTranslated() {
        withLanguage(.fixed(.russian)) {
            XCTAssertEqual(L("Drop files here"), "Перетащите файлы сюда")
        }
        withLanguage(.fixed(.german)) {
            XCTAssertEqual(L("Drop files here"), "Dateien hierher ziehen")
        }
    }

    /// The whole reason the key is the English text: an untranslated string
    /// reads as correct English rather than as a key.
    func testAnUntranslatedKeyReadsAsItself() {
        withLanguage(.fixed(.russian)) {
            XCTAssertEqual(L("A sentence nobody has translated"),
                           "A sentence nobody has translated")
        }
    }

    func testEnglishIsTheKeysThemselves() {
        withLanguage(.fixed(.english)) {
            XCTAssertEqual(L("Drop files here"), "Drop files here")
            XCTAssertEqual(Localization.language, .english)
        }
    }

    /// A translation must be free to reorder what is put into it, which is
    /// what the positional placeholders are for.
    func testArgumentsCanBeReorderedByATranslation() {
        XCTAssertEqual(Localization.format("%1$@ into %2$@", ["S1", "S0"]), "S1 into S0")
        XCTAssertEqual(Localization.format("%2$@ enthält %1$@", ["S1", "S0"]), "S0 enthält S1")
    }

    /// Whatever a call site used to interpolate, it can still pass: a count, an
    /// offset, a name. Interpolation is what this replaces, so it behaves the
    /// way interpolation did.
    func testAnyArgumentIsPutInTheWayInterpolationWouldHave() {
        XCTAssertEqual(Localization.format("%1$@ bytes", [4096]), "4096 bytes")
        XCTAssertEqual(Localization.format("at %1$@", ["0x1000"]), "at 0x1000")
    }

    /// A language may need to say the same thing twice, and may need none of
    /// it at all.
    func testAPlaceholderMayRepeatOrBeLeftOut() {
        XCTAssertEqual(Localization.format("%1$@ and %1$@", ["it"]), "it and it")
        XCTAssertEqual(Localization.format("nothing here", ["unused"]), "nothing here")
    }

    /// A placeholder with no argument behind it stays visible. A translator's
    /// mistake that can be seen is one that gets fixed; a silently swallowed
    /// one is a sentence missing a word in one language only.
    func testAPlaceholderWithNoArgumentIsLeftAsWritten() {
        XCTAssertEqual(Localization.format("%1$@ then %3$@", ["a", "b"]), "a then %3$@")
    }

    func testADoubledPercentIsALiteralOne() {
        XCTAssertEqual(Localization.format("100%% of %1$@", ["it"]), "100% of it")
    }

    func testTheStringsFormatIsRead() {
        let parsed = StringsFile.parse("""
        /* a comment */
        "one" = "eins";
        "two \\"quoted\\"" = "zwei";
        """)
        XCTAssertEqual(parsed["one"], "eins")
        XCTAssertEqual(parsed["two \"quoted\""], "zwei")
    }

    /// A file that will not parse is reported as empty rather than as half a
    /// language.
    func testABrokenFileIsEmpty() {
        XCTAssertTrue(StringsFile.parse("\"one\" = ").isEmpty)
    }
}
