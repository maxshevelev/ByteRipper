import XCTest
@testable import HelpBook

/// The content itself, as shipped. These are the tests that make the book
/// maintainable: a page renamed, a term deleted, a link mistyped or a language
/// half-translated is a failure here rather than a dead end in the window.
final class HelpContentTests: XCTestCase {
    private var book: HelpBook { Help.shared }

    func testTheBookLoads() {
        XCTAssertFalse(book.isEmpty, "the help resources did not load from the bundle")
        XCTAssertEqual(book.language, "en")
    }

    /// Every page the contents names exists, has a title, a summary and a body.
    /// A missing file throws in the loader, so reaching this at all means the
    /// files are there; what is checked here is that they were written.
    func testEveryTopicIsWritten() {
        for id in HelpContents.allTopics {
            guard let topic = book.topic(id) else {
                return XCTFail("no page for \(id.rawValue)")
            }
            XCTAssertFalse(topic.title.isEmpty, "\(id.rawValue) has no title")
            XCTAssertNotEqual(topic.title, id.rawValue, "\(id.rawValue) has no `# ` title line")
            XCTAssertFalse(topic.summary.isEmpty, "\(id.rawValue) has no `> ` summary")
            XCTAssertFalse(topic.blocks.isEmpty, "\(id.rawValue) has no body")
        }
    }

    func testEverySectionIsNamed() {
        XCTAssertEqual(book.sections.count, HelpContents.sections.count)
        for section in book.sections {
            XCTAssertNotEqual(section.name, section.id,
                              "section \(section.id) has no name in Sections.md")
            XCTAssertFalse(section.topics.isEmpty)
        }
    }

    func testEveryTermIsWritten() {
        XCTAssertFalse(book.terms.isEmpty)
        for term in book.terms {
            XCTAssertFalse(term.name.isEmpty, "\(term.id.rawValue) has no @name")
            XCTAssertNotEqual(term.name, term.id.rawValue, "\(term.id.rawValue) has no @name")
            XCTAssertFalse(term.summary.isEmpty, "\(term.id.rawValue) has no @short")
            XCTAssertFalse(term.blocks.isEmpty, "\(term.id.rawValue) has no body")
        }
    }

    func testTermIDsAreUnique() {
        let ids = book.terms.map(\.id.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "two glossary entries share an id")
    }

    /// Every glossary is populated. A group with nothing in it is a file that
    /// failed to parse rather than a deliberate choice.
    func testEveryGlossaryHasEntriesAndAName() {
        for group in HelpTermGroup.allCases {
            XCTAssertFalse(book.terms(in: group).isEmpty, "the \(group.rawValue) glossary is empty")
            XCTAssertNotEqual(book.glossaryName(group), group.rawValue,
                              "the \(group.rawValue) glossary has no name in Sections.md")
        }
    }

    /// No link in the book leads anywhere but into the book.
    func testEveryLinkResolves() {
        for topic in book.topics {
            for link in HelpMarkup.links(in: topic.blocks) {
                XCTAssertTrue(book.destinationExists(link),
                              "\(topic.id.rawValue) links to \(link), which does not exist")
            }
        }
        for term in book.terms {
            for link in HelpMarkup.links(in: term.blocks) + term.seeAlso {
                XCTAssertTrue(book.destinationExists(link),
                              "the term \(term.id.rawValue) links to \(link), which does not exist")
            }
        }
    }

    /// Every language ships the same pages. Adding `de` without translating a
    /// page is fine — the loader falls back word by word — but a page that
    /// exists in *no* language is a page nobody can read.
    func testEveryShippedLanguageLoads() throws {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "Help", withExtension: nil))
        let languages = try FileManager.default
            .contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath)
            .map { $0.lastPathComponent }
        XCTAssertTrue(languages.contains("en"))
        for language in languages {
            let loaded = try HelpLoader.load(language: language, base: base)
            XCTAssertEqual(loaded.topics.count, HelpContents.allTopics.count,
                           "\(language) is missing pages")
        }
    }

    func testSearchFindsPagesAndTerms() {
        let hits = book.search("checksum")
        XCTAssertTrue(hits.contains { $0.link == .topic(.recipeChecksums) })
        XCTAssertTrue(hits.contains { $0.link == .term(HelpTermID("checksum")) })
        XCTAssertTrue(book.search("   ").isEmpty)
    }

    /// The whole point of a glossary on a bench: a word typed as the panel
    /// writes it finds its entry.
    func testTheAcronymsThePanelsShowAreAllExplained() {
        let expected = ["fpt", "cpd", "manifest", "mfs", "efs", "svn", "arb-svn", "vcn",
                        "utok", "huffman", "iup", "rbe-pm", "integrity-table", "anti-replay",
                        "oem-config", "bpdt", "cse-layout-table", "sku",
                        "flash-descriptor", "region", "volume", "ffs-file", "section",
                        "guid", "nvram", "vss", "fit", "microcode", "boot-guard"]
        for id in expected {
            XCTAssertNotNil(book.term(HelpTermID(id)), "no glossary entry for \(id)")
        }
    }
}
