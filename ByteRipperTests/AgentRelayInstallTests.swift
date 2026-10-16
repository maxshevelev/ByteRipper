import AgentKit
import XCTest
@testable import ByteRipper

/// Where the relay a client's configuration names comes from: the app's helper,
/// installed beside the socket (`AgentEndpoint.relayPath()`), so that the path
/// in a configuration outlives the build folder the app was run from.
final class AgentRelayInstallTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("byteripper-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func helper(_ text: String) throws -> URL {
        let helper = folder.appendingPathComponent("ByteRipper.app/Contents/Helpers/\(AgentEndpoint.relayName)")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: helper)
        return helper
    }

    private var installed: URL {
        folder.appendingPathComponent("Application Support/ByteRipper/\(AgentEndpoint.relayName)")
    }

    func testTheHelperIsInstalledBesideTheSocketAndMadeExecutable() throws {
        let helper = try helper("#!/bin/sh\necho first\n")
        XCTAssertTrue(AgentRelayInstall.install(helper: helper, at: installed))
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: helper))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path),
                      "a client runs it as a command")
    }

    /// A second launch installs this app's version over the old one — that is
    /// what keeps the installed relay the *current* build's — and leaves nothing
    /// staged beside it.
    func testASecondInstallReplacesTheFirstAndLeavesNothingBehind() throws {
        let helper = try helper("#!/bin/sh\necho first\n")
        XCTAssertTrue(AgentRelayInstall.install(helper: helper, at: installed))

        try Data("#!/bin/sh\necho second\n".utf8).write(to: helper)
        XCTAssertTrue(AgentRelayInstall.install(helper: helper, at: installed))
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: helper))

        let left = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertEqual(left, [AgentEndpoint.relayName], "the staged copy is gone")
    }

    /// Nothing to install is not an install: the settings then hand out the
    /// bundled helper, which is what they did before there was an installed one.
    func testAnUnreadableHelperIsNotAnInstall() throws {
        XCTAssertFalse(AgentRelayInstall.install(helper: folder.appendingPathComponent("nowhere"),
                                                 at: installed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }
}
