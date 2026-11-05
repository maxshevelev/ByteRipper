import CodeAnalysis
import DumpHost
import Foundation
import GhidraHost
import HTTPService
import ServerAuth
import XCTest
@testable import ByteRipperServer

final class ServerCommandTests: XCTestCase {
    /// The route reads the reasons for the entries a publish moves from the
    /// body, whichever way the conflicts are decided.
    func testAPublishRouteReadsTheEntryReasons() throws {
        func request(_ query: [String: String], _ body: [String: Any]?) throws -> HTTPRequest {
            var request = HTTPRequest(method: "POST", path: "/x", query: query, headers: [:],
                                      body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
            request.parameters = [:]
            return request
        }
        let reasons = ["a": "why a"]
        XCTAssertEqual(GhidraRoutes.libraryTake(try request([:], nil)), .none)
        XCTAssertEqual(GhidraRoutes.libraryTake(try request([:], ["entry_reasons": reasons])),
                       LibraryTake.none.with(entryReasons: reasons))
        XCTAssertEqual(GhidraRoutes.libraryTake(try request(
            ["take_library_conflicts": "1", "library_reason": "all"], ["entry_reasons": reasons])),
                       LibraryTake.all("all").with(entryReasons: reasons))
        XCTAssertEqual(GhidraRoutes.libraryTake(try request([:], [
            "take_library_conflicts": ["b"], "library_reasons": ["b": "why b"], "entry_reasons": reasons])),
                       LibraryTake.these(["b": "why b"]).with(entryReasons: reasons))
    }

    /// A home no configuration file is in, so the defaults are the defaults.
    private func emptyHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("byteripper-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// The line parsed as on a Mac with no configuration file.
    private func parse(_ arguments: [String]) throws -> ServerCommand {
        try ServerCommand.parse(arguments, home: emptyHome())
    }

    func testTheDefaultsServeTheStoreOnLoopback() throws {
        guard case .serve(let configuration) = try parse([]) else { return XCTFail() }
        XCTAssertEqual(configuration.roles, [.cas, .ghidra])
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8765)
        XCTAssertEqual(configuration.store, CodeAnalysisPaths.defaultRoot)
        XCTAssertEqual(configuration.tokensFile, ServerPaths.defaultTokensFile)
    }

    func testAnAddressAStoreAndATokensFile() throws {
        let parsed = try parse(["serve", "--cas", "--listen", "100.64.1.2:9000",
                                              "--store", "/tmp/s", "--tokens", "/tmp/t.json"])
        guard case .serve(let configuration) = parsed else { return XCTFail() }
        XCTAssertEqual(configuration.host, "100.64.1.2")
        XCTAssertEqual(configuration.port, 9000)
        XCTAssertEqual(configuration.store.path, "/tmp/s")
        XCTAssertEqual(configuration.tokensFile.path, "/tmp/t.json")
        guard case .serve(let ipv6) = try parse(["--listen", "[::1]:8765"]) else { return XCTFail() }
        XCTAssertEqual(ipv6.host, "::1")
        guard case .serve(let both) = try parse(["--listen", "127.0.0.1:8765",
                                                               "--listen", "admins-imac:8765"]) else { return XCTFail() }
        XCTAssertEqual(both.listens, [.init(host: "127.0.0.1", port: 8765), .init(host: "admins-imac", port: 8765)])

        guard case .serve(let named) = try parse(["--server-name", "studio.local",
                                                                "--server-name", "studio.tail.ts.net"]) else { return XCTFail() }
        XCTAssertEqual(named.serverNames, ["studio.local", "studio.tail.ts.net"], "the console's names, repeatable")
    }

    /// The store is always served (`Design/SERVER_HEADLESS_PLAN.md` decision
    /// 17): `--ghidra` alone is every role, and `--cas` alone turns Ghidra off.
    func testTheStoreIsServedWhateverTheRolesNamed() throws {
        guard case .serve(let ghidra) = try parse(["--ghidra"]) else { return XCTFail() }
        XCTAssertEqual(ghidra.roles, [.cas, .ghidra])
        guard case .serve(let cas) = try parse(["--cas"]) else { return XCTFail() }
        XCTAssertEqual(cas.roles, [.cas])
    }

    func testWhatIsRefused() {
        XCTAssertThrowsError(try parse(["--idle", "-1"]))
        XCTAssertThrowsError(try parse(["--listen", "nowhere"]))
        XCTAssertThrowsError(try parse(["--store"]))
        XCTAssertThrowsError(try parse(["--bogus"]))
        XCTAssertThrowsError(try parse(["--cas-url", "http://100.64.0.7:8765"]),
                             "--cas-url is gone: the store is this server's own")
        XCTAssertThrowsError(try parse(["frobnicate"]))
    }

    func testTheTokenCommands() throws {
        XCTAssertEqual(try parse(["token", "add", "--name", "admin", "--rights", "admin"]),
                       .token(.add(name: "admin", rights: [.admin], file: ServerPaths.defaultTokensFile)))
        XCTAssertEqual(try parse(["token", "list", "--tokens", "/tmp/t.json"]),
                       .token(.list(file: URL(fileURLWithPath: "/tmp/t.json"))))
        XCTAssertEqual(try parse(["token", "revoke", "laptop"]),
                       .token(.revoke(id: "laptop", file: ServerPaths.defaultTokensFile)))
        XCTAssertThrowsError(try parse(["token", "add"]))
    }

    /// `~/.byteripper-server.json` fills what the line does not say; a flag
    /// still wins, and `--no-config` reads none.
    func testTheConfigurationFileFillsWhatTheFlagsDoNot() throws {
        let home = emptyHome()
        let support = home.appendingPathComponent("var/support", isDirectory: true)
        try """
        {
          "support": "\(support.path)",
          "store": "\(home.path)/store",
          "dumpRoots": ["\(home.path)/dumps"],
          "idle": 60,
          "maxOpenBytes": "64 MiB",
          "listen": ["127.0.0.1:18765"]
        }
        """.write(to: ServerConfiguration.defaultFile(in: home), atomically: true, encoding: .utf8)

        guard case .serve(let configuration) = try ServerCommand.parse([], home: home) else { return XCTFail() }
        XCTAssertEqual(configuration.support?.path, support.path)
        XCTAssertEqual(configuration.tokensFile, support.appendingPathComponent("tokens.json"))
        XCTAssertEqual(configuration.mcpSocket, support.appendingPathComponent("mcp.sock"))
        XCTAssertEqual(configuration.documentsFile, support.appendingPathComponent("documents.json"))
        XCTAssertEqual(configuration.uploads.path, support.appendingPathComponent("Uploads").path)
        XCTAssertEqual(configuration.store, home.appendingPathComponent("store"))
        XCTAssertEqual(configuration.dumpRoots, [home.appendingPathComponent("dumps")])
        XCTAssertEqual(configuration.idle, 60)
        XCTAssertEqual(configuration.limits.openBytes, UInt64(64 << 20))
        XCTAssertEqual(configuration.port, 18765)

        // The token commands keep the file's tokens, and a flag beats the file.
        XCTAssertEqual(try ServerCommand.parse(["token", "list"], home: home),
                       .token(.list(file: support.appendingPathComponent("tokens.json"))))
        guard case .serve(let overridden) = try ServerCommand.parse(["--store", "/tmp/other",
                                                                     "--support", "/tmp/sup"],
                                                                    home: home) else { return XCTFail() }
        XCTAssertEqual(overridden.store.path, "/tmp/other")
        XCTAssertEqual(overridden.tokensFile.path, "/tmp/sup/tokens.json")

        guard case .serve(let none) = try ServerCommand.parse(["--no-config"], home: home) else { return XCTFail() }
        XCTAssertNil(none.support)
        XCTAssertEqual(none.tokensFile, ServerPaths.defaultTokensFile)
    }

    func testAConfigurationFileTheServerDoesNotKnowIsRefused() throws {
        let home = emptyHome()
        let file = ServerConfiguration.defaultFile(in: home)
        try #"{"stroe": "/tmp/s"}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServerCommand.parse([], home: home)) { error in
            XCTAssertTrue("\(error)".contains("stroe"), "the key is named: \(error)")
            XCTAssertTrue("\(error)".contains("did you mean \"store\""), "and the one meant: \(error)")
        }
        try #"{"idle": "soon"}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServerCommand.parse([], home: home)) { error in
            XCTAssertTrue("\(error)".contains("idle"), "the key is named: \(error)")
        }
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServerCommand.parse([], home: home))
        try #"{"support": "/tmp/s"}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServerCommand.parse(["--config", home.path + "/nothing.json"], home: home),
                             "a named file that is not there is refused")
    }

    /// A file that does not parse says where the parser stopped, and a file
    /// that parses to something else says what it is.
    func testABrokenConfigurationFileSaysWhere() throws {
        let home = emptyHome()
        let file = ServerConfiguration.defaultFile(in: home)
        try "{\n  \"store\": /tmp/x\n}\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServerCommand.parse([], home: home)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains(file.path), "the file is named: \(text)")
            XCTAssertTrue(text.lowercased().contains("line"), "the parser's place is kept: \(text)")
        }
        try #"[1, 2]"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServerCommand.parse([], home: home)) { error in
            XCTAssertTrue("\(error)".contains("a list"), "what it is instead: \(error)")
        }
    }

    /// A `listen` list in the file is kept and a flag adds to it; without the
    /// file, the flags are the whole list.
    func testAFlagListenAddsToTheFilesList() throws {
        let home = emptyHome()
        try #"{"listen": ["100.64.1.2:9000"]}"#
            .write(to: ServerConfiguration.defaultFile(in: home), atomically: true, encoding: .utf8)
        guard case .serve(let both) = try ServerCommand.parse(["--listen", "127.0.0.1:18765"],
                                                              home: home) else { return XCTFail() }
        XCTAssertEqual(both.listens, [.init(host: "100.64.1.2", port: 9000),
                                      .init(host: "127.0.0.1", port: 18765)])
        guard case .serve(let alone) = try ServerCommand.parse(["--listen", "127.0.0.1:18765"],
                                                              home: emptyHome()) else { return XCTFail() }
        XCTAssertEqual(alone.listens, [.init(host: "127.0.0.1", port: 18765)])
        guard case .serve(let repeated) = try ServerCommand.parse(
            ["--listen", "127.0.0.1:18765", "--listen", "127.0.0.1:18765"], home: emptyHome()) else { return XCTFail() }
        XCTAssertEqual(repeated.listens.count, 1, "one address is bound once")
    }

    /// `serverName` is the flag's own spelling and takes a string or a list;
    /// `serverNames` is still read, and a misspelt key suggests the one meant.
    func testTheNamesTheConsoleAnswersUnder() throws {
        let home = emptyHome()
        let file = ServerConfiguration.defaultFile(in: home)
        try #"{"serverName": "admins-imac"}"#.write(to: file, atomically: true, encoding: .utf8)
        guard case .serve(let one) = try ServerCommand.parse([], home: home) else { return XCTFail() }
        XCTAssertEqual(one.serverNames, ["admins-imac"])
        try #"{"serverNames": ["a.local", "b.local"]}"#.write(to: file, atomically: true, encoding: .utf8)
        guard case .serve(let list) = try ServerCommand.parse([], home: home) else { return XCTFail() }
        XCTAssertEqual(list.serverNames, ["a.local", "b.local"])
        try #"{"serverName": ["a.local"]}"#.write(to: file, atomically: true, encoding: .utf8)
        guard case .serve(let listed) = try ServerCommand.parse([], home: home) else { return XCTFail() }
        XCTAssertEqual(listed.serverNames, ["a.local"], "the flag's key takes a list too")
    }

    /// A `tokens` or `mcpSocket` in the file survives the launchers'
    /// `--support`; `--tokens` on the line still wins over both.
    func testAFileTokenOutlivesASupportOnTheLine() throws {
        let home = emptyHome()
        let file = ServerConfiguration.defaultFile(in: home)
        try #"{"tokens": "/tmp/shared/tokens.json"}"#.write(to: file, atomically: true, encoding: .utf8)
        guard case .serve(let kept) = try ServerCommand.parse(["--support", "/tmp/sup"],
                                                              home: home) else { return XCTFail() }
        XCTAssertEqual(kept.tokensFile.path, "/tmp/shared/tokens.json")
        XCTAssertEqual(kept.clientTokenFile.path, "/tmp/shared/token",
                       "the client token is checked beside the tokens it is checked against")
        XCTAssertEqual(kept.mcpSocket.path, "/tmp/sup/mcp.sock", "the socket still follows the folder")
        guard case .serve(let line) = try ServerCommand.parse(["--support", "/tmp/sup",
                                                              "--tokens", "/tmp/line.json"],
                                                             home: home) else { return XCTFail() }
        XCTAssertEqual(line.tokensFile.path, "/tmp/line.json")

        try #"{"mcpSocket": "/tmp/there.sock"}"#.write(to: file, atomically: true, encoding: .utf8)
        guard case .serve(let socket) = try ServerCommand.parse(["--support", "/tmp/sup"],
                                                               home: home) else { return XCTFail() }
        XCTAssertEqual(socket.mcpSocket.path, "/tmp/there.sock")
        XCTAssertEqual(socket.tokensFile.path, "/tmp/sup/tokens.json", "the tokens follow the folder")
    }

    /// A relative path in the file is read from the file's folder, a count is
    /// a whole number, and a repeated listen is bound once.
    func testTheFilesPathsNumbersAndLists() throws {
        let home = emptyHome()
        let file = ServerConfiguration.defaultFile(in: home)
        try #"{"store": "store", "dumpRoots": ["dumps"], "listen": ["127.0.0.1:9000", "127.0.0.1:9000"]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        guard case .serve(let relative) = try ServerCommand.parse([], home: home) else { return XCTFail() }
        XCTAssertEqual(relative.store.path, home.appendingPathComponent("store").standardizedFileURL.path)
        XCTAssertEqual(relative.dumpRoots.map(\.path),
                       [home.appendingPathComponent("dumps").standardizedFileURL.path])
        XCTAssertEqual(relative.listens, [.init(host: "127.0.0.1", port: 9000)], "one address is bound once")

        for broken in [#"{"idle": true}"#, #"{"idle": -5}"#, #"{"idle": 1.5}"#, #"{"maxDocuments": 0}"#] {
            try broken.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ServerCommand.parse([], home: home), broken)
        }
    }

    /// `--support` reaches the token and relay verbs too, which take their
    /// file and socket from it.
    func testSupportReachesEveryVerb() throws {
        let home = emptyHome()
        let support = home.appendingPathComponent("sup", isDirectory: true)
        XCTAssertEqual(try ServerCommand.parse(["token", "list", "--support", support.path], home: home),
                       .token(.list(file: support.appendingPathComponent("tokens.json"))))
        guard case .relay(let path) = try ServerCommand.parse(["relay", "--support", support.path],
                                                              home: home) else { return XCTFail() }
        XCTAssertEqual(path, support.appendingPathComponent("mcp.sock").path)
    }

    /// The token and relay verbs take `--config` too, and it is not refused.
    func testTheOtherVerbsTakeTheConfigurationFile() throws {
        let home = emptyHome()
        let support = home.appendingPathComponent("support", isDirectory: true)
        try #"{"support": "\#(support.path)"}"#.write(to: ServerConfiguration.defaultFile(in: home),
                                                     atomically: true, encoding: .utf8)
        XCTAssertEqual(try ServerCommand.parse(["token", "list"], home: home),
                       .token(.list(file: support.appendingPathComponent("tokens.json"))))
        guard case .relay(let path) = try ServerCommand.parse(["relay"], home: home) else { return XCTFail() }
        XCTAssertEqual(path, support.appendingPathComponent("mcp.sock").path)
    }
}

@MainActor
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
        configuration.uploads = directory.appendingPathComponent("Uploads")
        configuration.documentsFile = directory.appendingPathComponent("documents.json")
        // `sun_path` holds 104 bytes: a socket in /tmp, not under the test folder.
        configuration.mcpSocket = URL(fileURLWithPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
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

    /// A saved document whose read does not return keeps nobody from the
    /// server: here a FIFO no one writes, as a macOS permission prompt nobody
    /// has answered holds a read of a cloud drive's file.
    func testAServerAnswersWhileASavedDocumentCannotBeRead() async throws {
        let tokens = try TokenStore.open(at: directory.appendingPathComponent("tokens.json"))
        try tokens.add(name: "admin", rights: TokenPreset.admin.rights)
        let (_, secret) = try tokens.add(name: "app", rights: TokenPreset.app.rights)
        let dumps = directory.appendingPathComponent("dumps", isDirectory: true)
        try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
        let dump = dumps.appendingPathComponent("held.bin")
        try SyntheticDump.image().write(to: dump)
        var configuration = ServerConfiguration()
        configuration.roles = [.cas]
        configuration.port = 0
        configuration.dumpRoots = [dumps]
        configuration.store = directory.appendingPathComponent("store")
        configuration.tokensFile = directory.appendingPathComponent("tokens.json")
        configuration.uploads = directory.appendingPathComponent("Uploads")
        configuration.documentsFile = directory.appendingPathComponent("documents.json")
        configuration.mcpSocket = URL(fileURLWithPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        configuration.clientTokenFile = directory.appendingPathComponent("token")
        let saved = DocumentRegistry(roots: [dumps], uploads: configuration.uploads,
                                     file: configuration.documentsFile)
        try await saved.open(path: dump)
        try FileManager.default.removeItem(at: dump)
        XCTAssertEqual(mkfifo(dump.path, 0o600), 0)

        let lines = Lines()
        let server = Server(configuration: configuration, log: { lines.add($0) })
        let port = try await server.start()
        defer { server.stop() }
        let remote = RemoteStore(base: URL(string: "http://127.0.0.1:\(port)")!, token: secret)
        _ = try await remote.hello()
        XCTAssertTrue(lines.all.contains("documents: opening 1"), "\(lines.all)")
        XCTAssertEqual(server.documents?.rows.count, 1)
        XCTAssertEqual(server.documents?.documents().count, 0)

        // A writer that opens and closes ends the read.
        let writer = open(dump.path, O_WRONLY | O_NONBLOCK)
        close(writer)
        await server.documentsOpened()
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("documents: ") && $0.contains(" of 1") }, "\(lines.all)")
    }

    /// The rights matrix over the wire (`Design/SERVER_HEADLESS_PLAN.md`
    /// decision 4): every token reads the store, `cas.write` writes it,
    /// `ghidra.use` reaches Ghidra, and a refusal names the right it lacks.
    func testEachRouteAsksForItsRight() async throws {
        let tokens = try TokenStore.open(at: directory.appendingPathComponent("tokens.json"))
        let (_, admin) = try tokens.add(name: "admin", rights: TokenPreset.admin.rights)
        let (_, reader) = try tokens.add(name: "reader", rights: TokenPreset.reader.rights)
        let (_, app) = try tokens.add(name: "app", rights: TokenPreset.app.rights)
        var configuration = ServerConfiguration()
        configuration.roles = [.cas, .ghidra]
        configuration.port = 0
        configuration.store = directory.appendingPathComponent("store")
        configuration.projects = directory.appendingPathComponent("projects")
        configuration.tokensFile = directory.appendingPathComponent("tokens.json")
        configuration.uploads = directory.appendingPathComponent("Uploads")
        configuration.documentsFile = directory.appendingPathComponent("documents.json")
        // `sun_path` holds 104 bytes: a socket in /tmp, not under the test folder.
        configuration.mcpSocket = URL(fileURLWithPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
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
        // The network MCP is gone (`Design/SERVER_HEADLESS_PLAN.md` §9): an
        // agent on the server uses the socket, not a route.
        let status2 = try await call("POST", "mcp", reader, body: Data("{}".utf8)).0
        XCTAssertEqual(status2, 404)
        // Replacing a shared definition is an administrator's: a token that may
        // use Ghidra and write the store does not reach it, on any route; the
        // administrator's goes past the right, and hears why there is nothing to do.
        let someModule = SHA256Digest(data: object).hex
        let replacing: [(String, Data)] = [
            ("ghidra/v1/modules/\(someModule)/publish",
             Data(#"{"take_library_conflicts":["a"],"library_reasons":{"a":"why"}}"#.utf8)),
            ("ghidra/v1/modules/\(someModule)/library", Data(#"{"action":"rename","id":"a","name":"B","reason":"why"}"#.utf8)),
            ("ghidra/v1/modules/\(someModule)/library",
             Data(#"{"action":"change","change":{"action":"take_out","id":"a","reason":"why"}}"#.utf8)),
            ("cas/v1/library", try JSONEncoder().encode(ServedStoreProtocol.PutLibrary(
                module: SHA256Digest(data: object), rev: nil, by: "test", proposals: [],
                change: LibraryChange(action: .takeOut, id: "a", reason: "why")))),
            ("cas/v1/library", try JSONEncoder().encode(ServedStoreProtocol.PutLibrary(
                module: SHA256Digest(data: object), rev: nil, by: "test", proposals: [], reason: "why",
                renameID: "a", renameTo: "B")))
        ]
        for (path, body) in replacing {
            let (refused, words) = try await call("POST", path, app, body: body)
            XCTAssertEqual(refused, 403, "\(path): \(words)")
            XCTAssertTrue(words.contains("admin"), words)
            let reached = try await call("POST", path, admin, body: body).0
            XCTAssertNotEqual(reached, 403, path)
        }
        // A citation only adds, and stays with whoever may write the store.
        let citation = try JSONEncoder().encode(ServedStoreProtocol.PutLibrary(
            module: SHA256Digest(data: object), rev: nil, by: "test", proposals: [],
            change: LibraryChange(action: .cite, id: "a", file: "MdePkg/x.c", line: 1)))
        let cited = try await call("POST", "cas/v1/library", app, body: citation).0
        XCTAssertNotEqual(cited, 403)
        // A publish lacks two rights, and one refusal names both — through
        // the client the app relays Ghidra calls with, as values.
        do {
            _ = try await GhidraRemote(base: base, token: reader).publishModule(SHA256Digest(data: object), by: "test")
            XCTFail("a reader token published")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.rights, ["cas.write", "ghidra.use"])
        }

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
        configuration.uploads = directory.appendingPathComponent("Uploads")
        configuration.documentsFile = directory.appendingPathComponent("documents.json")
        // `sun_path` holds 104 bytes: a socket in /tmp, not under the test folder.
        configuration.mcpSocket = URL(fileURLWithPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
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
