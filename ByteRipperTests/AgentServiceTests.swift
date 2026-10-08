import AgentKit
import ByteRipperCore
import XCTest
@testable import ByteRipper

/// What the agent service answers about a real window (`Design/AGENT_PLAN.md`,
/// stage 2): the host's own tools, driven as a client drives them — lines of
/// JSON in, lines out — through a connection in memory, and once through the
/// real socket.
@MainActor
final class AgentServiceTests: XCTestCase {
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
        service.stop()
        controller?.windowModel.pane1.close()
        controller?.windowModel.pane2.close()
        window?.orderOut(nil)
        window = nil
        controller = nil
        discardIsolatedDefaults(defaultsName, defaults)
        super.tearDown()
    }

    // MARK: - A window with files in it

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }
    }

    @discardableResult
    private func open(_ first: [UInt8], _ second: [UInt8]? = nil) throws -> MainViewController {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        try controller.windowModel.pane1.open(url: tempFile(first, "agent-a"))
        if let second {
            try controller.windowModel.pane2.open(url: tempFile(second, "agent-b"))
            controller.apply(mode: .comparison)
        } else {
            controller.apply(mode: .singleFile)
        }
        settle(window)
        return controller
    }

    private static let image: [UInt8] = Array("MZ firmware".utf8) + [UInt8](repeating: 0, count: 5)
        + (0..<0x2000).map { UInt8(truncatingIfNeeded: $0) }

    // MARK: - Talking to the service

    private func call(_ tool: String, _ arguments: JSONValue = .object([:]),
                      file: StaticString = #filePath, line: UInt = #line) async throws
    -> (answer: JSONValue, isError: Bool) {
        try await client.call(tool, arguments, file: file, line: line)
    }

    private func answer(_ tool: String, _ arguments: JSONValue = .object([:]),
                        file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        try await client.answer(tool, arguments, file: file, line: line)
    }

    // MARK: - The tools

    func testTheToolsAreListedInAFixedOrder() {
        let host = Array(service.server.tools.prefix(4))
        XCTAssertEqual(host.map(\.name), ["documents", "focus", "read", "reveal"])
        XCTAssertEqual(host.map(\.annotations.readOnly), [true, true, true, false])
    }

    func testDocumentsNamesBothFilesOfAComparisonTheFocusedOneFirst() async throws {
        let controller = try open(Self.image, [1, 2, 3])
        let listing = try await answer("documents")
        let documents = try XCTUnwrap(listing["documents"]?.arrayValue)
        XCTAssertEqual(documents.map { $0["slot"] }, ["A", "B"])
        XCTAssertEqual(documents.map { $0["id"] }, ["d1", "d2"])
        XCTAssertEqual(documents[0]["focused"], true)
        XCTAssertNil(documents[1]["focused"])
        XCTAssertEqual(documents[0]["size"], "0x2010")
        XCTAssertEqual(documents[1]["size"], "0x3")
        XCTAssertEqual(documents[0]["unsaved_edits"], false)
        XCTAssertEqual(documents[0]["path"]?.stringValue,
                       controller.windowModel.pane1.document?.url.path)
    }

    /// An id is the document's for as long as it is open; another file opened
    /// into the same pane is another document.
    func testAnIdStaysWithItsDocumentAndANewFileGetsANewOne() async throws {
        let controller = try open(Self.image)
        let value1 = try await answer("focus")["document"]
        XCTAssertEqual(value1, "d1")
        let value2 = try await answer("focus")["document"]
        XCTAssertEqual(value2, "d1")
        try controller.windowModel.pane1.open(url: tempFile([9, 9, 9], "agent-c"))
        let value3 = try await answer("focus")["document"]
        XCTAssertEqual(value3, "d2")
    }

    func testFocusReportsTheCaretTheSelectionAndWhatIsOnScreen() async throws {
        let controller = try open(Self.image, [1, 2, 3])
        let pane = controller.windowModel.pane1
        pane.moveCaret(to: 0x40, center: false)
        var focus = try await answer("focus")
        XCTAssertEqual(focus["caret"], "0x40")
        XCTAssertEqual(focus["selection"], .null)
        XCTAssertEqual(focus["compared_with"], "d2")
        XCTAssertEqual(focus["on_screen"]?["start"], "0x0")

        pane.select(range: 0x10..<0x20)
        focus = try await answer("focus")
        XCTAssertEqual(focus["selection"], ["start": "0x10", "end": "0x20", "length": "0x10"])
    }

    func testReadGivesRowsAsTheDumpDrawsThem() async throws {
        try open(Self.image)
        let read = try await answer("read", ["offset": "0x0", "length": 20])
        XCTAssertEqual(read["rows"], [
            "00000000  4D 5A 20 66 69 72 6D 77 61 72 65 00 00 00 00 00  |MZ firmware.....|",
            "00000010  00 01 02 03                                      |....|"
        ])
        XCTAssertEqual(read["length"], "0x14")
    }

    func testReadInTheOtherFormats() async throws {
        try open(Self.image)
        let value4 = try await answer("read", ["offset": 0, "length": 11, "format": "ascii"])["text"]
        XCTAssertEqual(value4,
                       "MZ firmware")
        let value5 = try await answer("read", ["offset": "0x10", "length": 8, "format": "u32"])["values"]
        XCTAssertEqual(value5,
                       ["0x03020100", "0x07060504"])
        let value6 = try await answer("read", ["offset": "0x10", "length": 4, "format": "u16",
                                                 "endian": "big"])["values"]
        XCTAssertEqual(value6,
                       ["0x0001", "0x0203"])
        let value7 = try await answer("read", ["offset": 0, "length": 4, "format": "utf16le"])["text"]
        XCTAssertEqual(value7,
                       "\u{5A4D}\u{6620}")
    }

    /// Unsaved edits are what the dump shows, so they are what is read.
    func testReadSeesUnsavedEdits() async throws {
        let controller = try open(Self.image)
        try controller.windowModel.pane1.applyToolWrites([(offset: 0, bytes: [0xEE])], named: "Test")
        let value8 = try await answer("read", ["offset": 0, "length": 1, "format": "u8"])["values"]
        XCTAssertEqual(value8, ["0xEE"])
        let documents = try await answer("documents")["documents"]?.arrayValue
        XCTAssertEqual(documents?.first?["unsaved_edits"], true)
    }

    func testAReadPastTheEndIsCutThereAndOneStartingPastItIsRefused() async throws {
        try open([1, 2, 3, 4])
        let cut = try await answer("read", ["offset": 2, "length": 16, "format": "u8"])
        XCTAssertEqual(cut["values"], ["0x03", "0x04"])
        XCTAssertEqual(cut["cut_at_end_of_file"], true)

        let refused = try await call("read", ["offset": "0x10"])
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(refused.answer, "Offset 0x10 is past the end of d1, which is 0x4 bytes long.")
        let value9 = try await call("read", ["offset": 0, "length": 5000]).isError
        XCTAssertTrue(value9)
    }

    func testAnUnknownDocumentIsRefusedWithWhereToLook() async throws {
        try open(Self.image)
        let refused = try await call("read", ["document": "d9", "offset": 0])
        XCTAssertEqual(refused.answer,
                       "No open document has the id d9. Call `documents` for the ones that are open.")
    }

    func testWithNothingOpenTheToolsSaySo() async throws {
        let value10 = try await call("focus").answer
        XCTAssertEqual(value10, "No file is open in ByteRipper.")
    }

    /// The agent points; the reader's Back undoes it.
    func testRevealSelectsThePlaceAndBackReturnsToWhereTheReaderWas() async throws {
        let controller = try open([UInt8](repeating: 0x11, count: 0x10000))
        let pane = controller.windowModel.pane1
        pane.moveCaret(to: 0x40, center: false)

        let shown = try await answer("reveal", ["offset": "0x8000", "length": "0x10"])
        XCTAssertEqual(shown["selected"], true)
        XCTAssertEqual(shown["shown"]?["end"], "0x8010")
        let selection = pane.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x8000..<0x8010)
        let onScreen = try XCTUnwrap(controller.filePaneView(for: pane)).visibleOffsets
        XCTAssertTrue(onScreen.contains(0x8000), "the place is on screen: \(onScreen)")

        XCTAssertTrue(controller.canNavigateBack)
        controller.navigateBack()
        XCTAssertEqual(pane.caretOffset, 0x40)
    }

    func testRevealWithoutALengthMovesTheCaretOnly() async throws {
        let controller = try open(Self.image)
        let shown = try await answer("reveal", ["offset": "0x100"])
        XCTAssertEqual(shown["selected"], false)
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, 0x100)
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty)
    }

    func testTheLogHearsEveryCall() async throws {
        try open(Self.image)
        _ = try await call("focus")
        _ = try await call("read", ["offset": "0x99999"])
        let settled = await awaitUntil(1) { self.service.log.count == 2 }
        XCTAssertTrue(settled)
        XCTAssertEqual(service.log.map(\.tool), ["focus", "read"])
        XCTAssertEqual(service.log.first?.outcome, .answered)
        if case .toolError = service.log.last?.outcome {} else { XCTFail("a refusal is logged as one") }
    }

    // MARK: - The socket

    /// The whole way a client comes: the switch, the socket, a handshake and a
    /// call, and the socket gone again when the switch is turned off.
    func testAClientReachesTheServiceThroughTheSocket() async throws {
        try open(Self.image)
        XCTAssertFalse(service.isRunning, "off until switched on")
        service.isEnabled = true
        XCTAssertTrue(service.isRunning, service.failure ?? "")
        defer { service.isEnabled = false }

        let fd = try UnixSocket.connect(to: service.socketPath)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let lines = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"socket-test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"focus","arguments":{}}}"#
        ]
        XCTAssertTrue(UnixSocket.writeAll(fd, Data((lines.joined(separator: "\n") + "\n").utf8)))

        // The socket's reads run on threads and the tool on this actor: read
        // off it, and let the main run loop turn while waiting.
        let received = ReceivedLines()
        Thread.detachNewThread {
            while let chunk = UnixSocket.readSome(fd) { received.append(chunk) }
        }
        let answered = await awaitUntil(3) { received.lines.count >= 2 }
        XCTAssertTrue(answered, "got \(received.lines)")
        let replies = try received.lines.map { try JSONValue.parse(Data($0.utf8)) }
        XCTAssertEqual(replies.first?["result"]?["serverInfo"]?["name"], "byteripper")
        let focus = try XCTUnwrap(replies.last?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(focus.contains(#""document":"d1""#), focus)
        let counted = await awaitUntil(1) { self.service.connectionCount == 1 }
        XCTAssertTrue(counted)

        service.isEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.socketPath))
    }
}

/// Lines read off a socket on another thread.
private final class ReceivedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) { lock.withLock { buffer.append(data) } }

    var lines: [String] {
        lock.withLock {
            String(decoding: buffer, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }
}
