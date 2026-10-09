import AgentKit
import XCTest
@testable import ByteRipper

/// The agent service as the person sees it: the Settings tab that switches it,
/// the Agent window that logs it, the Window menu's way there, and the text a
/// client is configured with (`Design/AGENT_PLAN.md`, stage 2).
@MainActor
final class AgentUITests: XCTestCase {
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var service: AgentService!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        service = AgentService(desk: AgentDesk(controllers: { [] }, keyController: { nil }),
                               defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
    }

    override func tearDown() {
        service.stop()
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    // MARK: - Settings ▸ Agent

    func testTheTabSwitchesTheServiceOnAndOffAndSaysSo() {
        let tab = AgentSettingsViewController()
        tab.service = service
        _ = tab.view
        XCTAssertFalse(tab.isEnabledShown, "off after installation")
        XCTAssertEqual(AgentSettingsViewController.statusText(of: service), "Switched off.")

        tab.toggleForTesting()
        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(AgentSettingsViewController.statusText(of: service), "Waiting for an agent.")

        tab.toggleForTesting()
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.socketPath))
    }

    /// A second copy of the app keeps its hands off the first one's socket,
    /// and says why it is not running.
    func testASocketAnotherCopyHoldsIsReportedNotTaken() throws {
        let other = UnixSocketListener(path: service.socketPath)
        try other.start { _ in }
        defer { other.stop() }
        service.isEnabled = true
        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(AgentSettingsViewController.statusText(of: service).hasPrefix("Could not start: "),
                      AgentSettingsViewController.statusText(of: service))
    }

    func testTheSettingsWindowHasAnAgentTab() {
        XCTAssertTrue(SettingsWindowController.toolbarLabels.contains("Agent"))
    }

    // MARK: - What a client is configured with

    func testTheClaudeCodeCommandNamesTheRelayQuotedForTheShell() {
        XCTAssertEqual(
            AgentClientConfiguration.text(for: .claudeCode,
                                          relay: "/Applications/My Tools/ByteRipper.app/Contents/Helpers/byteripper-mcp"),
            "claude mcp add --scope user byteripper -- '/Applications/My Tools/ByteRipper.app/Contents/Helpers/byteripper-mcp'")
        XCTAssertEqual(AgentClientConfiguration.text(for: .claudeCode, relay: "/a/it's"),
                       #"claude mcp add --scope user byteripper -- '/a/it'\''s'"#)
    }

    /// Claude Desktop and Cursor read the same block, laid out for a file a
    /// person edits by hand.
    func testClaudeDesktopAndCursorGetTheSameJSONBlockOneMemberPerLine() throws {
        for client in [AgentClientConfiguration.Client.claudeDesktop, .cursor] {
            let text = AgentClientConfiguration.text(for: client, relay: "/x/byteripper-mcp")
            let value = try JSONValue.parse(Data(text.utf8))
            XCTAssertEqual(value["mcpServers"]?["byteripper"]?["command"], "/x/byteripper-mcp")
            XCTAssertGreaterThan(text.split(separator: "\n").count, 3, "pretty, not one line: \(text)")
        }
    }

    func testAnOtherClientIsGivenTheParametersOneByOne() {
        let text = AgentClientConfiguration.text(for: .other, relay: "/x/byteripper-mcp")
        XCTAssertEqual(text.split(separator: "\n").map { $0.split(separator: " ").first.map(String.init) },
                       ["Name", "Transport", "Command", "Arguments", "Environment"])
        XCTAssertTrue(text.contains("stdio"))
        XCTAssertTrue(text.contains("/x/byteripper-mcp"))
    }

    /// The tab shows the text it would copy, and says where it goes.
    func testTheTabPreviewsEachClientsConfiguration() {
        let tab = AgentSettingsViewController()
        tab.service = service
        _ = tab.view
        XCTAssertTrue(tab.previewText.hasPrefix("claude mcp add"), tab.previewText)
        tab.choose(.cursor)
        XCTAssertTrue(tab.previewText.contains(#""mcpServers""#), tab.previewText)
        XCTAssertTrue(tab.destinationText.contains("~/.cursor/mcp.json"), tab.destinationText)
        tab.choose(.other)
        XCTAssertTrue(tab.previewText.hasPrefix("Name"), tab.previewText)
        for client in AgentClientConfiguration.Client.allCases {
            tab.choose(client)
            XCTAssertEqual(tab.previewText, AgentClientConfiguration.text(for: client))
        }
    }

    /// The relay the button hands out is the one inside the app's bundle.
    func testTheRelayIsInsideTheAppBundle() {
        XCTAssertTrue(AgentClientConfiguration.relayPath.hasSuffix(".app/Contents/Helpers/byteripper-mcp"),
                      AgentClientConfiguration.relayPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: AgentClientConfiguration.relayPath),
                      "the build embeds the relay")
    }

    // MARK: - Window ▸ Agent

    func testTheWindowLogsEachCallWithItsArgumentsAndResult() async {
        let controller = AgentWindowController(service: service)
        _ = controller.window
        let connection = service.connect(send: { _ in })
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read","arguments":{"offset":"0x10"}}}"# + "\n").utf8))
        await connection.waitUntilIdle()
        let logged = await awaitUntil(1) { self.service.log.count == 1 }
        XCTAssertTrue(logged)
        controller.refresh()
        XCTAssertEqual(controller.shownText(row: 0, column: "tool"), "read")
        XCTAssertEqual(controller.shownText(row: 0, column: "arguments"), #"{"offset":"0x10"}"#)
        XCTAssertEqual(controller.shownText(row: 0, column: "result"), "No file is open in ByteRipper.")

        service.clearLog()
        controller.refresh()
        XCTAssertNil(controller.shownText(row: 0, column: "tool"))
    }

    /// The table cuts the arguments to a column; the details under it give
    /// the selected call whole, each argument on a row of its own.
    func testTheDetailsShowTheSelectedCallWhole() async {
        let controller = AgentWindowController(service: service)
        _ = controller.window
        let connection = service.connect(send: { _ in })
        let arguments = #"{"offset":"0x10","length":64,"format":"u8","paths":["/a/one.bin","/b/two.bin"]}"#
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read","arguments":"#
            + arguments + "}}\n").utf8))
        await connection.waitUntilIdle()
        let logged = await awaitUntil(1) { self.service.log.count == 1 }
        XCTAssertTrue(logged)
        controller.refresh()
        XCTAssertTrue(controller.shownDetails.isEmpty, "nothing selected: the placeholder")

        controller.selectLogRow(0)
        let shown = Dictionary(uniqueKeysWithValues: controller.shownDetails.map { ($0.label, $0.value) })
        XCTAssertEqual(shown["offset"], "0x10", "a text as it is, without quotes")
        XCTAssertEqual(shown["length"], "64")
        XCTAssertEqual(shown["paths"], "[\n  \"/a/one.bin\",\n  \"/b/two.bin\"\n]", "anything else laid out")
        XCTAssertEqual(shown["Result"], "No file is open in ByteRipper.")
        XCTAssertEqual(controller.shownDetails.last?.label, "paths", "arguments last, by name")
    }

    func testTheWindowMenuLeadsToTheAgentWindow() throws {
        // Held here: a menu item holds its target weakly.
        let target = NSObject()
        let menu = MainMenu.build(appTarget: target)
        let window = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Window" })
        let item = try XCTUnwrap(window.items.first { $0.title == "Agent" })
        XCTAssertEqual(item.action, #selector(AppDelegate.showAgentWindow(_:)))
        XCTAssertTrue(item.target === target, "aimed at the app, not at whichever window is key")
    }
}
