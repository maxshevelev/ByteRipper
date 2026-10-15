import MEFirmware
import XCTest
@testable import MEATool

/// What an agent is told the File System State rests on.
@MainActor
final class MEAAgentQueriesTests: XCTestCase {
    func testAConfiguredStateWithAnUnreadableEFSSaysWhatIsUnknown() {
        let basis = MFSStateBasis(reservedFiles: .notRead, efs: .unreadable(offset: 0x267000),
                                  configuration: ["FITC"], decidedBy: .configuration)
        let text = MEAAgentQueries.explanation(state: .configured, basis: basis)
        XCTAssertTrue(text.hasPrefix("Configured, from the configuration found (FITC), not from files"), text)
        XCTAssertTrue(text.contains("The EFS partition at 0x267000 could not be read"), text)
        XCTAssertTrue(text.contains("is unknown"), text)
        XCTAssertEqual(MEAAgentQueries.efsText(basis.efs),
                       "unreadable: the partition table lists an EFS partition at 0x267000, but no EFS volume could be read there")
    }

    func testAnInitializedStateFromTheEFSNeedsNoCaveat() {
        let basis = MFSStateBasis(reservedFiles: .notRead, efs: .holdsFiles,
                                  configuration: ["FITC"], decidedBy: .efs)
        let text = MEAAgentQueries.explanation(state: .initialized, basis: basis)
        XCTAssertEqual(text, "Initialized, because the EFS volume holds file content: the engine has run and written its files.")
        XCTAssertEqual(MEAAgentQueries.reservedText(.initializing([2, 8])), "present: file 2, file 8, which mean Initialized")
    }

    /// What an agent is told the Manufacturing verdict rests on: an agent that
    /// reads "Already closed" and acts on it must be able to see that it was
    /// the live record of the file system that said so, and what the descriptor
    /// and the other page said beside it.
    func testTheManufacturingVerdictCarriesItsEvidence() throws {
        let basis = ManufacturingBasis(
            eom: 1, flag: false, flexible: 0, page: .imageConfiguration,
            descriptorOpen: false, liveFilesResolved: true)
        let json = MEAAgentQueries.manufacturingBasisJSON(basis)
        guard case .object(let members) = json else { return XCTFail("not an object") }
        XCTAssertEqual(members["eom_record"], .count(1))
        XCTAssertEqual(members["flag"], .bool(false))
        XCTAssertEqual(members["flexible_eom_settings"], .count(0))
        XCTAssertEqual(members["flag_page"], .string("imageConfiguration"))
        XCTAssertEqual(members["descriptor"], .string("locked"))
        XCTAssertEqual(members["live_files"], .string("read"))
        guard case .string(let explanation)? = members["explanation"] else {
            return XCTFail("no explanation")
        }
        XCTAssertTrue(explanation.contains("Manufacturing has been closed on this board already"), explanation)

        // A region read without a descriptor, and with a file system the
        // database could not name: both are said rather than left out.
        let unread = MEAAgentQueries.manufacturingBasisJSON(ManufacturingBasis(
            flag: true, flexible: 1, page: .liveMFS, liveFilesResolved: false))
        guard case .object(let sparse) = unread else { return XCTFail("not an object") }
        XCTAssertEqual(sparse["eom_record"], .null)
        XCTAssertEqual(sparse["descriptor"], .string("not read"))
        XCTAssertEqual(sparse["live_files"], .string("not read"))
        XCTAssertEqual(sparse["flag_page"], .string("liveMFS"))
    }
}
