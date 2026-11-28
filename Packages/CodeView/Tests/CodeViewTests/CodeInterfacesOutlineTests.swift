import CodeAnalysis
@testable import CodeView
import ToolModuleKit
import XCTest

/// The Interfaces tab's rows without a window: what each row says, in what
/// tone, and where it leads.
final class CodeInterfacesOutlineTests: XCTestCase {
    private let located = ModuleInterfaces.Interface(
        guid: "0AE8CE5D-E448-4437-A8D7-EBF5F194F731", name: "EFI_PEI_READ_ONLY_VARIABLE2_PPI", kind: .ppi,
        address: "0x221", condition: "only on S3 resume", purpose: "Reads the setup variables.", required: true,
        callback: "0x400")

    func testAnInterfaceSaysWhyWhenWhatAndWhere() {
        let rows = CodeInterfacesOutline.details(of: located) { $0 == CodeAddress(0x221) ? "Entry+0x21" : nil }
        XCTAssertEqual(rows.map(\.text.string), [
            "Reads the setup variables.", "When: only on S3 resume",
            "PPI 0AE8CE5D-E448-4437-A8D7-EBF5F194F731", "At: Entry+0x21", "Callback: 0x400"
        ])
        XCTAssertEqual(rows[2].text.parts.last?.tone, .mono, "a GUID is read character by character")
        XCTAssertEqual(rows[3].address, CodeAddress(0x221), "a place in the code opens")
        XCTAssertEqual(rows[3].text.parts.last?.tone, .link)
        XCTAssertNil(rows[4].address, "no instruction there: the address as written, no link")
        XCTAssertEqual(rows[4].text.parts.last?.tone, .plain)
    }

    func testTheListsCarryTheirMarks() {
        let groups = CodeInterfacesOutline.groups(of: ModuleInterfaces(installs: [], locates: [located])) { _ in nil }
        XCTAssertEqual(groups.map(\.title), ["Installs", "Locates", "Notified of"])
        XCTAssertEqual(groups[1].entries?.first?.marks, ["required"])
        XCTAssertNil(CodeInterfacesOutline.groups(of: nil) { _ in nil }[0].entries, "not answered: no list")
    }

    func testADependencyExpressionReadsAsItsConditions() {
        let outline = DependencyOutline(conditions: [
            .not(.interface(guid: "G1", name: "gFirstPpiGuid")),
            .anyOf([.interface(guid: "G2", name: nil), .always])
        ])
        let rows = CodeInterfacesOutline.conditions(of: outline)
        XCTAssertEqual(rows.map(\.text.string), ["NOT gFirstPpiGuid", "One of"])
        XCTAssertEqual(rows[0].text.parts.first?.tone, .quiet, "NOT is the format's word")
        XCTAssertEqual(rows[1].children.map(\.text.string), ["G2", "TRUE: the module waits for nothing"])
        XCTAssertEqual(rows[1].children[0].guid, "G2")
    }
}
