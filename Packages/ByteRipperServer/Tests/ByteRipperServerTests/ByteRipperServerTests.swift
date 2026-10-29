import CodeAnalysis
import Foundation
import HTTPService
import ServerAuth
import XCTest
@testable import ByteRipperServer

final class ServerCommandTests: XCTestCase {
    func testTheDefaultsServeTheStoreOnLoopback() throws {
        guard case .serve(let configuration) = try ServerCommand.parse([]) else { return XCTFail() }
        XCTAssertEqual(configuration.roles, [.cas, .ghidra])
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8765)
        XCTAssertEqual(configuration.store, CodeAnalysisPaths.defaultRoot)
        XCTAssertEqual(configuration.tokensFile, ServerPaths.defaultTokensFile)
    }

    func testAnAddressAStoreAndATokensFile() throws {
        let parsed = try ServerCommand.parse(["serve", "--cas", "--listen", "100.64.1.2:9000",
                                              "--store", "/tmp/s", "--tokens", "/tmp/t.json"])
        guard case .serve(let configuration) = parsed else { return XCTFail() }
        XCTAssertEqual(configuration.host, "100.64.1.2")
        XCTAssertEqual(configuration.port, 9000)
        XCTAssertEqual(configuration.store.path, "/tmp/s")
        XCTAssertEqual(configuration.tokensFile.path, "/tmp/t.json")
        guard case .serve(let ipv6) = try ServerCommand.parse(["--listen", "[::1]:8765"]) else { return XCTFail() }
        XCTAssertEqual(ipv6.host, "::1")
        guard case .serve(let both) = try ServerCommand.parse(["--listen", "127.0.0.1:8765",
                                                               "--listen", "admins-imac:8765"]) else { return XCTFail() }
        XCTAssertEqual(both.listens, [.init(host: "127.0.0.1", port: 8765), .init(host: "admins-imac", port: 8765)])
    }

    /// The store is always served (`Design/SERVER_HEADLESS_PLAN.md` decision
    /// 17): `--ghidra` alone is every role, and `--cas` alone turns Ghidra off.
    func testTheStoreIsServedWhateverTheRolesNamed() throws {
        guard case .serve(let ghidra) = try ServerCommand.parse(["--ghidra"]) else { return XCTFail() }
        XCTAssertEqual(ghidra.roles, [.cas, .ghidra])
        guard case .serve(let cas) = try ServerCommand.parse(["--cas"]) else { return XCTFail() }
        XCTAssertEqual(cas.roles, [.cas])
    }

    func testWhatIsRefused() {
        XCTAssertThrowsError(try ServerCommand.parse(["--idle", "-1"]))
        XCTAssertThrowsError(try ServerCommand.parse(["--listen", "nowhere"]))
        XCTAssertThrowsError(try ServerCommand.parse(["--store"]))
        XCTAssertThrowsError(try ServerCommand.parse(["--bogus"]))
        XCTAssertThrowsError(try ServerCommand.parse(["--cas-url", "http://100.64.0.7:8765"]),
                             "--cas-url is gone: the store is this server's own")
        XCTAssertThrowsError(try ServerCommand.parse(["frobnicate"]))
    }

    func testTheTokenCommands() throws {
        XCTAssertEqual(try ServerCommand.parse(["token", "add", "--name", "admin", "--rights", "admin"]),
                       .token(.add(name: "admin", rights: [.admin], file: ServerPaths.defaultTokensFile)))
        XCTAssertEqual(try ServerCommand.parse(["token", "list", "--tokens", "/tmp/t.json"]),
                       .token(.list(file: URL(fileURLWithPath: "/tmp/t.json"))))
        XCTAssertEqual(try ServerCommand.parse(["token", "revoke", "laptop"]),
                       .token(.revoke(id: "laptop", file: ServerPaths.defaultTokensFile)))
        XCTAssertThrowsError(try ServerCommand.parse(["token", "add"]))
    }
}

final class ServerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheServerServesItsStoreBehindItsToken() async throws {
        let tokens = try TokenStore.open(at: directory.appendingPathComponent("tokens.json"))
        // The console's admin token is what lets the server start at all.
        try tokens.add(name: "admin", rights: TokenPreset.admin.rights)
        let (_, secret) = try tokens.add(name: "app", rights: TokenPreset.app.rights)
        var configuration = ServerConfiguration()
        configuration.roles = [.cas]
        configuration.port = 0
        configuration.store = directory.appendingPathComponent("store")
        configuration.tokensFile = directory.appendingPathComponent("tokens.json")
        configuration.clientTokenFile = directory.appendingPathComponent("token")
        let lines = Lines()
        let server = Server(configuration: configuration, log: { lines.add($0) })
        let port = try await server.start()
        defer { server.stop() }

        let remote = RemoteStore(base: URL(string: "http://127.0.0.1:\(port)")!, token: secret)
        let hello = try await remote.hello()
        XCTAssertEqual(hello.store, try ContentStore(root: configuration.store).identity())
        XCTAssertTrue(lines.all.contains { $0.contains("GET /cas/v1/hello 200") }, "\(lines.all)")
        do {
            _ = try await RemoteStore(base: remote.base, token: "wrong").hello()
            XCTFail("answered a wrong token")
        } catch RemoteStore.Failure.refused(let status, _, _) {
            XCTAssertEqual(status, 401)
        }
    }

    /// The rights matrix over the wire (`Design/SERVER_HEADLESS_PLAN.md`
    /// decision 4): every token reads the store, `cas.write` writes it,
    /// `ghidra.use` reaches Ghidra, and a refusal names the right it lacks.
    func testEachRouteAsksForItsRight() async throws {
        let tokens = try TokenStore.open(at: directory.appendingPathComponent("tokens.json"))
        try tokens.add(name: "admin", rights: TokenPreset.admin.rights)
        let (_, reader) = try tokens.add(name: "reader", rights: TokenPreset.reader.rights)
        let (_, app) = try tokens.add(name: "app", rights: TokenPreset.app.rights)
        var configuration = ServerConfiguration()
        configuration.roles = [.cas, .ghidra]
        configuration.port = 0
        configuration.store = directory.appendingPathComponent("store")
        configuration.projects = directory.appendingPathComponent("projects")
        configuration.tokensFile = directory.appendingPathComponent("tokens.json")
        configuration.clientTokenFile = directory.appendingPathComponent("token")
        let server = Server(configuration: configuration, log: { _ in })
        let port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        func call(_ method: String, _ path: String, _ token: String, body: Data? = nil) async throws -> (Int, String) {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }
        let object = Data("bytes".utf8)
        let objectPath = "cas/v1/objects/\(SHA256Digest(data: object).hex)"

        let status1 = try await call("GET", "cas/v1/hello", reader).0
        XCTAssertEqual(status1, 200)
        let (written, refusal) = try await call("PUT", objectPath, reader, body: object)
        XCTAssertEqual(written, 403)
        XCTAssertTrue(refusal.contains("cas.write"), refusal)
        let (ghidra, why) = try await call("GET", "ghidra/v1/modules", reader)
        XCTAssertEqual(ghidra, 403)
        XCTAssertTrue(why.contains("ghidra.use"), why)
        let status2 = try await call("POST", "mcp", reader, body: Data("{}".utf8)).0
        XCTAssertEqual(status2, 403)

        let status3 = try await call("PUT", objectPath, app, body: object).0
        XCTAssertEqual(status3, 204)
        let status4 = try await call("GET", "ghidra/v1/modules", app).0
        XCTAssertEqual(status4, 200)
    }

    /// This Mac's client token is said nothing about when it is one of the
    /// server's, and named — never as a file to delete — when it is not.
    func testTheClientTokenIsCheckedNotDeleted() throws {
        let tokens = try TokenStore.open(at: directory.appendingPathComponent("tokens.json"))
        let (_, app) = try tokens.add(name: "app", rights: TokenPreset.app.rights)
        let client = directory.appendingPathComponent("token")
        XCTAssertNil(Server.clientTokenWarning(client, tokens: tokens), "no file, nothing to say")

        try Data((app + "\n").utf8).write(to: client)
        XCTAssertNil(Server.clientTokenWarning(client, tokens: tokens))
        XCTAssertNil(try TokenStore.open(at: directory.appendingPathComponent("tokens.json")).all()
            .first?.lastUsed, "the check is not a use")

        try Data("an-earlier-builds-token\n".utf8).write(to: client)
        let warning = try XCTUnwrap(Server.clientTokenWarning(client, tokens: tokens))
        XCTAssertTrue(warning.contains("token add"), warning)
        XCTAssertTrue(warning.contains("do not delete it"), warning)
        try tokens.revoke("app")
        try Data((app + "\n").utf8).write(to: client)
        XCTAssertNotNil(Server.clientTokenWarning(client, tokens: tokens), "a revoked token is not one of the server's")
    }

    /// Without an admin token the console cannot be opened and the file cannot
    /// be corrected through it, so the server names the command instead of
    /// starting (`Design/SERVER_HEADLESS_PLAN.md` decision 16).
    func testAServerWithoutAnAdminTokenRefusesToStart() async throws {
        var configuration = ServerConfiguration()
        configuration.roles = [.cas]
        configuration.port = 0
        configuration.store = directory.appendingPathComponent("store")
        configuration.tokensFile = directory.appendingPathComponent("tokens.json")
        configuration.clientTokenFile = directory.appendingPathComponent("token")
        do {
            try await Server(configuration: configuration, log: { _ in }).start()
            XCTFail("started without an admin token")
        } catch {
            XCTAssertTrue("\(error)".contains("no admin token"), "\(error)")
            XCTAssertTrue("\(error)".contains("token add --name admin --rights admin"), "\(error)")
        }
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
