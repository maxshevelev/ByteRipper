import AgentKit
import ByteRipperCore
import CodeAnalysis
import CodeView
import HTTPService
import XCTest
import UEFIImage
@testable import UEFIToolUI
@testable import ByteRipper

/// A module's code as an agent reaches it: listed, read and shown without the
/// person opening a Code panel first, and annotated so that the note opens the
/// code, not the bytes (`Design/CODE_PANEL_PLAN.md`).
@MainActor
final class CodeAgentTests: XCTestCase {
    private var controller: MainViewController?
    private var window: NSWindow?
    private var service: AgentService!
    private var client: AgentTestClient!
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var previousRoot: URL?
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        let desk = AgentDesk(controllers: { [weak self] in self?.controller.map { [$0] } ?? [] },
                             keyController: { [weak self] in self?.controller })
        service = AgentService(desk: desk, defaults: defaults,
                               socketPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        client = AgentTestClient(service)

        root = FileManager.default.temporaryDirectory.appendingPathComponent("CodeAgent-\(UUID().uuidString)")
        let store = try ContentStore(root: root)
        let module = Self.teModule()
        try store.putAnalysis(
            module: ModuleIdentity(sha256: SHA256Digest(data: module), size: module.count, name: "CpuPei",
                                   kind: "TE", language: "x86:LE:32:default", imageBase: "0x0"),
            recipe: AnalysisRecipe(id: "code-v4-ghidra-12.1.2", exporter: 4, ghidra: "12.1.2",
                                   script: "ExportCode.java"),
            artifact: Data(Self.artifact.utf8))
        previousRoot = UEFIToolModule.codeAnalysisRoot
        UEFIToolModule.codeAnalysisRoot = root
    }

    override func tearDown() async throws {
        NotesWindowController.discardForTesting()
        controller?.windowModel.pane1.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        UEFIToolModule.codeAnalysisRoot = previousRoot
        try? FileManager.default.removeItem(at: root)
        discardIsolatedDefaults(defaultsName, defaults)
        client = nil
        service = nil
        try await super.tearDown()
    }

    @discardableResult
    private func open() throws -> MainViewController {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        try controller.windowModel.pane1.open(url: tempFile(Self.image(), "code-agent"))
        controller.apply(mode: .singleFile)
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        return controller
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<300 where !done() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The image node `code_modules` finds the module at.
    private func moduleNode() async throws -> String {
        let answer = try await client.answer("code_modules")
        let modules = try XCTUnwrap(answer["modules"]?.arrayValue)
        XCTAssertEqual(modules.count, 1)
        XCTAssertEqual(modules.first?["module"]?.stringValue, "CpuPei")
        XCTAssertEqual(modules.first?["recipes"]?.arrayValue?.first?.stringValue, "code-v4-ghidra-12.1.2")
        return try XCTUnwrap(modules.first?["node"]?.stringValue)
    }

    // MARK: - Ghidra on the analysis server

    /// `ghidra_open` sends a node's image to the server Settings name; with
    /// the analyses on this Mac, a Ghidra tool says where to set a server.
    func testGhidraOpenSendsTheNodesImageToTheAnalysisServer() async throws {
        try open()
        let node = try await moduleNode()
        for key in ["CodeAnalysisLocation", "CodeAnalysisServer"] { AppDefaults.store.removeObject(forKey: key) }
        let refused = try await client.call("ghidra_modules")
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("Settings ▸ Code Analysis") == true, "\(refused.answer)")

        final class Received: @unchecked Sendable { var body = Data(); var query: [String: String] = [:] }
        let received = Received()
        var router = HTTPRouter()
        router.add("POST", "/ghidra/v1/modules") { request in
            received.body = request.body
            received.query = request.query
            return .json(["module": SHA256Digest(data: request.body).hex, "functions": "2"])
        }
        let server = HTTPServer(configuration: .init(port: 0), router: router)
        let port = try await server.start()
        defer { server.stop() }
        AppDefaults.store.set("server", forKey: "CodeAnalysisLocation")
        AppDefaults.store.set("http://127.0.0.1:\(port)", forKey: "CodeAnalysisServer")
        defer { for key in ["CodeAnalysisLocation", "CodeAnalysisServer"] { AppDefaults.store.removeObject(forKey: key) } }

        let opened = try await client.answer("ghidra_open", ["node": .string(node)])
        XCTAssertEqual(received.body, Self.teModule(), "the node's image is what went to the server")
        XCTAssertEqual(opened["module"]?.stringValue, SHA256Digest(data: Self.teModule()).hex)
        XCTAssertEqual(received.query["node"], node)
        XCTAssertFalse((received.query["name"] ?? "").isEmpty)
    }

    // MARK: - Reading without a panel

    func testTheCodeIsReadFromTheStoreByNodeWithNoPanelOpen() async throws {
        let controller = try open()
        let node = try await moduleNode()
        XCTAssertNil(controller.fragments.expanded, "nothing was opened to answer")

        let functions = try await client.answer("code_query", ["node": .string(node)])
        XCTAssertEqual(functions["node"]?.stringValue, node)
        let rows = try XCTUnwrap(functions["functions"]?.arrayValue)
        XCTAssertEqual(rows.compactMap { $0["name"]?.stringValue }, ["FUN_00000220", "entry"])
        XCTAssertEqual(rows.first?["offset"]?.stringValue, "0x68", "the module's bytes give the offsets")

        let c = try await client.answer("code_query", ["node": .string(node), "what": "c", "function": "entry"])
        XCTAssertEqual(c["c"]?.stringValue, "void entry(void)\n{\n}\n")
        XCTAssertNil(controller.fragments.expanded)
    }

    func testTheCodeIsReadByTheModuleHashAlone() async throws {
        let sha = SHA256Digest(data: Self.teModule()).hex
        let functions = try await client.answer("code_query", ["module": .string(sha)])
        XCTAssertEqual(functions["sha256"]?.stringValue, sha)
        XCTAssertEqual(functions["functions"]?.arrayValue?.count, 2)
        XCTAssertEqual(functions["functions"]?.arrayValue?.first?["offset"], .null,
                       "no bytes, so no module offsets")

        let missing = try await client.call("code_query", ["module": .string(String(repeating: "0", count: 64))])
        XCTAssertTrue(missing.isError)
    }

    func testANodeWithNoAnalysisIsRefusedWithTheWayOn() async throws {
        try open()
        let refused = try await client.call("code_query", ["node": "0"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.answer.stringValue?.contains("code_modules") == true, "\(refused.answer)")
    }

    // MARK: - Opening the panel

    func testOpenCodeOpensThePanelAtAFunctionAndRaisesItAgain() async throws {
        let controller = try open()
        let node = try await moduleNode()
        let opened = try await client.answer("open_code", ["node": .string(node), "function": "entry"])
        let panel = try XCTUnwrap(controller.fragments.expanded)
        let pane = try XCTUnwrap(controller.fragments.codePane(panel))
        XCTAssertEqual(pane.selectedFunction?.name, "entry")
        XCTAssertEqual(opened["function"]?.stringValue, "entry")
        let document = try XCTUnwrap(opened["document"]?.stringValue)

        // The panel is a document code_query reads by its id.
        let read = try await client.answer("code_query", ["document": .string(document)])
        XCTAssertEqual(read["document"]?.stringValue, document)

        // Asked again, at another place: the same panel, moved there.
        _ = try await client.answer("open_code", ["node": .string(node), "address": "0x221"])
        XCTAssertEqual(controller.fragments.count, 1)
        XCTAssertEqual(controller.fragments.codePane(panel)?.selectedInstruction?.address, CodeAddress(0x221))
        XCTAssertEqual(controller.fragments.codePane(panel)?.selectedFunction?.name, "FUN_00000220")

        let unknown = try await client.call("open_code", ["node": .string(node), "function": "nowhere"])
        XCTAssertTrue(unknown.isError)
    }

    /// View ▸ Back and Forward (⌘[ ⌘]) walk the code's own jumps while a
    /// Code panel is in front — even with the keyboard somewhere else, as it
    /// is after a click on a link — and the tab's places after them.
    func testBackAndForwardWalkTheCodeInFront() async throws {
        let controller = try open()
        let node = try await moduleNode()
        _ = try await client.answer("open_code", ["node": .string(node), "function": "entry"])
        let panel = try XCTUnwrap(controller.fragments.expanded)
        let pane = try XCTUnwrap(controller.fragments.codePane(panel))
        pane.go(to: CodeLocation(function: CodeAddress(0x220)))
        XCTAssertEqual(pane.selectedFunction?.name, "FUN_00000220")

        controller.view.window?.makeFirstResponder(nil)
        XCTAssertTrue(controller.canNavigateBack)
        controller.navigateBack()
        XCTAssertEqual(pane.selectedFunction?.name, "entry", "back in the code, not in the dump")
        XCTAssertTrue(controller.canNavigateForward)
        controller.navigateForward()
        XCTAssertEqual(pane.selectedFunction?.name, "FUN_00000220")
    }

    // MARK: - Annotations on code

    func testAnAnnotationOnCodeOpensTheCodePanelThere() async throws {
        let controller = try open()
        let node = try await moduleNode()
        let made = try await client.answer("annotate", [
            "title": "Reads ESI", "note": "The first instruction.", "node": .string(node),
            "function": "FUN_00000220", "address": "0x221"
        ])
        XCTAssertEqual(made["code"]?["function"]?.stringValue, "FUN_00000220")
        XCTAssertEqual(made["code"]?["address"]?.stringValue, "0x221")
        XCTAssertEqual(made["node"]?.stringValue, node)
        let id = try XCTUnwrap(made["id"]?.stringValue)
        let annotation = try XCTUnwrap(service.annotationTools.all().first { $0.id == id })
        XCTAssertNotNil(annotation.range, "the module is the file's own bytes: drawn over the instruction")
        XCTAssertNil(controller.fragments.expanded)

        service.annotationTools.show(id)
        try await until { controller.fragments.expanded != nil }
        let panel = try XCTUnwrap(controller.fragments.expanded)
        let pane = try XCTUnwrap(controller.fragments.codePane(panel))
        XCTAssertEqual(pane.selectedFunction?.name, "FUN_00000220")
        XCTAssertEqual(pane.selectedInstruction?.address, CodeAddress(0x221))
        XCTAssertEqual(pane.notes.map(\.id), [id], "the panel shows the note at its place")
    }

    func testTheCardSaysTheCodePlaceWithTheCodeBadge() async throws {
        try open()
        let node = try await moduleNode()
        let made = try await client.answer("annotate", ["title": "Entry", "node": .string(node), "function": "entry"])
        let id = try XCTUnwrap(made["id"]?.stringValue)
        let texts = NotesWindowController.instance.cards.shownTexts(of: id)
        XCTAssertTrue(texts.contains { $0.hasPrefix("Code ") && $0.hasSuffix("CpuPei ▸ entry") }, "\(texts)")
    }

    func testThePersonAnnotatesCodeFromTheCodePanel() async throws {
        let controller = try open()
        let node = try await moduleNode()
        _ = try await client.answer("open_code", ["node": .string(node)])
        let panel = try XCTUnwrap(controller.fragments.expanded)
        let codePane = try XCTUnwrap(controller.fragments.pane(panel))
        let id = try await service.annotationTools.addNote(
            title: "Mine", note: "", at: CodeLocation(function: CodeAddress(0x230)), of: codePane)
        let annotation = try XCTUnwrap(service.annotationTools.all().first { $0.id == id })
        XCTAssertEqual(annotation.author, .person)
        XCTAssertEqual(annotation.code?.functionName, "entry")
        XCTAssertEqual(annotation.node, node, "found in the dump the panel was opened over")
        try await until { controller.fragments.codePane(panel)?.notes.isEmpty == false }
        XCTAssertEqual(controller.fragments.codePane(panel)?.notes.first?.title, "Mine")
    }

    /// A rename published after the note was made renames what the note is
    /// about, found by the function's address; the note's title stays the
    /// person's.
    func testACodeAnnotationNamesItsFunctionAsTheAnalysisDoesNow() async throws {
        let controller = try open()
        let node = try await moduleNode()
        _ = try await client.answer("open_code", ["node": .string(node)])
        let panel = try XCTUnwrap(controller.fragments.expanded)
        let codePane = try XCTUnwrap(controller.fragments.pane(panel))
        let id = try await service.annotationTools.addNote(
            title: "Mine", note: "", at: CodeLocation(function: CodeAddress(0x220)), of: codePane)
        func annotation() -> AgentAnnotation? { service.annotationTools.all().first { $0.id == id } }
        XCTAssertEqual(annotation()?.code?.functionName, "FUN_00000220")

        let store = try ContentStore(root: root)
        let stored = try XCTUnwrap(try store.analysis(module: SHA256Digest(data: Self.teModule())))
        try store.putAnalysis(
            module: stored.module, recipe: stored.recipe,
            artifact: Data(Self.artifact.replacingOccurrences(of: #""name":"FUN_00000220""#,
                                                              with: #""name":"LoadMicrocode""#).utf8),
            reading: AnalysisReading(project: "p", rev: 1))
        try await until { annotation()?.code?.functionName == "LoadMicrocode" }
        XCTAssertEqual(annotation()?.code?.label, "CpuPei ▸ LoadMicrocode")
        XCTAssertEqual(annotation()?.title, "Mine")
    }

    func testACodeAnnotationIsKeptBetweenLaunches() throws {
        let annotation = AgentAnnotation(
            id: "a1", file: .disk(URL(fileURLWithPath: "/tmp/x.bin"), FileIdentity(url: URL(fileURLWithPath: "/tmp"))),
            range: nil, node: "0.0.0", title: "T", note: "", relatedTo: [],
            code: AgentAnnotation.Code(module: String(repeating: "a", count: 64), moduleName: "CpuPei",
                                       function: "0x220", functionName: "FUN_00000220", address: "0x221"))
        let stored = try XCTUnwrap(AnnotationsFile.Stored(annotation))
        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode(AnnotationsFile.Stored.self, from: data)
        XCTAssertEqual(back.annotation.code, annotation.code)
        XCTAssertEqual(back.annotation.code?.location,
                       CodeLocation(function: CodeAddress(0x220), address: CodeAddress(0x221)))
    }

    // MARK: - The test module

    static let artifact = """
        {"script_version":4,"ghidra":"12.1.2","program":{"image_base":"0x0","language":"x86:LE:32:default"},
         "functions":[
          {"entry":"0x220","name":"FUN_00000220","name_source":"DEFAULT","instructions":[
            {"address":"0x220","bytes":"56","mnemonic":"PUSH","text":"PUSH ESI"},
            {"address":"0x221","bytes":"57","mnemonic":"PUSH","text":"PUSH EDI"}]},
          {"entry":"0x230","name":"entry","name_source":"IMPORTED","c":"void entry(void)\\n{\\n}\\n",
           "instructions":[{"address":"0x230","bytes":"C3","mnemonic":"RET","text":"RET"}]}]}
        """

    /// A TE image whose .text is at RVA 0x220 and module offset 0x68.
    static func teModule() -> Data {
        var data = Data(repeating: 0, count: 0x100)
        data[0] = 0x56
        data[1] = 0x5A
        put(&data, 2, 0x14C, 2)
        data[4] = 1
        data[5] = 0x0B
        put(&data, 6, 0x200, 2)
        put(&data, 8, 0x220, 4)
        put(&data, 12, 0x220, 4)
        for (index, byte) in Array(".text".utf8).enumerated() { data[40 + index] = byte }
        put(&data, 48, 0x40, 4)
        put(&data, 52, 0x220, 4)
        put(&data, 56, 0x40, 4)
        put(&data, 60, 0x240, 4)
        put(&data, 76, 0x6000_0020, 4)
        data[0x68] = 0x56
        data[0x69] = 0x57
        data[0x78] = 0xC3
        return data
    }

    /// `UEFITestImage`'s volume with its one file a PEIM holding the TE image
    /// as a TE section.
    static func image() -> [UInt8] {
        var image = UEFITestImage.make()
        let module = [UInt8](teModule())
        var file: [UInt8] = []
        file += EFIGUID(low: 0x0000_0000_0000_0003, high: 0x0000_0000_0000_0004).bytes
        file += [0, 0xAA, 0x06, 0x00]         // header/body checksum, PEIM, attributes
        let size = 0x18 + 4 + module.count
        file += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size >> 16)]
        file += [0xF8]
        let section = 4 + module.count
        file += [UInt8(section & 0xFF), UInt8((section >> 8) & 0xFF), UInt8(section >> 16), 0x12]
        file += module
        image.replaceSubrange(0x48..<(0x48 + file.count), with: file)
        return image
    }

    private static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, _ count: Int) {
        for index in 0..<count { data[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
    }
}
