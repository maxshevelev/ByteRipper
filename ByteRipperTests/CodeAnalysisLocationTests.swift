import CASService
import CodeAnalysis
import HTTPService
import Localization
import UEFIToolUI
import XCTest
@testable import ByteRipper

/// The app reading its code analyses from a served store: the setting points
/// the store root at a mirror, the mirror follows the server, a project's
/// bundle goes to the server, and switching back reads this Mac again.
@MainActor
final class CodeAnalysisLocationTests: XCTestCase {
    private var directory: URL!
    private var served: ContentStore!
    private var service: CASService!
    private var server: HTTPServer!
    private var address = ""
    private var location: CodeAnalysisLocation!
    private var previousRoot: URL?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeAnalysisLocationTests-\(UUID().uuidString)", isDirectory: true)
        served = try ContentStore(root: directory.appendingPathComponent("served"))
        service = try CASService(store: served)
        server = HTTPServer(configuration: .init(port: 0, token: "secret"), router: service.routes())
        address = "http://127.0.0.1:\(try await server.start())"
        location = CodeAnalysisLocation(localRoot: directory.appendingPathComponent("local"),
                                        mirrorsRoot: directory.appendingPathComponent("mirrors"),
                                        tokenFile: directory.appendingPathComponent("Server/token"))
        previousRoot = UEFIToolModule.codeAnalysisRoot
    }

    override func tearDown() async throws {
        try? location?.choose(.thisMac, server: "", token: nil)
        for key in ["CodeAnalysisLocation", "CodeAnalysisServer", "CodeAnalysisServerStore"] {
            AppDefaults.store.removeObject(forKey: key)
        }
        UEFIToolModule.codeAnalysisRoot = previousRoot
        server?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func artifact(_ functions: Int) -> Data {
        let functions = (0..<functions).map { index in
            ["entry": String(format: "0x%X", index), "name": "FUN_\(index)",
             "instructions": [["address": String(format: "0x%X", index), "text": "RET"]]] as [String: Any]
        }
        let document: [String: Any] = ["script_version": 4, "ghidra": "12.1.2", "functions": functions,
                                       "strings": [], "post_codes": [], "status_code_calls": []]
        return try! JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
    }

    private func module(_ label: String) -> ModuleIdentity {
        let data = Data(label.utf8)
        return ModuleIdentity(sha256: SHA256Digest(data: data), size: data.count, name: label, kind: "TE",
                              language: "x86:LE:32:default", imageBase: "0x0")
    }

    private let recipe = AnalysisRecipe(id: "code-v4-ghidra-12.1.2", exporter: 4, ghidra: "12.1.2",
                                        script: "ExportCode.java")

    /// Waits on the main actor, so the location's own tasks run meanwhile.
    private func wait(_ what: String, timeout: TimeInterval = 10,
                      until condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testOnAServerTheAppReadsTheMirrorAndFollowsTheServer() async throws {
        try served.putAnalysis(module: module("first"), recipe: recipe, artifact: artifact(1))
        var rootChanges = 0
        let observer = NotificationCenter.default.addObserver(
            forName: CodeAnalysisPaths.rootDidChange, object: nil, queue: .main) { _ in rootChanges += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        try location.choose(.server, server: address, token: "secret")
        try await wait("the connection") { location.state == .connected(store: try served.identity()) }
        let mirrorRoot = StoreMirror.root(of: try served.identity(), in: directory.appendingPathComponent("mirrors"))
        XCTAssertEqual(UEFIToolModule.codeAnalysisRoot, mirrorRoot)
        XCTAssertGreaterThan(rootChanges, 0)
        XCTAssertEqual(try location.readToken(), "secret")

        // What any reader opens by the root fetches the objects it lacks.
        let store = try ContentStore(root: mirrorRoot, create: false)
        let first = try XCTUnwrap(store.analysis(module: module("first").sha256))
        let code = try await Task.detached { try ContentStore(root: mirrorRoot, create: false).artifact(for: first) }.value
        XCTAssertEqual(code.functions.count, 1)

        // A module stored on the server later reaches the mirror by itself.
        // Written straight into the served directory, as byteripper-cas on the
        // server would; the server's FSEvents stream would find it, and the
        // test, which runs none, asks the feed to look.
        try served.putAnalysis(module: module("second"), recipe: recipe, artifact: artifact(2))
        await service.feed.rescan()
        try await wait("the second module") { try store.analysis(module: module("second").sha256) != nil }

        try location.choose(.thisMac, server: address, token: nil)
        XCTAssertEqual(location.state, .local)
        XCTAssertEqual(UEFIToolModule.codeAnalysisRoot, directory.appendingPathComponent("local"))
    }

    func testAProjectsBundleGoesToTheServerAndTheReportIsTheServers() async throws {
        let local = try ContentStore(root: directory.appendingPathComponent("bundle-source"))
        try local.putAnalysis(module: module("carried"), recipe: recipe, artifact: artifact(3))
        let bundle = directory.appendingPathComponent("Analyses.bundle")
        try local.exportBundle([AnalysisKey(module: module("carried").sha256, recipe: recipe.id)!], to: bundle)

        try location.choose(.server, server: address, token: "secret")
        try await wait("the connection") { location.remote != nil && location.state != .connecting }
        let report = try await location.sendBundle(at: bundle)
        XCTAssertEqual(report?.imported.count, 1)
        XCTAssertNotNil(try served.analysis(module: module("carried").sha256))
        let mirror = try ContentStore(root: XCTUnwrap(UEFIToolModule.codeAnalysisRoot), create: false)
        XCTAssertNotNil(try mirror.analysis(module: module("carried").sha256))
    }

    /// A token the server refuses is not a server out of reach: the line says
    /// the token is refused, and the analyses already read stay readable
    /// (`Design/SERVER_HEADLESS_PLAN.md` decision 4).
    func testAWrongTokenSaysSoAndKeepsTryingWithoutTheLocalStore() async throws {
        try location.choose(.server, server: address, token: "wrong")
        await wait("the refusal") { if case .refused = location.state { return true } else { return false } }
        XCTAssertEqual(location.state, .refused(reason: L("The server does not accept the token.")))
        XCTAssertNotEqual(UEFIToolModule.codeAnalysisRoot, directory.appendingPathComponent("local"))
        XCTAssertThrowsError(try location.choose(.server, server: "not an address", token: nil))
    }

    /// No anonymous mode, loopback included (decision 3): the app reaches
    /// the server on this Mac with its token, and a Mac that keeps none is
    /// told so instead of being told its token is wrong.
    func testOnLoopbackTheAppSendsItsTokenAndSaysWhenItHasNone() async throws {
        try location.choose(.server, server: address, token: nil)
        XCTAssertEqual(location.state, .refused(reason: L(
            "This Mac keeps no token for the server: enter the one made on the server by byteripper-server token add.")))

        try location.choose(.server, server: address, token: "secret")
        await wait("the connection") { if case .connected = location.state { return true } else { return false } }
    }

    /// The line under the fields wraps: an unreachable server's line carries
    /// the system's words and the address, longer than the tab is wide.
    func testTheStatusLineWrapsRatherThanCuttingOff() async throws {
        try location.choose(.server, server: "http://127.0.0.1:1", token: "secret")
        await wait("the failure") { if case .unreachable = location.state { return true } else { return false } }
        let settings = CodeAnalysisSettingsViewController()
        settings.location = location
        let window = NSWindow(contentViewController: settings)
        defer { window.close() }
        settings.refresh()
        settings.view.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(Self.labels(in: settings.view).first {
            $0.stringValue.hasPrefix(L("The server cannot be reached; what this Mac has read is shown. %1$@", ""))
        })
        let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width,
                                                            height: .greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(needed, label.font!.pointSize * 2, "the line is longer than the tab: \(label.stringValue)")
        XCTAssertGreaterThanOrEqual(label.frame.height + 1, needed, "the label is as tall as its lines")
    }

    private static func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] + labels(in: $0) }
    }

    /// A 403 names the rights the token lacks, in the tab's words and in the
    /// send button's line.
    func testAMissingRightIsNamed() {
        let refusal = RemoteStore.Failure.refused(status: 403, message: "this token has no cas.write right",
                                                  rights: ["cas.write"])
        XCTAssertEqual(CodeAnalysisLocation.describe(refusal), L("The token lacks the %1$@ right.", "cas.write"))
        XCTAssertEqual(CodeAnalysisLocation.state(for: refusal),
                       .refused(reason: L("The token lacks the %1$@ right.", "cas.write")))
        XCTAssertEqual(CodeAnalysisLocation.describe(RemoteStore.Failure.refused(
            status: 403, message: "this token has none of the rights cas.write, ghidra.use",
            rights: ["cas.write", "ghidra.use"])),
            L("The token lacks the rights %1$@.", "cas.write, ghidra.use"))
        XCTAssertEqual(CodeAnalysisLocation.describe(RemoteStore.Failure.refused(
            status: 401, message: "a bearer token is required", rights: [])),
            L("The server does not accept the token."))
        XCTAssertEqual(CodeAnalysisLocation.state(for: RemoteStore.Failure.unreachable("nothing listens")),
                       .unreachable(reason: CodeAnalysisLocation.describe(RemoteStore.Failure.unreachable("nothing listens"))))
    }
}
