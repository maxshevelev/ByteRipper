import AppKit
import XCTest
import CodeAnalysis
@testable import CodeView

/// The navigator switch's tabs come from the module's analysis profile: a UEFI
/// module and one with no profile keep the six of before, an ITE EC image
/// swaps Interfaces and POST for its own record sections.
@MainActor
final class CodeNavigatorTabsTests: XCTestCase {
    /// The switch as it was before profiles: four lists, Interfaces, Search.
    private let today: [CodeNavigatorTab] = [
        .list(.functions), .list(.strings), .list(.postCodes), .list(.statusCodes), .interfaces, .search
    ]

    func testAUEFIModuleKeepsTodaysTabs() {
        XCTAssertEqual(CodeNavigatorTab.tabs(for: .uefi), today)
        XCTAssertEqual(CodeNavigatorTab.tabs(for: AnalysisProfile.derive(kind: "TE", ecFamily: nil)), today)
    }

    func testAModuleWithNoProfileKeepsTodaysTabs() {
        XCTAssertEqual(CodeNavigatorTab.tabs(for: nil), today)
        XCTAssertNil(AnalysisProfile.derive(kind: nil, ecFamily: nil))
    }

    func testAnITEECImageHasItsRecordSectionsInPlaceOfInterfacesAndPOST() {
        let tabs = CodeNavigatorTab.tabs(for: .ecIteNds32)
        XCTAssertEqual(Array(tabs.prefix(1)), [.list(.functions)])
        XCTAssertFalse(tabs.contains(.list(.strings)))
        XCTAssertFalse(tabs.contains(.list(.statusCodes)))
        XCTAssertEqual(tabs.last, .search, "Search stays last")
        XCTAssertFalse(tabs.contains(.interfaces))
        XCTAssertFalse(tabs.contains(.list(.postCodes)))
        let records = tabs.dropFirst(1).dropLast().map { tab -> String in
            guard case let .record(id, _, _) = tab else { return "?" }
            return id
        }
        XCTAssertEqual(records, ["irq_map", "host_commands", "ec_ram", "smbus_peers", "gpio", "eflash_area"])
        XCTAssertEqual(tabs[1], .record(id: "irq_map", title: "Interrupts", symbol: "bolt"))
    }

    /// Every record the catalogue adds a section for has words of the app's
    /// own; an id it does not know keeps the profile's English.
    func testRecordTitlesAreTheAppsAndAnUnknownIdFallsBack() {
        for record in AnalysisProfile.catalogue.flatMap(\.addedPanelRecords) {
            XCTAssertEqual(CodeRecordSectionView.title(of: record.id, fallback: "-"), record.title, record.id)
        }
        XCTAssertEqual(CodeRecordSectionView.title(of: "future_kind", fallback: "Future kind"), "Future kind")
    }

    // MARK: - The pane

    private let moduleBytes = Data([0x56, 0x5A] + [UInt8](repeating: 0, count: 14))

    private func pane(kind: String?, ecFamily: String? = nil) throws -> CodePaneView {
        let ec = ecFamily.map {
            ECModuleFacts(family: $0, extent: 16, extentSource: "crt0", sliceSize: 16, rawSHA256: "",
                          masked: [], chipRead: false, hostUpdateSize: nil, version: nil)
        }
        let manifest = AnalysisManifest(
            module: ModuleIdentity(sha256: SHA256Digest(data: moduleBytes), size: moduleBytes.count,
                                   name: "Module", kind: kind, ec: ec),
            recipe: AnalysisRecipe(id: "code-v2-ghidra-12.1.2", exporter: 2, ghidra: "12.1.2",
                                   script: "ExportCode.java"),
            artifact: AnalysisArtifact(sha256: SHA256Digest(data: Data("artifact".utf8)), size: 8,
                                       mediaType: "application/json"),
            analyzedAt: "2026-10-25T15:00:00+00:00",
            stats: AnalysisStats(functions: 1, instructions: 1))
        let artifact = try JSONDecoder().decode(CodeArtifact.self, from: Data("""
        {"script_version":2,"ghidra":"12.1.2","program":{"image_base":"0x0"},
         "functions":[{"entry":"0x0","name":"entry","instructions":[
            {"address":"0x0","bytes":"56","mnemonic":"PUSH","text":"PUSH ESI"}]}]}
        """.utf8))
        return CodePaneView(manifest: manifest, artifact: artifact, moduleBytes: moduleBytes, hexView: NSView())
    }

    func testAUEFIPaneDrawsTodaysSwitch() throws {
        let pane = try self.pane(kind: "PE32")
        XCTAssertEqual(pane.navigatorTabs, today)
        XCTAssertEqual(pane.navigatorListIndex, 0)
        XCTAssertEqual(try self.pane(kind: nil).navigatorTabs, today)
    }

    func testAnECPaneShowsARecordSectionsHonestEmptyState() throws {
        let pane = try self.pane(kind: "EC", ecFamily: "ite-nds32")
        XCTAssertEqual(pane.navigatorTabs.count, 8)
        pane.showRecordSection("ec_ram")
        XCTAssertEqual(pane.shownRecordSection, "ec_ram")
        XCTAssertEqual(pane.navigatorListIndex, 3)
        XCTAssertFalse(pane.recordPanel.isHidden)
        XCTAssertEqual(pane.recordPanel.shownTitle, "EC RAM")
        XCTAssertEqual(pane.recordPanel.shownEmptyText, CodeRecordSectionView.emptyText)
        // The Search tab takes its place, and the lists come back after.
        pane.showSearchTab(true)
        XCTAssertNil(pane.shownRecordSection)
        XCTAssertTrue(pane.recordPanel.isHidden)
        pane.showSearchTab(false)
        pane.selectList(.functions)
        XCTAssertEqual(pane.navigatorListIndex, 0)
    }

    /// A new revision published while a record tab is in front changes the
    /// data only: the tab stays, and the switch and the section are the same
    /// views, with the new revision's rows in them. The app's path is
    /// followed — the reading adopted, the place restored, the records read.
    func testANewRevisionKeepsTheRecordTabInFront() throws {
        let pane = try self.pane(kind: "EC", ecFamily: "ite-nds32")
        pane.frame = NSRect(x: 0, y: 0, width: 500 + CodePaneView.defaultNavigatorWidth, height: 400)
        pane.layoutSubtreeIfNeeded()
        pane.showRecordSection("irq_map")
        let segment = pane.navigatorListIndex
        let navigatorSwitch = pane.navigatorSwitch
        let section = pane.recordPanel

        var manifest = pane.manifest
        manifest.reading = AnalysisReading(project: "p", rev: 2, records: ["irq_map": "complete"])
        pane.adoptReading(manifest: manifest,
                          model: CodeModel(artifact: pane.artifact, moduleBytes: moduleBytes), recipes: [])
        pane.restore(function: 0, instruction: 0, showsC: false)
        pane.focusSelectedFunction()
        pane.setModuleRecords(ModuleRecords(["irq_map": .init(status: .complete,
                                                               rows: [["irq": .string("4")]])]))
        pane.layoutSubtreeIfNeeded()

        XCTAssertEqual(pane.shownRecordSection, "irq_map", "the tab the reader chose stays")
        XCTAssertEqual(pane.navigatorListIndex, segment)
        XCTAssertFalse(pane.recordPanel.isHidden)
        XCTAssertTrue(pane.navigatorSwitch === navigatorSwitch, "the switch is not rebuilt")
        XCTAssertTrue(pane.recordPanel === section, "the section is not rebuilt")
        XCTAssertEqual(pane.manifest.reading?.rev, 2)
    }

    /// Each tab keeps its selected row: two record tabs and Functions, there
    /// and back.
    func testEachTabKeepsItsSelectionAcrossSwitches() throws {
        let pane = try self.pane(kind: "EC", ecFamily: "ite-nds32")
        pane.frame = NSRect(x: 0, y: 0, width: 500 + CodePaneView.defaultNavigatorWidth, height: 400)
        pane.layoutSubtreeIfNeeded()
        pane.setModuleRecords(ModuleRecords([
            "irq_map": .init(status: .complete, rows: [["irq": .string("4"), "purpose": .string("tick")],
                                                       ["irq": .string("5"), "purpose": .string("kbc")]]),
            "gpio": .init(status: .complete, rows: [["pin": .string("GPA3"), "function": .string("LED")],
                                                    ["pin": .string("GPJ5"), "function": .string("Lid")]])]))
        pane.selectFunction(at: 0)
        let section = pane.recordPanel
        func selected() -> String { section.listText(row: section.table.selectedRow) }
        func pick(_ text: String) throws {
            let row = try XCTUnwrap((0..<section.table.numberOfRows).first { section.listText(row: $0) == text }, text)
            section.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        pane.showRecordSection("irq_map")
        try pick("IRQ 5  kbc")
        pane.showRecordSection("gpio")
        try pick("GPJ5  Lid")
        pane.showRecordSection(nil)
        pane.selectList(.functions)
        XCTAssertEqual(pane.selectedFunctionIndex, 0)
        pane.showRecordSection("irq_map")
        XCTAssertEqual(selected(), "IRQ 5  kbc")
        pane.showRecordSection("gpio")
        XCTAssertEqual(selected(), "GPJ5  Lid")
        XCTAssertFalse(section.shownDetails.isEmpty, "its details too")
        pane.showRecordSection(nil)
        XCTAssertEqual(pane.selectedFunctionIndex, 0)
        pane.showRecordSection("irq_map")
        XCTAssertEqual(selected(), "IRQ 5  kbc")
    }

    /// A function's tooltip never shows over another tab: the Functions list
    /// is hidden, not only covered, while Search, Interfaces or a record is in
    /// front, on every way there and back.
    func testTheFunctionsListIsHiddenUnderEveryTab() throws {
        let pane = try self.pane(kind: "EC", ecFamily: "ite-nds32")
        pane.frame = NSRect(x: 0, y: 0, width: 500 + CodePaneView.defaultNavigatorWidth, height: 400)
        pane.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.functionScroll.isHidden)
        func underRecordRow() -> NSView? {
            let point = pane.recordPanel.convert(NSPoint(x: 20, y: pane.recordPanel.bounds.midY), to: pane)
            return pane.hitTest(point)
        }
        pane.showRecordSection("irq_map")
        XCTAssertTrue(pane.functionScroll.isHidden)
        XCTAssertFalse(underRecordRow()?.isDescendant(of: pane.functionTable) ?? false)
        pane.showSearchTab(true)
        XCTAssertTrue(pane.functionScroll.isHidden)
        pane.showSearchTab(false)
        XCTAssertFalse(pane.functionScroll.isHidden, "back to the list")
        pane.showRecordSection("gpio")
        XCTAssertTrue(pane.functionScroll.isHidden)
        pane.showRecordSection(nil)
        XCTAssertFalse(pane.functionScroll.isHidden)

        let uefi = try self.pane(kind: "PE32")
        uefi.showInterfacesTab(true)
        XCTAssertTrue(uefi.functionScroll.isHidden)
        uefi.showInterfacesTab(false)
        XCTAssertFalse(uefi.functionScroll.isHidden)
    }
}
