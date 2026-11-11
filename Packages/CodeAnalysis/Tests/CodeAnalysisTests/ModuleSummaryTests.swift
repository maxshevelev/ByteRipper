import XCTest
@testable import CodeAnalysis

/// The summary the UEFI tree shows beside a module's file: the paragraph
/// under the description's title.
final class ModuleSummaryTests: XCTestCase {
    func testTheSummaryIsTheTextBetweenTheTitleAndTheFirstSection() {
        let description = """
        # PeiVariable

        The PEI phase's read-only access to UEFI variables. It installs the
        Read Only Variable 2 PPI, which other PEIMs use to read settings.

        ## What it is

        - Origin: EDK2
        """
        XCTAssertEqual(ModuleSummary.of(description: description),
                       "The PEI phase's read-only access to UEFI variables. It installs the "
                       + "Read Only Variable 2 PPI, which other PEIMs use to read settings.")
    }

    func testParagraphsStayApartAndInlineMarkdownGoes() {
        let description = """
        # Module
        It calls [ProcessFv](0x9DFD3F8) and `InstallPpi`, **twice**, *always*.

        A second ~~sentence~~ paragraph with Name_With_Underscores and a * b.
        ## Execution flow
        """
        XCTAssertEqual(ModuleSummary.of(description: description),
                       "It calls ProcessFv and InstallPpi, twice, always.\n\n"
                       + "A second sentence paragraph with Name_With_Underscores and a * b.")
    }

    func testADescriptionWithoutASummaryHasNone() {
        XCTAssertNil(ModuleSummary.of(description: "# Module\n\n## What it is\n\n- Origin: EDK2\n"))
        XCTAssertNil(ModuleSummary.of(description: ""))
    }
}
