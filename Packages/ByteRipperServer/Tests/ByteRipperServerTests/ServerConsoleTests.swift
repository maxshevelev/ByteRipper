import AgentKit
import DumpHost
import Foundation
import HTTPService
import ServerAuth
import ServerConsole
import XCTest
@testable import ByteRipperServer

/// The console over loopback (`Design/SERVER_HEADLESS_PLAN.md` §5, §8,
/// phase 7): the shell open and its data behind a session, sign-in and its
/// cookies, CSRF on every change, `Host` and `Origin` on every `/admin` path,
/// and the documents, tokens and activity as the operator sees them.
@MainActor
final class ServerConsoleTests: XCTestCase {
    private var directory: URL!
    private var dumps: URL!
    private var server: Server!
    private var base: URL!
    private var admin = ""
    private var app = ""
    private var reader = ""

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerConsoleTests-\(UUID().uuidString)", isDirectory: true)
        dumps = directory.appendingPathComponent("dumps", isDirectory: true)
        try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
        let tokens = try TokenStore.open(at: directory.appendingPathComponent("tokens.json"))
        admin = try tokens.add(name: "admin", rights: TokenPreset.admin.rights).secret
        app = try tokens.add(name: "studio", rights: TokenPreset.app.rights).secret
        reader = try tokens.add(name: "reader", rights: TokenPreset.reader.rights).secret
        var configuration = ServerConfiguration()
        configuration.roles = [.cas]
        configuration.port = 0
        configuration.store = directory.appendingPathComponent("store")
        configuration.tokensFile = directory.appendingPathComponent("tokens.json")
        configuration.uploads = directory.appendingPathComponent("Uploads")
        configuration.documentsFile = directory.appendingPathComponent("documents.json")
        configuration.dumpRoots = [dumps]
        // `sun_path` holds 104 bytes: a socket in /tmp, not under the test folder.
        configuration.mcpSocket = URL(fileURLWithPath: "/tmp/br-\(UUID().uuidString.prefix(8)).sock")
        configuration.clientTokenFile = directory.appendingPathComponent("token")
        server = Server(configuration: configuration, log: { _ in })
        let port = try await server.start()
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - A browser

    /// What a browser holds after signing in: the two cookies, sent back by
    /// hand — the session never touches the shared cookie store.
    private struct Signed {
        var session: String
        var csrf: String
        var cookie: String { "\(AdminCookie.session)=\(session); \(AdminCookie.csrf)=\(csrf)" }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private func call(_ method: String, _ path: String, signed: Signed? = nil, csrf: Bool = true,
                      bearer: String? = nil, json: Any? = nil, body: Data? = nil,
                      headers: [String: String] = [:]) async throws -> (status: Int, body: JSONValue?, response: HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        if let signed {
            request.setValue(signed.cookie, forHTTPHeaderField: "Cookie")
            if csrf { request.setValue(signed.csrf, forHTTPHeaderField: "X-CSRF-Token") }
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await Self.session.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, try? JSONValue.parse(data), http)
    }

    private func signIn(_ secret: String? = nil) async throws -> Signed {
        let answer = try await call("POST", "/admin/login", json: ["token": secret ?? admin])
        XCTAssertEqual(answer.status, 200, "\(String(describing: answer.body))")
        let fields = answer.response.allHeaderFields as? [String: String] ?? [:]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: base.appendingPathComponent("admin"))
        let session = try XCTUnwrap(cookies.first { $0.name == AdminCookie.session })
        let csrf = try XCTUnwrap(cookies.first { $0.name == AdminCookie.csrf })
        XCTAssertTrue(session.isHTTPOnly, "the session is out of a script's reach")
        XCTAssertFalse(csrf.isHTTPOnly, "the page reads the CSRF value to send it back")
        XCTAssertEqual(session.path, "/admin")
        return Signed(session: session.value, csrf: csrf.value)
    }

    // MARK: - The door

    /// The shell is open and holds no data; every answer with data needs the
    /// session (§5: a test asserts the API without one is a 401).
    func testTheShellIsOpenAndTheDataIsNot() async throws {
        let status = try await call("GET", "/admin/api/status")
        XCTAssertEqual(status.status, 401)
        for page in Console.pages {
            let shell = try await call("GET", page)
            XCTAssertEqual(shell.status, 200, page)
            XCTAssertEqual(shell.response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
            XCTAssertNotNil(shell.response.value(forHTTPHeaderField: "Content-Security-Policy"))
            XCTAssertEqual(shell.response.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
        }
        let script = try await call("GET", "/admin/assets/console.js")
        XCTAssertEqual(script.status, 200)
        let status1 = try await call("GET", "/admin/api/documents").status
        XCTAssertEqual(status1, 401)
        let status2 = try await call("GET", "/admin/anything").status
        XCTAssertEqual(status2, 401, "no page answers for a name it does not list")
    }

    /// Only an admin token signs in; the session reads, and a change needs
    /// its CSRF token as well. The cookie opens nothing outside `/admin`.
    func testSignInAndCSRF() async throws {
        let wrong = try await call("POST", "/admin/login", json: ["token": "not-a-token"])
        XCTAssertEqual(wrong.status, 401)
        let notAdmin = try await call("POST", "/admin/login", json: ["token": app])
        XCTAssertEqual(notAdmin.status, 403)
        let form = try await call("POST", "/admin/login", body: Data("token=\(admin)".utf8),
                                  headers: ["Content-Type": "application/x-www-form-urlencoded"])
        XCTAssertEqual(form.status, 200, "a form's body signs in too")

        let signed = try await signIn()
        let session = try await call("GET", "/admin/api/session", signed: signed)
        XCTAssertEqual(session.body?["name"]?.stringValue, "admin")
        let unguarded = try await call("POST", "/admin/api/documents", signed: signed, csrf: false, json: ["path": "/x"])
        XCTAssertEqual(unguarded.status, 403, "a change without the CSRF token")
        let store = try await call("GET", "/cas/v1/hello", signed: signed)
        XCTAssertEqual(store.status, 401, "the console's cookie is no key to the store")

        let out = try await call("POST", "/admin/logout", signed: signed)
        XCTAssertEqual(out.status, 200)
        let status3 = try await call("GET", "/admin/api/session", signed: signed).status
        XCTAssertEqual(status3, 401)
    }

    /// Decision 19: a console request under a name this server does not
    /// own is refused before any route — the open sign-in first of all.
    func testAnUnlistedHostOrOriginIsRefused() async throws {
        let names = ConsoleNames(listens: ["127.0.0.1"], serverNames: ["studio.tail.ts.net"], interfaces: { [] })
        func head(_ path: String, _ headers: [String: String]) -> HTTPRequest {
            HTTPRequest(method: "POST", path: path, headers: headers)
        }
        XCTAssertNil(names.screen(head("/admin/login", ["host": "127.0.0.1:8765"])))
        XCTAssertNil(names.screen(head("/admin/login", ["host": "localhost:8765", "origin": "http://localhost:8765"])))
        XCTAssertNil(names.screen(head("/admin/login", ["host": "Studio.tail.ts.net.", "origin": "http://studio.tail.ts.net:8765"])))
        XCTAssertNil(names.screen(head("/admin/login", ["host": "[::1]:8765"])))
        XCTAssertNotNil(names.screen(head("/admin/login", ["host": "rebound.example:8765"])))
        XCTAssertNotNil(names.screen(head("/admin/login", [:])), "no Host at all")
        XCTAssertNotNil(names.screen(head("/admin/login", ["host": "127.0.0.1:8765", "origin": "http://evil.example"])))
        XCTAssertNotNil(names.screen(head("/admin/login", ["host": "127.0.0.1:8765", "origin": "null"])))
        XCTAssertNotNil(names.screen(head("/admin", ["host": "127.0.0.1", "sec-fetch-site": "cross-site"])))
        XCTAssertNil(names.screen(head("/cas/v1/hello", ["host": "rebound.example"])), "the roles are not the console's to guard")
        let wildcard = ConsoleNames(listens: ["0.0.0.0"], serverNames: [], interfaces: { ["192.168.1.20"] })
        XCTAssertNil(wildcard.screen(head("/admin", ["host": "192.168.1.20:8765"])))

        // Over the wire, with a Host header URLSession would not send.
        let port = base.port!
        let reply = try Self.raw("POST /admin/login HTTP/1.1\r\nHost: rebound.example:\(port)\r\n"
            + "Content-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}", port: port)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
    }

    /// One request over a plain TCP socket, its whole answer back.
    private static func raw(_ request: String, port: Int) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw HTTPError(.internalError, "cannot connect") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: answer, as: UTF8.self)
    }

    // MARK: - What the console does

    /// Open by path (and refused outside the roots), upload, reopen, the
    /// order, closing, deleting an upload — the registry's rules, through
    /// the routes.
    func testDocumentsThroughTheConsole() async throws {
        let signed = try await signIn()
        try SyntheticDump.image(marker: 1).write(to: dumps.appendingPathComponent("a.bin"))
        let opened = try await call("POST", "/admin/api/documents", signed: signed,
                                    json: ["path": dumps.appendingPathComponent("a.bin").path])
        XCTAssertEqual(opened.body?["id"]?.stringValue, "d1")
        let outside = try await call("POST", "/admin/api/documents", signed: signed, json: ["path": "/etc/hosts"])
        XCTAssertEqual(outside.status, 422)
        XCTAssertTrue(outside.body?["error"]?.stringValue?.contains("outside the dump roots") == true)
        // What the console itself refuses carries the console's headers too.
        XCTAssertEqual(outside.response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNotNil(outside.response.value(forHTTPHeaderField: "Content-Security-Policy"))

        let uploaded = try await call("POST", "/admin/api/uploads?name=board%20one.bin", signed: signed,
                                      body: SyntheticDump.image(marker: 2))
        XCTAssertEqual(uploaded.body?["id"]?.stringValue, "d2")
        let unnamed = try await call("POST", "/admin/api/uploads", signed: signed, body: Data([1]))
        XCTAssertEqual(unnamed.status, 400)

        var list = try await call("GET", "/admin/api/documents", signed: signed)
        let rows = list.body?["documents"]?.arrayValue ?? []
        XCTAssertEqual(rows.map { $0["id"]?.stringValue }, ["d1", "d2"])
        XCTAssertEqual(rows[1]["name"]?.stringValue, "board one.bin")
        XCTAssertEqual(rows[1]["uploaded"], true)
        XCTAssertEqual(rows[0]["state"]?.stringValue, "open")
        XCTAssertEqual(list.body?["roots"]?.arrayValue?.first?["present"], true)
        XCTAssertEqual(list.body?["used"]?["documents"], .count(2))

        try SyntheticDump.image(marker: 9).write(to: dumps.appendingPathComponent("a.bin"))
        list = try await call("GET", "/admin/api/documents", signed: signed)
        XCTAssertEqual(list.body?["documents"]?.arrayValue?.first?["disk"]?.stringValue, "changed")
        let status4 = try await call("POST", "/admin/api/documents/d1/reopen", signed: signed).status
        XCTAssertEqual(status4, 200)
        list = try await call("GET", "/admin/api/documents", signed: signed)
        XCTAssertEqual(list.body?["documents"]?.arrayValue?.first?["version"], .count(2))

        let status5 = try await call("PUT", "/admin/api/documents/order", signed: signed, json: ["ids": ["d2", "d1"]]).status
        XCTAssertEqual(status5, 200)
        let status6 = try await call("DELETE", "/admin/api/documents/d1", signed: signed).status
        XCTAssertEqual(status6, 422,
                       "only an upload is deleted")
        let status7 = try await call("DELETE", "/admin/api/documents/d2", signed: signed).status
        XCTAssertEqual(status7, 200)
        let status8 = try await call("POST", "/admin/api/documents/d1/close", signed: signed).status
        XCTAssertEqual(status8, 200)
        list = try await call("GET", "/admin/api/documents", signed: signed)
        XCTAssertEqual(list.body?["documents"]?.arrayValue?.count, 0)
    }

    /// A secret is answered once, at making or rotating, never listed; the
    /// last admin token cannot be revoked, and a revocation ends its sessions.
    func testTokensThroughTheConsole() async throws {
        let signed = try await signIn()
        let made = try await call("POST", "/admin/api/tokens", signed: signed, json: ["name": "bench", "preset": "app"])
        let secret = try XCTUnwrap(made.body?["secret"]?.stringValue)
        let id = try XCTUnwrap(made.body?["id"]?.stringValue)
        let listed = try await call("GET", "/admin/api/tokens", signed: signed)
        XCTAssertFalse(String(decoding: listed.body?.encoded() ?? Data(), as: UTF8.self).contains(secret),
                       "the list never carries a secret")
        let bench = listed.body?["tokens"]?.arrayValue?.first { $0["id"]?.stringValue == id }
        XCTAssertEqual(bench?["rights"], ["cas.read", "cas.write", "ghidra.use"])
        let mine = listed.body?["tokens"]?.arrayValue?.first { $0["yours"] == true }
        XCTAssertEqual(mine?["name"]?.stringValue, "admin")
        let twice = try await call("POST", "/admin/api/tokens", signed: signed, json: ["name": "bench", "preset": "reader"])
        XCTAssertEqual(twice.status, 409)

        let rotated = try await call("POST", "/admin/api/tokens/\(id)/rotate", signed: signed)
        XCTAssertNotEqual(rotated.body?["secret"]?.stringValue, secret)
        let status9 = try await call("GET", "/cas/v1/hello", bearer: secret).status
        XCTAssertEqual(status9, 401, "the old secret is refused")

        let adminID = try XCTUnwrap(mine?["id"]?.stringValue)
        let last = try await call("POST", "/admin/api/tokens/\(adminID)/revoke", signed: signed)
        XCTAssertEqual(last.status, 409, "the last admin token stays")

        let second = try await call("POST", "/admin/api/tokens", signed: signed, json: ["name": "ops", "preset": "admin"])
        let opsSecret = try XCTUnwrap(second.body?["secret"]?.stringValue)
        let opsSigned = try await signIn(opsSecret)
        let opsID = try XCTUnwrap(second.body?["id"]?.stringValue)
        let status10 = try await call("POST", "/admin/api/tokens/\(opsID)/revoke", signed: signed).status
        XCTAssertEqual(status10, 200)
        let status11 = try await call("GET", "/admin/api/session", signed: opsSigned).status
        XCTAssertEqual(status11, 401,
                       "a revoked token's sessions end")
    }

    /// A REST client is a row per token; the console's own reads are not.
    /// The status names what the server holds.
    func testActivityAndStatus() async throws {
        let signed = try await signIn()
        _ = try await call("GET", "/cas/v1/hello", bearer: app)
        _ = try await call("PUT", "/cas/v1/objects/00", bearer: reader, body: Data("x".utf8))
        _ = try await call("GET", "/cas/v1/hello", bearer: "stranger")
        let activity = try await call("GET", "/admin/api/activity", signed: signed)
        let rest = activity.body?["rest"]?.arrayValue ?? []
        XCTAssertEqual(Set(rest.compactMap { $0["name"]?.stringValue }), ["studio", "reader", RESTActivity.anonymous])
        let refused = rest.first { $0["name"]?.stringValue == "reader" }
        XCTAssertEqual(refused?["refused"], .count(1))
        XCTAssertEqual(refused?["last_status"], .count(403))
        XCTAssertEqual(activity.body?["mcp"], .array([]))

        let status = try await call("GET", "/admin/api/status", signed: signed)
        XCTAssertEqual(status.body?["version"]?.stringValue, Server.version)
        XCTAssertEqual(status.body?["roles"], ["cas"])
        XCTAssertNil(status.body?["ghidra"], "Ghidra is not a role here")
        XCTAssertEqual(status.body?["sessions"], .count(1))
        XCTAssertEqual(status.body?["addresses"]?.arrayValue?.count, 1)
        XCTAssertNotNil(status.body?["memory"])
    }

    /// A failed sign-in is answered after the pause, and the next attempt
    /// waits it out.
    func testFailedSignInsAreSlowed() async throws {
        let gate = SignInGate(pause: 0.2)
        let started = Date()
        for _ in 0..<2 {
            do {
                _ = try await gate.attempt { () throws -> Int in throw HTTPError(.unauthorized, "no") }
            } catch {}
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)
        let value = try await gate.attempt { 7 }
        XCTAssertEqual(value, 7)
    }
}
