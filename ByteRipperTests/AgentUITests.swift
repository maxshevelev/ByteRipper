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
        XCTAssertEqual(AgentSettingsViewController.statusText(of: service), "Waiting for a connection.")

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

    /// The Tools page lists every tool the agent is offered, grouped and
    /// classed, with what it has been used for; the details give the tool as
    /// the agent reads it.
    func testTheToolsPageListsEveryToolWithItsUseAndWhatTheAgentReads() async throws {
        let controller = AgentWindowController(service: service)
        _ = controller.window
        let connection = service.connect(send: { _ in })
        for id in 1...2 {
            await connection.receive(Data((#"{"jsonrpc":"2.0","id":"# + "\(id)"
                + #","method":"tools/call","params":{"name":"read","arguments":{}}}"# + "\n").utf8))
        }
        await connection.waitUntilIdle()
        let logged = await awaitUntil(1) { self.service.toolStats["read"]?.calls == 2 }
        XCTAssertTrue(logged)
        controller.refresh()
        controller.showTools()
        let page = controller.toolsPage
        XCTAssertEqual(Set(page.rows.map(\.tool.name)), Set(service.server.tools.map(\.name)), "every tool")
        XCTAssertEqual(page.rows.count, service.server.tools.count)
        // A section to each group, headed by its name, in the order the groups come.
        XCTAssertEqual(page.sectionTitles.first, "Files and View")
        XCTAssertTrue(page.sectionTitles.contains("UEFI Structure"))
        XCTAssertEqual(page.sectionTitles.count, Set(page.sectionTitles).count, "each group once")
        XCTAssertTrue(page.table.delegate?.tableView?(page.table, isGroupRow: 0) == true)
        XCTAssertFalse(page.table.delegate?.tableView?(page.table, shouldSelectRow: 0) ?? true, "a heading is not chosen")
        // A heading stands out: a size above the names, with room above it;
        // the names stand in from their heading.
        let firstTool = try XCTUnwrap(page.table.delegate?.tableView?(
            page.table, viewFor: page.table.tableColumns.first, row: 1) as? NSTableCellView)
        XCTAssertGreaterThan(AgentToolsPage.headingFont.pointSize,
                             try XCTUnwrap(firstTool.textField?.font?.pointSize), "a heading is larger than a name")
        XCTAssertGreaterThanOrEqual(page.table.delegate?.tableView?(page.table, heightOfRow: 0) ?? 0,
                                    page.table.rowHeight + 10, "room above a heading")
        firstTool.frame = NSRect(x: 0, y: 0, width: 140, height: page.table.rowHeight)
        firstTool.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstTool.textField?.frame.minX), AgentToolsPage.toolIndent,
                                    "the names stand in from their heading")
        // What the window adds goes to the last column and to no other.
        XCTAssertEqual(page.table.columnAutoresizingStyle, .lastColumnOnlyAutoresizingStyle)
        XCTAssertEqual(page.table.tableColumns.map { $0.resizingMask.contains(.autoresizingMask) },
                       page.table.tableColumns.indices.map { $0 == page.table.tableColumns.count - 1 })
        let read = try XCTUnwrap(page.row(of: "read"))
        XCTAssertEqual(page.shownText(row: read, column: "kind"), "Read")
        XCTAssertEqual(page.shownText(row: read, column: "calls"), "2")
        XCTAssertEqual(page.shownText(row: read, column: "failures"), "2", "no file was open")
        let write = try XCTUnwrap(page.row(of: "write"))
        XCTAssertEqual(page.shownText(row: write, column: "kind"), "Edits a File")
        XCTAssertEqual(page.shownText(row: write, column: "calls"), "")
        let fix = try XCTUnwrap(page.rows.first { $0.tool.name == "uefi_fix_checksum" })
        XCTAssertEqual(fix.group.title, "UEFI Structure")
        XCTAssertEqual(fix.kind, .edit)

        page.select(read)
        let tool = try XCTUnwrap(service.server.tools.first { $0.name == "read" })
        XCTAssertEqual(page.shownTexts.first, tool.description, "the description as the agent reads it")
        XCTAssertEqual(page.shownTexts.last, tool.inputSchema.prettyText)

        service.resetToolStats()
        controller.refresh()
        XCTAssertEqual(page.shownText(row: read, column: "calls"), "")
    }

    /// The window's width goes to one column in the Marks and Tools lists: Note
    /// and Last Call, the last in each. The others keep the widths they were
    /// given.
    func testTheLastColumnTakesWhatTheWindowAddsInMarksAndTools() {
        let controller = AgentWindowController(service: service)
        _ = controller.window
        for table in [controller.marksList.table, controller.toolsPage.table] {
            XCTAssertEqual(table.columnAutoresizingStyle, .lastColumnOnlyAutoresizingStyle)
            XCTAssertEqual(table.tableColumns.map { $0.resizingMask.contains(.autoresizingMask) },
                           table.tableColumns.indices.map { $0 == table.tableColumns.count - 1 })
        }
        XCTAssertEqual(controller.marksList.table.tableColumns.last?.title, "Note")
        XCTAssertEqual(controller.toolsPage.table.tableColumns.last?.title, "Last Call")
    }

    /// The log shows a request while the tool is still working on it, and the
    /// row is the same one when the answer comes.
    func testTheLogShowsARequestWhileItRuns() async throws {
        let controller = AgentWindowController(service: service)
        _ = controller.window
        let connection = service.connect(send: { _ in })
        // `survey` over no files answers at once; `open_dump` of a path that
        // does not exist fails at once: neither holds still, so the running
        // record is made by hand and then replaced by the finished one.
        let running = AgentCallRecord(client: "test", tool: "read", arguments: ["offset": "0x10"],
                                      started: Date(), duration: .zero, finished: Date(),
                                      answerBytes: 0, outcome: .running)
        service.recordForTesting(running)
        controller.refresh()
        XCTAssertEqual(controller.shownRows.map(\.tool), ["read"])
        XCTAssertEqual(controller.shownText(row: 0, column: "result"), "Running…")
        XCTAssertEqual(controller.shownText(row: 0, column: "duration"), "0 s", "counts up while it runs")
        XCTAssertEqual(controller.shownText(row: 0, column: "size"), "")

        let done = AgentCallRecord(id: running.id, client: "test", tool: "read", arguments: ["offset": "0x10"],
                                   started: running.started, duration: .milliseconds(12), finished: Date(),
                                   answerBytes: 100, outcome: .answered)
        service.recordForTesting(done)
        controller.refresh()
        XCTAssertEqual(controller.shownRows.count, 1, "the finished call took the running one's place")
        XCTAssertEqual(controller.shownText(row: 0, column: "result"), "Answered")
        XCTAssertEqual(service.toolStats["read"]?.calls, 1, "counted once, when it ended")
        _ = connection
    }

    /// The window opens tall the first time and keeps the frame it was left in.
    func testTheWindowOpensTallAndKeepsItsFrame() throws {
        let key = "NSWindow Frame " + AgentWindowController.frameAutosaveName
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let first = try XCTUnwrap(AgentWindowController(service: service).window)
        XCTAssertEqual(first.frameAutosaveName, AgentWindowController.frameAutosaveName,
                       "the name survives the window controller taking the window")
        let room = try XCTUnwrap((first.screen ?? NSScreen.main)?.visibleFrame.height) - 40
        XCTAssertGreaterThanOrEqual(first.frame.height, min(AgentWindowController.initialSize.height, room))

        first.setFrame(NSRect(x: 120, y: 140, width: 640, height: 500), display: false)
        first.saveFrame(usingName: AgentWindowController.frameAutosaveName)
        let second = try XCTUnwrap(AgentWindowController(service: service).window)
        XCTAssertEqual(second.frame.width, 640, accuracy: 1)
        XCTAssertEqual(second.frame.height, 500, accuracy: 1)
        XCTAssertEqual(second.frame.origin.x, 120, accuracy: 1)
    }

    /// The table cuts the arguments to a column; the details under it give
    /// the selected call whole, each argument on a row of its own.
    func testTheDetailsShowTheSelectedCallWhole() async {
        let controller = AgentWindowController(service: service)
        _ = controller.window
        let connection = service.connect(send: { _ in })
        let arguments = #"{"offset":"0x10","length":64,"label":"Model","related_to":["m1","m2"]}"#
        await connection.receive(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mark","arguments":"#
            + arguments + "}}\n").utf8))
        await connection.waitUntilIdle()
        let logged = await awaitUntil(1) { self.service.log.count == 1 }
        XCTAssertTrue(logged)
        controller.refresh()
        XCTAssertTrue(controller.shownDetails.isEmpty, "nothing selected: the placeholder")

        controller.selectLogRow(0)
        let shown = Dictionary(uniqueKeysWithValues: controller.shownDetails.map { ($0.label, $0.value) })
        XCTAssertEqual(shown["Result"], "No file is open in ByteRipper.")
        XCTAssertEqual(controller.shownArguments, """
            {
              "label" : "Model",
              "length" : 64,
              "offset" : "0x10",
              "related_to" : [
                "m1",
                "m2"
              ]
            }
            """, "the whole JSON, laid out")

        // Space or the corner button opens it over the window, as a tool
        // panel's details open.
        XCTAssertTrue(controller.detailsPane.showQuickLook())
        XCTAssertTrue(controller.detailsPane.isQuickLookShown)
        controller.detailsPane.closeQuickLook()
        XCTAssertFalse(controller.detailsPane.isQuickLookShown)
        controller.close()
    }

    /// A new request leaves the selected row selected and the log where the
    /// reader left it; with Follow New Requests on, the log goes to it.
    func testTheLogKeepsItsSelectionAndFollowsOnlyWhenAsked() async {
        let saved = AgentWindowController.follows
        defer { AgentWindowController.follows = saved }
        let controller = AgentWindowController(service: service)
        controller.window?.setContentSize(NSSize(width: 760, height: 420))
        controller.showWindow(nil)
        defer { controller.close() }
        let connection = service.connect(send: { _ in })
        func call(_ id: Int) async {
            await connection.receive(Data((#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"read","arguments":{"offset":"0x10"}}}"#
                + "\n").utf8))
            await connection.waitUntilIdle()
        }
        for id in 0..<40 { await call(id) }
        _ = await awaitUntil(2) { self.service.log.count == 40 }
        controller.setFollowsForTesting(false)
        controller.refresh()
        controller.window?.layoutIfNeeded()
        controller.selectLogRow(3)
        controller.logScrollToTopForTesting()
        let before = controller.logVisibleRows

        await call(40)
        _ = await awaitUntil(2) { self.service.log.count == 41 }
        controller.refresh()
        XCTAssertEqual(controller.logSelection, [3], "the same call stays selected")
        XCTAssertEqual(controller.logVisibleRows, before, "and the log stays where it was")

        controller.setFollowsForTesting(true)
        await call(41)
        _ = await awaitUntil(2) { self.service.log.count == 42 }
        controller.refresh()
        XCTAssertTrue(controller.logVisibleRows.contains(41), "following: the newest is on screen")
        XCTAssertEqual(controller.logSelection, [3], "and the selection is still the reader's")
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

    /// The keyboard lands on the list in view — when the window is shown, and
    /// on the new page's list when another page is picked.
    func testTheKeyboardIsOnThePagesList() throws {
        let controller = AgentWindowController(service: nil)
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        controller.focusList()
        XCTAssertTrue(window.firstResponder === controller.shownList)
        controller.showMarks()
        XCTAssertTrue(window.firstResponder === controller.marksList.table)
        controller.showFindings()
        XCTAssertTrue(window.firstResponder === controller.findingsList.table)
    }
}
