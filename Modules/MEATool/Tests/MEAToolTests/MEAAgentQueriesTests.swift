import MEFirmware
import XCTest
@testable import MEATool

/// What an agent is told the File System State rests on.
@MainActor
final class MEAAgentQueriesTests: XCTestCase {
    func testAConfiguredStateWithAnUnreadableEFSSaysWhatIsUnknown() {
        let basis = MFSStateBasis(reservedFiles: .notRead, efs: .unreadable(offset: 0x267000),
                                  configuration: ["FITC"], decidedBy: .configuration)
        // The explanation is what the row reads: the state, then the evidence
        // in brackets. The address of the EFS partition it could not read is in
        // the structured fields beside it, where the panel has room for it.
        let text = MEAAgentQueries.explanation(state: .configured, basis: basis)
        XCTAssertEqual(text, "Configured (configuration: FITC; EFS: unreadable)")
        XCTAssertEqual(MEAAgentQueries.efsText(basis.efs),
                       "unreadable: the partition table lists an EFS partition at 0x267000, but no EFS volume could be read there")
    }

    func testAnInitializedStateFromTheEFSNeedsNoCaveat() {
        let basis = MFSStateBasis(reservedFiles: .notRead, efs: .holdsFiles,
                                  configuration: ["FITC"], decidedBy: .efs)
        let text = MEAAgentQueries.explanation(state: .initialized, basis: basis)
        XCTAssertEqual(text, "Initialized (EFS: holds files)")
        XCTAssertEqual(MEAAgentQueries.reservedText(.initializing([2, 8])), "present: file 2, file 8, which mean Initialized")
    }

    /// What an agent is told the Manufacturing verdict rests on: an agent that
    /// reads "Will close on first boot" and acts on it must be able to see
    /// which record the flag came from, what End of Manufacturing will commit,
    /// and what the descriptor said beside it.
    func testTheManufacturingVerdictCarriesItsEvidence() throws {
        let basis = ManufacturingBasis(
            flag: true, flexible: 0, page: .imageConfiguration,
            descriptorOpen: false, liveFilesResolved: true)
        let json = MEAAgentQueries.manufacturingBasisJSON(.willClose, basis)
        guard case .object(let members) = json else { return XCTFail("not an object") }
        XCTAssertEqual(members["flag"], .bool(true))
        XCTAssertEqual(members["flexible_eom_settings"], .count(0))
        XCTAssertEqual(members["flag_page"], .string("imageConfiguration"))
        XCTAssertEqual(members["descriptor"], .string("locked"))
        XCTAssertEqual(members["live_files"], .string("read"))
        guard case .string(let explanation)? = members["explanation"] else {
            return XCTFail("no explanation")
        }
        // What the row itself reads, brackets and all.
        XCTAssertEqual(explanation, "Will close on the EOM flag (EOM: on, descriptor: locked)")

        // A region read without a descriptor, and with a file system the
        // database could not name: both are said rather than left out.
        let unread = MEAAgentQueries.manufacturingBasisJSON(.willClose, ManufacturingBasis(
            flag: true, flexible: 1, page: .liveMFS, liveFilesResolved: false))
        guard case .object(let sparse) = unread else { return XCTFail("not an object") }
        XCTAssertEqual(sparse["descriptor"], .string("not read"))
        XCTAssertEqual(sparse["live_files"], .string("not read"))
        XCTAssertEqual(sparse["flag_page"], .string("liveMFS"))
    }
}
