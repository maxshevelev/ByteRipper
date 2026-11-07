import XCTest
@testable import FITTool

final class ProcessorNamesTests: XCTestCase {
    private let catalogue = [
        ProcessorFamily(
            cpuids: ["906EA"], codeNames: ["Coffee Lake H", "Coffee Lake S"],
            productFamilies: ["8th Generation Intel Core Processor Family"],
            steppings: ["U0"], segments: ["Mobile", "Desktop"],
            processors: [
                ProcessorModel(name: "Intel Core i7-8750H", sSpec: ["SR3YY"], sSpecSource: nil, series: nil),
                ProcessorModel(name: "Intel Core i7-8700", sSpec: [], sSpecSource: nil, series: nil)
            ]),
        ProcessorFamily(
            cpuids: ["606AX"], codeNames: ["Ice Lake Xeon-SP"], productFamilies: [],
            steppings: [], segments: ["Server"],
            processors: [ProcessorModel(name: "Intel Xeon Gold 6300", sSpec: [], sSpecSource: nil, series: true)])
    ]

    func testTheShippedTableIsRead() {
        XCTAssertGreaterThan(ProcessorNames.shipped.count, 50)
        XCTAssertFalse(ProcessorNames.families(for: [0x906EA]).isEmpty, "906EA is in the shipped table")
    }

    func testAnXInTheTableMatchesAnyDigit() {
        XCTAssertEqual(ProcessorNames.families(for: [0x606A6], in: catalogue).map(\.codeNames),
                       [["Ice Lake Xeon-SP"]])
        XCTAssertTrue(ProcessorNames.families(for: [0x606B6], in: catalogue).isEmpty)
    }

    func testAGroupIsFollowedByItsModelsWithoutTheWordIntel() {
        let groups = FITProcessorGroup.groups(for: [0x906EA], in: catalogue, language: .english)
        XCTAssertEqual(groups, [.init(cpuid: "906EA", codeNames: ["Coffee Lake H", "Coffee Lake S"],
                                      notes: ["Coffee Lake H, Coffee Lake S\n"
                                              + "8th Generation Intel Core Processor Family\n"
                                              + "Stepping U0 · Mobile · Desktop"], lines: [
            .init(kind: .model, text: "Core i7-8750H", detail: "SR3YY"),
            .init(kind: .model, text: "Core i7-8700", detail: "")
        ])])
    }

    /// Every CPUID of an update is a group of its own, in the update's order,
    /// and one the table does not know says so rather than being left out.
    func testEveryCPUIDOfTheUpdateIsAGroup() {
        let groups = FITProcessorGroup.groups(for: [0x906EA, 0x906EB], in: catalogue, language: .english)
        XCTAssertEqual(groups.map(\.cpuid), ["906EA", "906EB"])
        XCTAssertEqual(groups[1].codeNames, [])
        XCTAssertEqual(groups[1].lines, [.init(kind: .unknown,
                                               text: "No processor names known for CPUID 906EB", detail: "")])
    }

    /// What is said about a group — its names, its product families, the
    /// cores, a hybrid's two kinds as one part, the stepping and the segments
    /// — is a note for the popover's head, not a line of its list; and a
    /// CPUID with two groups names each group over its models.
    func testWhatIsSaidAboutAGroupIsANote() {
        var hybrid = catalogue[0]
        hybrid.cores = ["Golden Cove", "Gracemont"]
        hybrid.productFamilies = []
        let groups = FITProcessorGroup.groups(for: [0x906EA], in: [hybrid], language: .english)
        XCTAssertEqual(groups.first?.notes,
                       ["Coffee Lake H, Coffee Lake S\nGolden Cove + Gracemont · Stepping U0 · Mobile · Desktop"])
        XCTAssertEqual(groups.first?.lines.map(\.kind), [.model, .model], "no line naming the one group")

        let shipped = FITProcessorGroup.groups(for: [0x90672], language: .english)
        XCTAssertEqual(shipped.first?.codeNames, ["Alder Lake-HX", "Alder Lake S"], "no brackets left in the names")
        XCTAssertTrue(shipped.first?.notes.first?.contains("\nGolden Cove + Gracemont") == true)

        let twoGroups = FITProcessorGroup.groups(for: [0x806D1], language: .english)
        XCTAssertEqual(twoGroups.first?.notes.count, 2, "\(twoGroups.first?.notes ?? [])")
        XCTAssertTrue(twoGroups.first?.notes.allSatisfy { $0.hasPrefix("Tiger Lake H\n") } == true)
        let headings = twoGroups.first?.lines.filter { $0.kind == .family } ?? []
        XCTAssertEqual(headings.map(\.text), ["Tiger Lake H", "Tiger Lake H"])
        XCTAssertEqual(headings.map(\.detail),
                       twoGroups.first?.notes.map { $0.replacingOccurrences(of: "Tiger Lake H\n", with: "") },
                       "each group's note over its own models")
        XCTAssertEqual(twoGroups.first?.lines.first?.kind, .family, "the first group named over its models")
    }

    func testASeriesIsSaidToBeOne() {
        let groups = FITProcessorGroup.groups(for: [0x606A6], in: catalogue, language: .english)
        XCTAssertEqual(groups.first?.lines.last?.detail, "series, models not listed")
    }
}
