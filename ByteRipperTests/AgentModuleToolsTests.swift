import AgentKit
import Localization
import UEFIToolUI
import XCTest
@testable import ByteRipper

/// What the tool-modules answer an agent, through the service, on a real
/// window (`Design/AGENT_PLAN.md`, stage 3): the UEFI Structure's questions
/// asked with its panel closed, its actions refused until `open_panel` opens
/// it, and the answers in English whatever the window speaks.
@MainActor
final class AgentModuleToolsTests: XCTestCase {
    private var controller: MainViewController?
    private var window: NSWindow?
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in self?.controller.map { [$0] } ?? [] },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        client = AgentTestClient(service)
    }

    override func tearDown() {
        controller?.tools.activate(nil, animated: false)
        controller?.windowModel.pane1.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    @discardableResult
    private func open(_ bytes: [UInt8]) throws -> MainViewController {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        try controller.windowModel.pane1.open(url: tempFile(bytes, "agent-uefi"))
        controller.apply(mode: .singleFile)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        return controller
    }

    /// The driver's id, found the way an agent finds it.
    private func driverID() async throws -> String {
        let found = try await client.answer("uefi_find", ["name": "MyDriver", "exact": true, "type": "File"])
        let id = try XCTUnwrap(found["matches"]?.arrayValue?.first?["id"]?.stringValue, "\(found)")
        return id
    }

    // MARK: - The list

    func testEveryModuleToolIsListedWithADocumentArgument() {
        let names = service.server.tools.map(\.name)
        for name in ["uefi_tree", "uefi_node", "uefi_find", "uefi_at", "uefi_select", "uefi_selection", "open_panel"] {
            XCTAssertTrue(names.contains(name), "\(name) in \(names)")
        }
        for tool in service.server.tools where tool.name.hasPrefix("uefi_") {
            XCTAssertNotNil(tool.inputSchema["properties"]?["document"], tool.name)
        }
        let select = service.server.tools.first { $0.name == "uefi_select" }
        XCTAssertEqual(select?.annotations.readOnly, false, "it changes what is on screen")
    }

    // MARK: - Questions, with the panel closed

    func testTheTreeIsReadWithThePanelClosed() async throws {
        let controller = try open(UEFITestImage.make())
        XCTAssertNil(controller.tools.session, "no panel open")
        let top = try await client.answer("uefi_tree", ["depth": 3])
        XCTAssertEqual(top["document"], "d1")
        XCTAssertTrue(top.jsonText.contains(#""name":"MyDriver""#), top.jsonText)
        XCTAssertNil(controller.tools.session, "a question does not open the panel")
    }

    func testFindNodeAndAtAgreeOnTheDriver() async throws {
        try open(UEFITestImage.make())
        let id = try await driverID()

        let node = try await client.answer("uefi_node", ["node": .string(id)])
        XCTAssertEqual(node["node"]?["name"], "MyDriver")
        XCTAssertEqual(node["node"]?["start"], "0x48")
        XCTAssertEqual(node["path"]?.arrayValue?.last, "MyDriver")
        let labels = node["fields"]?.arrayValue?.compactMap { $0["label"]?.stringValue } ?? []
        XCTAssertTrue(labels.contains("GUID"), "\(labels)")

        let chain = try await client.answer("uefi_at", ["offset": "0x60"])["chain"]?.arrayValue ?? []
        XCTAssertTrue(chain.contains { $0["id"]?.stringValue == id }, "the driver holds 0x60: \(chain)")
        XCTAssertEqual(chain.first?["start"], "0x0", "outermost first")
    }

    func testABadNodeIdSaysWhereIdsComeFrom() async throws {
        try open(UEFITestImage.make())
        let refused = try await client.call("uefi_node", ["node": "volume"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("uefi_tree") == true, "\(refused.answer)")
        let missing = try await client.call("uefi_node", ["node": "9.9.9"])
        XCTAssertTrue(missing.answer.stringValue?.hasPrefix("No node 9.9.9") == true, "\(missing.answer)")
    }

    /// The window may speak Russian; the agent is answered in English.
    func testAnswersAreInEnglishWhateverTheWindowSpeaks() async throws {
        try open(UEFITestImage.make())
        let id = try await driverID()
        let node = try await Localization.$override.withValue(.russian) {
            try await client.answer("uefi_node", ["node": .string(id)])
        }
        let labels = node["fields"]?.arrayValue?.compactMap { $0["label"]?.stringValue } ?? []
        XCTAssertTrue(labels.contains("Kind"), "English labels: \(labels)")
    }

    // MARK: - Actions, and opening the panel

    func testAnActionWithThePanelClosedNamesOpenPanel() async throws {
        try open(UEFITestImage.make())
        let id = try await driverID()
        let refused = try await client.call("uefi_select", ["node": .string(id)])
        XCTAssertTrue(refused.isError)
        let expected = "The UEFI Structure panel is not open on d1. "
            + #"Call `open_panel` with module "uefi-structure" first, or show the bytes with `reveal`."#
        XCTAssertEqual(refused.answer, .string(expected))
    }

    /// The whole of "find it and show it to me": open the panel, choose the
    /// node, read the choice back — and Back undoes it.
    func testOpenPanelThenSelectChoosesTheNodeAndBackReturns() async throws {
        let controller = try open(UEFITestImage.make())
        let id = try await driverID()

        let opened = try await client.answer("open_panel", ["module": "uefi-structure"])
        XCTAssertEqual(opened["was_open"], false)
        XCTAssertEqual(controller.tools.activeIdentifier, UEFIToolModule.identifier)
        let again = try await client.answer("open_panel", ["module": "uefi-structure"])
        XCTAssertEqual(again["was_open"], true)

        let selected = try await client.answer("uefi_select", ["node": .string(id)])
        XCTAssertEqual(selected["selected"]?["id"]?.stringValue, id)
        let chosen = try await client.answer("uefi_selection")
        XCTAssertEqual(chosen["selected"]?["name"], "MyDriver")
        XCTAssertTrue(controller.canNavigateBack, "the agent's choice is a step the reader can undo")
    }

    func testAnUnknownModuleIsRefusedWithTheOnesThereAre() async throws {
        try open(UEFITestImage.make())
        let refused = try await client.call("open_panel", ["module": "nope"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("uefi-structure") == true, "\(refused.answer)")
    }
}
