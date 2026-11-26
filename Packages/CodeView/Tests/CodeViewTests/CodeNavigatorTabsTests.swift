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
}
