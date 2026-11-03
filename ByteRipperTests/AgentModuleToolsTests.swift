import AgentKit
import Localization
import UEFIImage
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
        for name in ["uefi_tree", "uefi_node", "uefi_find", "uefi_at", "uefi_dmi", "uefi_select", "uefi_selection", "open_panel"] {
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

    /// The detail names a file by the GUID catalogue, as the panel's does.
    func testTheNodeIsNamedByTheGUIDCatalogueAsInThePanel() async throws {
        try open(UEFITestImage.make())
        let id = try await driverID()
        let plain = try await client.answer("uefi_node", ["node": .string(id)])
        let guid = try XCTUnwrap(plain["node"]?["guid"]?.stringValue)
        let held = UEFIToolSession.guidsSource
        defer { UEFIToolSession.guidsSource = held }
        UEFIToolSession.guidsSource = FixedGuids(catalogue: GuidsCatalogue(names: [try XCTUnwrap(EFIGUID(guid)): "CatalogueDriver"]))
        let node = try await client.answer("uefi_node", ["node": .string(id)])
        let field = node["fields"]?.arrayValue?.first { $0["label"] == "Name in the catalogue" }
        XCTAssertEqual(field?["value"], "CatalogueDriver", "\(node)")
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
        let node = try await withAppLanguage(.russian) {
            try await client.answer("uefi_node", ["node": .string(id)])
        }
        let labels = node["fields"]?.arrayValue?.compactMap { $0["label"]?.stringValue } ?? []
        XCTAssertTrue(labels.contains("Kind"), "English labels: \(labels)")
    }

    /// The window speaks Russian, and no word of it reaches the agent: the
    /// whole tree of each image walked, every node's fields, the checksums,
    /// the variables, the areas, a search, the annotations, the FIT table and
    /// the ME firmware — in English.
    /// The language is never switched for a call; a word the answer borrows
    /// from a panel is asked for in English where it is made.
    func testNoAnswerSpeaksTheWindowsLanguage() async throws {
        try await withAppLanguage(.russian) {
            XCTAssertEqual(L("Free space"), "Свободное место", "the window speaks Russian")
            var asked = 0
            for bytes in [UEFITestImage.make(), LenovoTestImage.make(),
                          try CompressedTestImage.make(holding: "SECRET-MODEL-GH51G"),
                          FITTestImage.make(checksum: 0x42, brokenMicrocodeRows: 2),
                          METestImage.fptFile(),
                          NvramTestImage.vss([.init("Setup", [1, 1]), .init("Lang", [0x65])])] {
                try open(bytes)
                var answers: [(String, JSONValue)] = []
                func ask(_ tool: String, _ arguments: [String: JSONValue] = [:]) async throws {
                    let call = try await client.call(tool, .object(arguments))
                    answers.append(("\(tool) \(arguments)", call.answer))
                    asked += 1
                }
                var queue: [String?] = [nil]
                var seen: Set<String> = []
                while let next = queue.first, seen.count < 300 {
                    queue.removeFirst()
                    let tree = try await client.call("uefi_tree", .object(next.map { ["node": .string($0)] } ?? [:]))
                    answers.append(("uefi_tree \(next ?? "top")", tree.answer))
                    for child in tree.answer["children"]?.arrayValue ?? [] {
                        guard let id = child["id"]?.stringValue, seen.insert(id).inserted else { continue }
                        try await ask("uefi_node", ["node": .string(id)])
                        if child["children"] != nil { queue.append(id) }
                    }
                }
                try await ask("uefi_at", ["offset": "0x28"])
                try await ask("uefi_checksums")
                try await ask("variables")
                try await ask("region_scan")
                try await ask("uefi_dmi")
                try await ask("find_bytes", ["text": "MODEL", "node": "root"])
                try await ask("annotate", ["offset": "0x28", "length": 4, "title": "Signature"])
                try await ask("annotations")
                try await ask("fit_table")
                try await ask("fit_table", ["entry": 1])
                try await ask("me_summary")
                try await ask("me_tree")
                for (question, answer) in answers {
                    let text = answer.jsonText
                    XCTAssertNil(text.range(of: "\\p{Cyrillic}", options: .regularExpression),
                                 "\(question) answered in the window's language: \(text.prefix(400))")
                }
                controller?.windowModel.pane1.close()
                service.annotationTools.remove { _ in true }
            }
            XCTAssertGreaterThan(asked, 30, "the walk asked enough to mean something")
        }
    }

    /// The DMI area is answered where the panel's DMI button finds it, with
    /// what the panel says about it.
    func testTheDMIAreaIsTheStoreTheDMIButtonFinds() async throws {
        try open(LenovoTestImage.make())
        let answer = try await client.answer("uefi_dmi")
        XCTAssertEqual(answer["total"], 1, "\(answer)")
        let area = try XCTUnwrap(answer["areas"]?.arrayValue?.first)
        XCTAssertEqual(area["layout"], "Lenovo DMI store")
        XCTAssertEqual(area["start"], "0x1000", "where LenovoTestImage lays its log")
        XCTAssertEqual(area["size"], "0x4000")
        XCTAssertFalse(area["fields"]?.arrayValue?.isEmpty ?? true, "the panel's detail comes with it")
        let id = try XCTUnwrap(area["id"]?.stringValue)
        let node = try await client.answer("uefi_node", ["node": .string(id)])
        XCTAssertEqual(node["node"]?["start"], "0x1000", "the id is the tree's")
        XCTAssertEqual(node["node"]?["end"], "0x5000")
    }

    /// A dump the parser finds no DMI area in is not said to have none: the
    /// answer and the tool's description both say the search knows only some
    /// layouts.
    func testNoDMIAreaFoundIsNotNoDMIArea() async throws {
        try open(UEFITestImage.make())
        let answer = try await client.answer("uefi_dmi")
        XCTAssertEqual(answer["total"], 0)
        XCTAssertEqual(answer["areas"], .array([]))
        let note = try XCTUnwrap(answer["note"]?.stringValue)
        XCTAssertTrue(note.contains("is not therefore absent from the dump"), note)
        let tool = try XCTUnwrap(service.server.tools.first { $0.name == "uefi_dmi" })
        XCTAssertTrue(tool.description.contains("is not therefore absent from the dump"), tool.description)
        XCTAssertTrue(tool.description.contains("never that the dump has no DMI"), tool.description)
    }

    // MARK: - Actions, and opening the panel

    func testAnActionWithThePanelClosedNamesOpenPanel() async throws {
        try open(UEFITestImage.make())
        let id = try await driverID()
        let refused = try await client.call("uefi_select", ["node": .string(id)])
        XCTAssertTrue(refused.isError)
        let name = try XCTUnwrap(controller?.windowModel.pane1.status.fileName)
        let expected = "The UEFI Structure panel is not open on \(name) (d1). "
            + #"Call `open_panel` with module "uefi-structure" first, or show the bytes with `reveal`."#
        XCTAssertEqual(refused.answer, .string(expected))
    }

    /// The whole of "find it and show it to me": open the panel, choose the
    /// node, read the choice back — and Back undoes it.
    /// A node is named to the person by its label — the name, with its
    /// addresses where the name is only a kind — and carries a link that
    /// opens it, never its id alone.
    func testANodeIsNamedByItsLabelAndLinked() async throws {
        let controller = try open(UEFITestImage.withTrailingPadding())
        let id = try await driverID()
        let node = try await client.answer("uefi_node", ["node": .string(id)])
        XCTAssertEqual(node["node"]?["label"], "MyDriver")
        let path = try XCTUnwrap(controller.windowModel.pane1.document?.url.path)
        let link = try XCTUnwrap(node["node"]?["link"]?.stringValue, "\(node)")
        XCTAssertTrue(link.hasPrefix("[MyDriver](byteripper://node?"), link)
        let url = try XCTUnwrap(URL(string: String(link.dropFirst("[MyDriver](".count).dropLast())))
        let parsed = try XCTUnwrap(AgentNodeURLs.parse(url))
        XCTAssertEqual(parsed.file.path, path)
        XCTAssertEqual(parsed.node, id)

        let found = try await client.answer("uefi_find", ["type": "Padding"])
        let padding = try XCTUnwrap(found["matches"]?.arrayValue?.first, "\(found)")
        XCTAssertEqual(padding["label"], .string("\(padding["name"]?.stringValue ?? ""), "
                       + "\(padding["start"]?.stringValue ?? "")–\(padding["end"]?.stringValue ?? "")"),
                       "a name that is only a kind gets its addresses")
    }

    func testANodeLinkIsOursOnlyWithAFileAndANodeID() {
        XCTAssertNil(AgentNodeURLs.parse(URL(string: "byteripper://node?file=/a.bin&id=x.1")!))
        XCTAssertNil(AgentNodeURLs.parse(URL(string: "byteripper://node?id=0.1")!))
        XCTAssertNil(AgentNodeURLs.parse(URL(string: "https://node?file=/a.bin&id=0.1")!))
        let url = AgentNodeURLs.url(file: URL(fileURLWithPath: "/tmp/a b[1].bin"), node: "0.2.5")!
        XCTAssertEqual(AgentNodeURLs.parse(url)?.file.path, "/tmp/a b[1].bin")
        XCTAssertEqual(AgentNodeURLs.parse(url)?.node, "0.2.5")
    }

    /// A click on a node link opens the UEFI Structure panel on the file and
    /// chooses the node.
    func testOpeningANodeLinkChoosesTheNodeInThePanel() async throws {
        let controller = try open(UEFITestImage.make())
        let id = try await driverID()
        let file = try XCTUnwrap(controller.windowModel.pane1.document?.url)
        await service.openNode(file: file, id: id)
        XCTAssertEqual(controller.tools.activeIdentifier, UEFIToolModule.identifier)
        let chosen = try await client.answer("uefi_selection")
        XCTAssertEqual(chosen["selected"]?["name"], "MyDriver")
    }

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

/// A GUID catalogue that is just this list, so a test does not reach GitHub.
private struct FixedGuids: GuidsSource {
    let catalogue: GuidsCatalogue
    func guids() async throws -> GuidsCatalogue { catalogue }
}
