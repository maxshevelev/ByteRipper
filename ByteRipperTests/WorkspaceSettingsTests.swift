import XCTest
@testable import ByteRipper

/// The General tab's workspace switch: off until someone turns it on, and the
/// checkbox reads and writes the one stored value.
@MainActor
final class WorkspaceSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WorkspaceSettings.resetToDefaults()
    }

    override func tearDown() {
        WorkspaceSettings.resetToDefaults()
        super.tearDown()
    }

    func testTheWorkspaceIsNotRestoredUntilSwitchedOn() {
        XCTAssertFalse(WorkspaceSettings.restoresWorkspace)
    }

    func testTheCheckboxReflectsAndWritesTheSetting() {
        let controller = WorkspaceSettingsViewController()
        _ = controller.view
        let checkbox = controller.restoreCheckboxForTesting
        XCTAssertEqual(checkbox.state, .off)

        checkbox.state = .on
        NSApp.sendAction(checkbox.action!, to: checkbox.target, from: checkbox)
        XCTAssertTrue(WorkspaceSettings.restoresWorkspace)

        WorkspaceSettings.set(restoresWorkspace: false)
        controller.refresh()
        XCTAssertEqual(checkbox.state, .off)
    }
}
