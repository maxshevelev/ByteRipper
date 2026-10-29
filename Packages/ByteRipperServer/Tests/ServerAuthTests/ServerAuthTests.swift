import Foundation
import HTTPService
import XCTest
@testable import ServerAuth

/// What a callback said, in order, from any thread.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A temporary directory of its own for one test.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init(_ name: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var tokens: URL { url.appendingPathComponent("tokens.json") }

    func cleanedUp() { try? FileManager.default.removeItem(at: url) }
}

final class TokenStoreTests: XCTestCase {
    private var scratch: ScratchDirectory!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory("TokenStoreTests")
    }

    override func tearDownWithError() throws {
        scratch.cleanedUp()
    }

    /// The secret exists in the caller's answer and nowhere in the file
    /// (`Design/SERVER_HEADLESS_PLAN.md` §5).
    func testASecretIsShownOnceAndOnlyItsHashIsKept() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let (token, secret) = try store.add(name: "laptop", rights: [.casWrite])
        XCTAssertEqual(secret.count, 43)
        XCTAssertEqual(token.rights, [.casRead, .casWrite], "every token carries cas.read")

        let file = try String(contentsOf: scratch.tokens, encoding: .utf8)
        XCTAssertFalse(file.contains(secret))
        XCTAssertTrue(file.contains(TokenStore.hash(secret)))
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.tokens.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        let principal = store.principal(for: secret)
        XCTAssertEqual(principal?.name, "laptop")
        XCTAssertEqual(principal?.rights, [.casRead, .casWrite])
        XCTAssertNil(store.principal(for: secret + "x"))
        XCTAssertNil(store.principal(for: ""))
    }

    func testARotatedSecretReplacesTheOldOne() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let (token, secret) = try store.add(name: "app", rights: TokenPreset.app.rights)
        let rotated = try store.rotate(token.id)
        XCTAssertNotEqual(rotated, secret)
        XCTAssertNil(store.principal(for: secret))
        XCTAssertEqual(store.principal(for: rotated)?.id, token.id)
    }

    func testARevokedTokenIsRefusedAndItsNameIsFreeAgain() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let (token, secret) = try store.add(name: "app", rights: [.casWrite])
        try store.revoke(token.id)
        XCTAssertNil(store.principal(for: secret))
        XCTAssertThrowsError(try store.rotate(token.id))
        XCTAssertNoThrow(try store.add(name: "app", rights: [.casWrite]))
    }

    func testANameBelongsToOneLiveToken() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        try store.add(name: "app", rights: [])
        XCTAssertThrowsError(try store.add(name: "app", rights: [])) { error in
            XCTAssertEqual(error as? TokenStore.Failure, .duplicateName("app"))
        }
        XCTAssertThrowsError(try store.add(name: "  ", rights: []))
    }

    /// A token may be named by its id or by its name, which is what the
    /// command line shows.
    func testATokenIsFoundByIdOrByName() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let (token, secret) = try store.add(name: "laptop", rights: [])
        try store.revoke("laptop")
        XCTAssertNil(store.principal(for: secret))
        XCTAssertEqual(store.all().first(where: { $0.id == token.id })?.revoked, true)
        XCTAssertThrowsError(try store.revoke("nowhere"))
    }

    /// `last_used` is not a file write per request: it reaches the file at
    /// stop, or once the interval has passed (`Design/SERVER_HEADLESS_PLAN.md`
    /// §5).
    func testLastUsedIsNotWrittenPerRequest() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let (_, secret) = try store.add(name: "agent", rights: [])
        for _ in 0..<50 { _ = store.principal(for: secret) }
        XCTAssertNil(try TokenStore.open(at: scratch.tokens).all().first?.lastUsed)

        try store.flush()
        XCTAssertNotNil(try TokenStore.open(at: scratch.tokens).all().first?.lastUsed)
    }

    func testTheServerNeedsAnAdminToken() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        XCTAssertFalse(store.hasAdmin)
        try store.add(name: "app", rights: TokenPreset.app.rights)
        XCTAssertFalse(store.hasAdmin)
        try store.add(name: "admin", rights: TokenPreset.admin.rights)
        XCTAssertTrue(store.hasAdmin)
    }

    /// An admin token carries the other rights with it: the one command
    /// decision 17 names has to be enough.
    func testAdminCarriesEveryRight() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let (_, secret) = try store.add(name: "admin", rights: [.admin])
        let principal = try XCTUnwrap(store.principal(for: secret))
        XCTAssertTrue(principal.allows(.admin))
        XCTAssertTrue(principal.allows(.casWrite))
        XCTAssertTrue(principal.allows(.ghidraUse))
    }

    func testAFileOthersMayReadIsRefused() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        try store.add(name: "admin", rights: [.admin])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratch.tokens.path)
        XCTAssertThrowsError(try TokenStore.open(at: scratch.tokens)) { error in
            XCTAssertEqual(error as? TokenStore.Failure, .readableByOthers(scratch.tokens.path))
        }
    }

    /// A file that stops reading closes the door rather than serving on from
    /// what was read before — the old cache would still hold tokens the file
    /// has since revoked. It opens again when the file reads again.
    func testAFileThatStopsReadingClosesTheDoor() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let problems = Lines()
        store.onProblem = { problems.add($0) }
        let (_, secret) = try store.add(name: "laptop", rights: [.casWrite])
        XCTAssertNotNil(store.principal(for: secret))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratch.tokens.path)
        // The mode alone changes no stamp; a hand edit that breaks the JSON does.
        let text = try String(contentsOf: scratch.tokens, encoding: .utf8)
        try Data((text + "\n").utf8).write(to: scratch.tokens)
        XCTAssertNil(store.principal(for: secret))
        XCTAssertNil(store.principal(for: secret))
        XCTAssertEqual(problems.all.count, 1, "the problem is said once, not per request")
        XCTAssertTrue(problems.all[0].contains("chmod 600"), problems.all[0])

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.tokens.path)
        XCTAssertNotNil(store.principal(for: secret))
        XCTAssertTrue(problems.all.last!.contains("reads again"))
    }

    /// A lock another process holds is waited for, then given up on — never
    /// waited for forever.
    func testALockHeldElsewhereIsGivenUpOn() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        try store.add(name: "admin", rights: [.admin])
        let held = open(scratch.tokens.path + ".lock", O_RDWR)
        XCTAssertEqual(flock(held, LOCK_EX), 0)
        defer { flock(held, LOCK_UN); close(held) }
        let started = Date()
        XCTAssertThrowsError(try store.add(name: "app", rights: [])) { error in
            XCTAssertEqual(error as? TokenStore.Failure, .cannotLock(scratch.tokens.path + ".lock"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), TokenStore.lockWait + 1)
    }

    /// A revocation made by the command line reaches a server that is already
    /// running: the file's stamp is checked before each request.
    func testAChangeMadeBesideTheServerIsSeen() throws {
        let running = try TokenStore.open(at: scratch.tokens)
        let (_, secret) = try running.add(name: "laptop", rights: [.casWrite])
        XCTAssertNotNil(running.principal(for: secret))

        let commandLine = try TokenStore.open(at: scratch.tokens)
        try commandLine.revoke("laptop")
        XCTAssertNil(running.principal(for: secret))
    }
}

final class ServerAuthorizerTests: XCTestCase {
    private var scratch: ScratchDirectory!
    private var store: TokenStore!
    private var authorizer: ServerAuthorizer!
    private var secret: String!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory("ServerAuthorizerTests")
        store = try TokenStore.open(at: scratch.tokens)
        (_, secret) = try store.add(name: "admin", rights: [.admin])
        authorizer = ServerAuthorizer(tokens: store)
    }

    override func tearDownWithError() throws {
        scratch.cleanedUp()
    }

    private func request(_ method: String, _ path: String,
                         headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers)
    }

    func testABearerIsAcceptedOnAnyPath() async throws {
        let principal = try authorizer.principal(for: request(
            "GET", "/cas/v1/hello", headers: ["authorization": "Bearer \(secret!)"]))
        XCTAssertEqual(principal.name, "admin")
        do {
            _ = try authorizer.principal(for: request(
                "GET", "/cas/v1/hello", headers: ["authorization": "Bearer wrong"]))
            XCTFail("accepted a wrong secret")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, .unauthorized)
        }
    }

    func testWithoutABearerOnlyTheConsoleIsReachableAndOnlySignedIn() async throws {
        for path in ["/cas/v1/hello", "/ghidra/v1/modules", "/"] {
            do {
                _ = try authorizer.principal(for: request("GET", path))
                XCTFail("served \(path) without a token")
            } catch let error as HTTPError {
                XCTAssertEqual(error.status, .unauthorized)
            }
        }
        do {
            _ = try authorizer.principal(for: request("GET", "/admin/documents"))
            XCTFail("opened the console without a session")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, .unauthorized)
        }
    }

    func testACookieSessionOpensTheConsoleAndNothingElse() async throws {
        let principal = try XCTUnwrap(store.principal(for: secret))
        let session = try authorizer.signIn(secret: secret)
        let cookie = "\(AdminCookie.session)=\(session.id); \(AdminCookie.csrf)=\(session.csrf)"

        let page = try authorizer.principal(for: request("GET", "/admin", headers: ["cookie": cookie]))
        XCTAssertEqual(page.id, principal.id)

        do {
            // The browser carries the cookie to whatever the address serves;
            // the store is not one of the console's pages.
            _ = try authorizer.principal(for: request("GET", "/cas/v1/hello", headers: ["cookie": cookie]))
            XCTFail("a console cookie opened the store")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, .unauthorized)
        }
    }

    func testAConsoleFormNeedsTheCsrfValueTwice() async throws {
        let principal = try XCTUnwrap(store.principal(for: secret))
        let session = try authorizer.signIn(secret: secret)
        let cookie = "\(AdminCookie.session)=\(session.id); \(AdminCookie.csrf)=\(session.csrf)"
        let headers = ["cookie": cookie, AdminCookie.header: session.csrf]

        _ = try authorizer.principal(for: request("POST", "/admin/api/tokens", headers: headers))
        for wrong in [["cookie": cookie],
                      ["cookie": cookie, AdminCookie.header: "nope"],
                      ["cookie": "\(AdminCookie.session)=\(session.id)", AdminCookie.header: session.csrf]] {
            do {
                _ = try authorizer.principal(for: request("POST", "/admin/api/tokens", headers: wrong))
                XCTFail("accepted a form without its CSRF value")
            } catch let error as HTTPError {
                XCTAssertEqual(error.status, .forbidden)
            }
        }
    }

    /// A revoked token's console session ends with it.
    func testARevokedTokenClosesItsConsoleSession() async throws {
        let principal = try XCTUnwrap(store.principal(for: secret))
        let session = try authorizer.signIn(secret: secret)
        let cookie = "\(AdminCookie.session)=\(session.id)"
        try store.revoke(principal.id)
        do {
            _ = try authorizer.principal(for: request("GET", "/admin", headers: ["cookie": cookie]))
            XCTFail("served the console on a revoked token")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, .unauthorized)
        }
        XCTAssertEqual(authorizer.sessions.count, 0)
    }

    /// A rotated secret ends the console sessions it signed in: a secret is
    /// rotated because it got out.
    func testARotatedTokenClosesItsConsoleSession() async throws {
        let session = try authorizer.signIn(secret: secret)
        let cookie = "\(AdminCookie.session)=\(session.id)"
        _ = try authorizer.principal(for: request("GET", "/admin", headers: ["cookie": cookie]))
        let rotated = try store.rotate("admin")
        do {
            _ = try authorizer.principal(for: request("GET", "/admin", headers: ["cookie": cookie]))
            XCTFail("served the console on a rotated secret's session")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, .unauthorized)
        }
        let again = try authorizer.signIn(secret: rotated)
        _ = try authorizer.principal(for: request("GET", "/admin", headers: ["cookie": "\(AdminCookie.session)=\(again.id)"]))
    }

    /// Only an admin token signs in to the console.
    func testOnlyAnAdminTokenSignsIn() throws {
        let (_, app) = try store.add(name: "app", rights: TokenPreset.app.rights)
        XCTAssertThrowsError(try authorizer.signIn(secret: app)) { error in
            XCTAssertEqual((error as? HTTPError)?.status, .forbidden)
        }
        XCTAssertThrowsError(try authorizer.signIn(secret: "nope")) { error in
            XCTAssertEqual((error as? HTTPError)?.status, .unauthorized)
        }
    }

    func testASessionEndsAtSignOut() async throws {
        let principal = try XCTUnwrap(store.principal(for: secret))
        let session = try authorizer.signIn(secret: secret)
        authorizer.sessions.end(session.id)
        XCTAssertNil(authorizer.sessions.session(session.id))
    }

    /// The console's sessions are kept beside the tokens: stopping the server
    /// does not sign the operator out. What the file holds is the hash of each
    /// session id, never the id itself — a copy of it cannot sign in.
    func testASessionOutlivesTheServer() throws {
        let file = scratch.tokens.deletingLastPathComponent().appendingPathComponent("sessions.json")
        let first = ServerAuthorizer(tokens: store, sessions: AdminSessions(file: file))
        let session = try first.signIn(secret: secret)

        let reopened = ServerAuthorizer(tokens: store, sessions: AdminSessions(file: file))
        XCTAssertNotNil(reopened.sessions.session(session.id), "a restart keeps the session")
        XCTAssertNotNil(try reopened.principal(for: request(
            "GET", "/admin", headers: ["cookie": "\(AdminCookie.session)=\(session.id)"])))

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(session.id), "the file holds the id's hash, not the id")
        XCTAssertTrue(text.contains("tokenHash"))
    }

    /// Signing out reaches the file: the session does not come back with the
    /// next start.
    func testSigningOutReachesTheFile() throws {
        let file = scratch.tokens.deletingLastPathComponent().appendingPathComponent("sessions.json")
        let sessions = AdminSessions(file: file)
        let session = try ServerAuthorizer(tokens: store, sessions: sessions).signIn(secret: secret)
        sessions.end(session.id)
        XCTAssertNil(AdminSessions(file: file).session(session.id))
    }

    /// Revoking a token ends its sessions in the file too: a revocation is
    /// what a leaked secret gets, and it must not need the browser to ask.
    func testRevokingATokenDropsItsSessionsFromTheFile() throws {
        let file = scratch.tokens.deletingLastPathComponent().appendingPathComponent("sessions.json")
        let sessions = AdminSessions(file: file)
        let session = try ServerAuthorizer(tokens: store, sessions: sessions).signIn(secret: secret)
        let principal = try XCTUnwrap(store.principal(for: secret))
        sessions.end(principal: principal.id)
        XCTAssertNil(AdminSessions(file: file).session(session.id))
    }
}

final class TokenCommandTests: XCTestCase {
    private var scratch: ScratchDirectory!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory("TokenCommandTests")
    }

    override func tearDownWithError() throws {
        scratch.cleanedUp()
    }

    func testAddMakesAOneTimeSecretWithItsRights() throws {
        let command = try TokenCommand.parse(["add", "--name", "admin", "--rights", "admin",
                                              "--tokens", scratch.tokens.path],
                                             defaultFile: scratch.tokens)
        let output = try command.run()
        let secret = try XCTUnwrap(output.split(separator: "\n").first.map(String.init))
        XCTAssertEqual(secret.count, 43)
        let store = try TokenStore.open(at: scratch.tokens)
        let principal = try XCTUnwrap(store.principal(for: secret))
        XCTAssertEqual(principal.rights, [.casRead, .admin])
        XCTAssertTrue(principal.allows(.casWrite) && principal.allows(.ghidraUse),
                      "admin carries every other right")
    }

    func testAPresetNamesTheRights() throws {
        guard case .add(let name, let rights, _) = try TokenCommand.parse(
            ["add", "--name", "laptop", "--preset", "app"], defaultFile: scratch.tokens) else {
            return XCTFail()
        }
        XCTAssertEqual(name, "laptop")
        XCTAssertEqual(rights, [.casRead, .casWrite, .ghidraUse])
    }

    func testWhatIsRefused() {
        XCTAssertThrowsError(try TokenCommand.parse([], defaultFile: scratch.tokens))
        XCTAssertThrowsError(try TokenCommand.parse(["add"], defaultFile: scratch.tokens))
        XCTAssertThrowsError(try TokenCommand.parse(["add", "--name", "a", "--rights", "frobnicate"],
                                                    defaultFile: scratch.tokens))
        XCTAssertThrowsError(try TokenCommand.parse(["add", "--name", "a", "--rights", "admin",
                                                     "--preset", "app"], defaultFile: scratch.tokens))
        XCTAssertThrowsError(try TokenCommand.parse(["rotate"], defaultFile: scratch.tokens))
        XCTAssertThrowsError(try TokenCommand.parse(["frobnicate"], defaultFile: scratch.tokens))
    }

    /// `list` never shows a secret or a hash.
    func testTheListNamesNoSecret() throws {
        let (token, secret) = try TokenStore.open(at: scratch.tokens).add(name: "admin", rights: [.admin])
        let listed = try TokenCommand.parse(["list", "--tokens", scratch.tokens.path],
                                            defaultFile: scratch.tokens).run()
        XCTAssertTrue(listed.contains(token.id))
        XCTAssertTrue(listed.contains("admin"))
        XCTAssertFalse(listed.contains(secret))
        XCTAssertFalse(listed.contains(TokenStore.hash(secret)))
    }

    func testRevokeAndRotateByID() throws {
        let store = try TokenStore.open(at: scratch.tokens)
        let (token, secret) = try store.add(name: "app", rights: [.casWrite])

        let rotated = try TokenCommand.parse(["rotate", token.id, "--tokens", scratch.tokens.path],
                                             defaultFile: scratch.tokens).run()
        let newSecret = try XCTUnwrap(rotated.split(separator: "\n").first.map(String.init))
        XCTAssertNotEqual(newSecret, secret)
        XCTAssertNil(store.principal(for: secret))
        XCTAssertNotNil(store.principal(for: newSecret))

        _ = try TokenCommand.parse(["revoke", token.id], defaultFile: scratch.tokens).run()
        XCTAssertNil(store.principal(for: newSecret))
    }
}
