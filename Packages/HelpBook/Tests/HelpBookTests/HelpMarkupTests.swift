import Localization
import XCTest
@testable import HelpBook

/// The markup the content is written in — the one format a translator has to
/// keep, so each of its rules is pinned here.
final class HelpMarkupTests: XCTestCase {
    func testParagraphsAreJoinedUntilABlankLine() {
        let blocks = HelpMarkup.parse("one\ntwo\n\nthree")
        XCTAssertEqual(blocks, [
            .paragraph([.text("one two")]),
            .paragraph([.text("three")])
        ])
    }

    func testHeadingBulletsStepsAndCaution() {
        let blocks = HelpMarkup.parse("""
        ## Heading

        - first
        - second

        1. step one
        2. step two

        ! careful
        """)
        XCTAssertEqual(blocks, [
            .heading("Heading"),
            .bullets([[.text("first")], [.text("second")]]),
            .steps([[.text("step one")], [.text("step two")]]),
            .caution([.text("careful")])
        ])
    }

    /// A step's own number is thrown away: the view numbers them, so a step
    /// inserted in the middle of a translated page cannot be misnumbered.
    func testStepsKeepOrderNotTheWrittenNumbers() {
        let blocks = HelpMarkup.parse("7. a\n9. b")
        XCTAssertEqual(blocks, [.steps([[.text("a")], [.text("b")]])])
    }

    func testAListEndsAtProse() {
        let blocks = HelpMarkup.parse("- item\nprose")
        XCTAssertEqual(blocks, [
            .bullets([[.text("item")]]),
            .paragraph([.text("prose")])
        ])
    }

    func testInlineForms() {
        XCTAssertEqual(HelpMarkup.spans("a **b** c `0xFF` d"), [
            .text("a "), .strong("b"), .text(" c "), .code("0xFF"), .text(" d")
        ])
    }

    func testLinksWithAndWithoutTheirOwnWords() {
        XCTAssertEqual(HelpMarkup.spans("see [[topic:hex-view]] and [[term:fpt|the table]]"), [
            .text("see "),
            .link(text: "hex-view", link: .topic(.hexView)),
            .text(" and "),
            .link(text: "the table", link: .term(HelpTermID("fpt")))
        ])
    }

    /// Brackets that are not a link stay as they were typed. A page that loses
    /// a line because of a stray `[[` is worse than one that prints it.
    func testUnrecognisedBracketsAreLeftAlone() {
        XCTAssertEqual(HelpMarkup.spans("[[nonsense]]"), [.text("[[nonsense]]")])
    }

    func testPlainTextReadsLinksAsTheirWords() {
        let blocks = HelpMarkup.parse("go to [[topic:settings|Settings]] now")
        XCTAssertEqual(HelpMarkup.plainText(blocks), "go to Settings now")
    }

    /// A link out of the book, for a page that has to name where a claim came
    /// from. It is a span of its own, not a `HelpLink`: nothing in the book can
    /// navigate to it.
    func testAWebLinkIsItsOwnSpan() throws {
        let url = try XCTUnwrap(URL(string: "https://example.org/guide"))
        XCTAssertEqual(HelpMarkup.spans("see [[web:https://example.org/guide|the guide]]"), [
            .text("see "),
            .web(text: "the guide", url: url)
        ])
    }

    /// Without its own words a source link shows the address, which is the
    /// honest fallback: the reader can still see where it goes.
    func testAWebLinkWithoutWordsShowsItsAddress() throws {
        let url = try XCTUnwrap(URL(string: "https://example.org/x"))
        XCTAssertEqual(HelpMarkup.spans("[[web:https://example.org/x]]"), [
            .web(text: "https://example.org/x", url: url)
        ])
    }

    /// Anything but https stays as written rather than becoming a link. A book
    /// of ours does not send a reader over plain http, and a link that renders
    /// but goes nowhere is worse than visible brackets.
    func testOnlyHTTPSBecomesALink() {
        XCTAssertEqual(HelpMarkup.spans("[[web:http://example.org]]"),
                       [.text("[[web:http://example.org]]")])
        XCTAssertEqual(HelpMarkup.spans("[[web:ftp://example.org]]"),
                       [.text("[[web:ftp://example.org]]")])
    }

    func testPlainTextReadsAWebLinkAsItsWords() {
        let blocks = HelpMarkup.parse("measured, see [[web:https://example.org|the guide]]")
        XCTAssertEqual(HelpMarkup.plainText(blocks), "measured, see the guide")
    }
}

/// The file formats around the markup: a page's header, a term's fields, the
/// section names.
final class HelpFileFormatTests: XCTestCase {
    func testTopicFileHeader() {
        let topic = HelpTopicFile.parse("""
        # The Title

        > The one-line summary.

        The body.
        """, id: .overview)
        XCTAssertEqual(topic.title, "The Title")
        XCTAssertEqual(topic.summary, "The one-line summary.")
        XCTAssertEqual(topic.blocks, [.paragraph([.text("The body.")])])
    }

    /// A page with no `#` line still has a title — its id — rather than a blank
    /// row in the contents.
    func testTopicWithoutATitleFallsBackToItsID() {
        XCTAssertEqual(HelpTopicFile.parse("body", id: .overview).title, "overview")
    }

    func testTermFileFields() {
        let terms = HelpTermFile.parse("""
        @term fpt
        @name Flash Partition Table
        @short One sentence.

        The body.

        @see term:cpd
        @see topic:tool-me

        @term cpd
        @name Code Partition Directory
        """, group: .me)
        XCTAssertEqual(terms.count, 2)
        XCTAssertEqual(terms[0].id, HelpTermID("fpt"))
        XCTAssertEqual(terms[0].name, "Flash Partition Table")
        XCTAssertEqual(terms[0].summary, "One sentence.")
        XCTAssertEqual(terms[0].blocks, [.paragraph([.text("The body.")])])
        XCTAssertEqual(terms[0].seeAlso, [.term(HelpTermID("cpd")), .topic(.toolME)])
        XCTAssertEqual(terms[0].group, .me)
        XCTAssertEqual(terms[1].id, HelpTermID("cpd"))
    }

    func testSectionNames() {
        let names = HelpSectionFile.parse("@section reading\n@name Reading a Dump")
        XCTAssertEqual(names["reading"], "Reading a Dump")
    }

    /// A language the book has not been written in yet falls back to English
    /// rather than throwing: the UI may be translated before the help is, and
    /// an English page beats no page.
    func testALanguageTheBookLacksFallsBackToEnglish() throws {
        let book = try HelpLoader.load(language: "ja")
        XCTAssertEqual(book.language, "en")
        XCTAssertFalse(book.isEmpty)
    }
}
