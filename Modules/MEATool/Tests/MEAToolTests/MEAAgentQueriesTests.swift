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
}
