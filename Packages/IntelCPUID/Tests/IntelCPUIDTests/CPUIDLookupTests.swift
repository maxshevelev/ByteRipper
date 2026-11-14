import XCTest
@testable import IntelCPUID

/// The window's search finds what the repository's lookup page finds.
final class CPUIDLookupTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    private static let lookup: CPUIDLookup = {
        let names = try! Data(contentsOf: fixtures.appendingPathComponent("IntelCPUIDBrandNames.json"))
        let signatures = try! Data(contentsOf: fixtures.appendingPathComponent("IntelMicrocodeSignatures.json"))
        return CPUIDLookup(tables: try! ProcessorTables.decode(brandNames: names, signatures: signatures))
    }()
    private var lookup: CPUIDLookup { Self.lookup }

    /// Case, spaces and punctuation are ignored, and every word must match.
    func testAModelIsFoundAsTypedAnyWay() {
        let rows = lookup.rows(matching: "i5 8300h")
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.name.contains("i5-8300H") })
        XCTAssertEqual(lookup.rows(matching: "I5-8300H").map(\.name), rows.map(\.name))
        XCTAssertTrue(lookup.rows(matching: "i5-8300H nosuchword").isEmpty)
    }

    /// An S-SPEC finds its model, under its CPUID.
    func testAnSSpecFindsItsModel() throws {
        let row = try XCTUnwrap(lookup.rows(matching: "SR3Z0").first)
        XCTAssertEqual(row.cpuids, ["906EA"])
        XCTAssertTrue(row.sSpecs.contains("SR3Z0"))
        XCTAssertFalse(row.name.hasPrefix("Intel "), "the word every name starts with is left off")
    }

    /// A CPUID with an X in the table is found by any CPUID it stands for.
    func testACPUIDPatternIsFoundByAnyOfItsCPUIDs() {
        XCTAssertTrue(lookup.rows(matching: "606A6").contains { $0.cpuids == ["606AX"] })
        XCTAssertFalse(lookup.rows(matching: "606AG").contains { $0.cpuids == ["606AX"] })
    }

    /// A query that is one CPUID heads the table with its entry, and the
    /// updates it shares; a CPUID only an update names still has a heading.
    func testACPUIDQueryIsHeadedByItsEntry() throws {
        let heading = try XCTUnwrap(lookup.headings(for: " b06f5 ").first)
        XCTAssertEqual(heading.family?.codeNames, ["Raptor Lake"])
        XCTAssertTrue(heading.shared.contains { $0.update.revision == "3E" && $0.others.contains("90672") })
        XCTAssertTrue(lookup.headings(for: "B06F").isEmpty, "part of a CPUID is a search, not a heading")
        XCTAssertTrue(lookup.headings(for: "B06F5 i3").isEmpty)

        let named = Set(lookup.tables.families.flatMap(\.cpuids))
        if let lone = lookup.tables.microcode.cpuids.sorted().first(where: { cpuid in
            !named.contains(cpuid) && !lookup.tables.families.contains { $0.matches(cpuid) }
        }) {
            let only = try XCTUnwrap(lookup.headings(for: lone).first)
            XCTAssertNil(only.family)
            XCTAssertEqual(only.cpuids, [lone])
        }
    }

    /// Completions that start with the query come first, CPUIDs before
    /// S-SPECs before models; what is the query already is not offered.
    func testCompletionsAreRanked() {
        let hints = lookup.hints(for: "906E")
        XCTAssertFalse(hints.isEmpty)
        XCTAssertTrue(hints.prefix(3).allSatisfy { $0.kind == .cpuid })
        XCTAssertTrue(hints.count <= 8)
        XCTAssertFalse(lookup.hints(for: "906EA").contains { $0.text == "906EA" })
        XCTAssertTrue(lookup.hints(for: "  ").isEmpty)
    }

    /// The highlight is on the text as written, across what the search ignores.
    func testTheHighlightSpansIgnoredCharacters() {
        let text = "Core i7-2600K"
        let ranges = CPUIDLookup.highlights(in: text, query: "i72600")
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["i7-2600"])
        XCTAssertEqual(CPUIDLookup.highlights(in: text, query: "core k").map { String(text[$0]) }, ["Core", "K"])
        XCTAssertTrue(CPUIDLookup.highlights(in: text, query: "").isEmpty)
    }

    /// The counts the status line gives before anything is typed.
    func testTheCountsLeaveSeriesOut() {
        XCTAssertEqual(lookup.modelCount, lookup.rows.filter { !$0.series }.count)
        XCTAssertLessThan(lookup.modelCount, lookup.rows.count, "the fixture has series lines")
        XCTAssertEqual(lookup.rows(matching: "").count, lookup.rows.count)
    }

    /// A search replaces what was typed on the way to it, and the list keeps ten.
    func testHistoryKeepsTheQueryNotItsBeginnings() {
        var history = SearchHistory.remembering("SR0", in: [])
        history = SearchHistory.remembering("i7  2600", in: history)
        history = SearchHistory.remembering("SR00C", in: history)
        XCTAssertEqual(history, ["SR00C", "i7 2600"])
        XCTAssertEqual(SearchHistory.remembering("   ", in: history), history)
        let full = (0..<12).reduce([String]()) { SearchHistory.remembering("Q\($1)X", in: $0) }
        XCTAssertEqual(full.count, SearchHistory.limit)
        XCTAssertEqual(full.first, "Q11X")
    }
}
