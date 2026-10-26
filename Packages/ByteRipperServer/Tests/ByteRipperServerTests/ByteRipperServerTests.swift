import CodeAnalysis
import Foundation
import XCTest
@testable import ByteRipperServer

final class ServerCommandTests: XCTestCase {
    func testTheDefaultsServeTheStoreOnLoopback() throws {
        guard case .serve(let configuration) = try ServerCommand.parse([]) else { return XCTFail() }
        XCTAssertEqual(configuration.roles, [.cas])
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8765)
        XCTAssertEqual(configuration.store, CodeAnalysisPaths.defaultRoot)
        XCTAssertFalse(configuration.tokenRequired)
    }

    func testAnAddressAStoreAndATokenFile() throws {
        let parsed = try ServerCommand.parse(["serve", "--cas", "--listen", "100.64.1.2:9000",
                                              "--store", "/tmp/s", "--token-file", "/tmp/t"])
        guard case .serve(let configuration) = parsed else { return XCTFail() }
        XCTAssertEqual(configuration.host, "100.64.1.2")
        XCTAssertEqual(configuration.port, 9000)
        XCTAssertEqual(configuration.store.path, "/tmp/s")
        XCTAssertEqual(configuration.tokenFile.path, "/tmp/t")
        XCTAssertTrue(configuration.tokenRequired)
        guard case .serve(let ipv6) = try ServerCommand.parse(["--listen", "[::1]:8765"]) else { return XCTFail() }
        XCTAssertEqual(ipv6.host, "::1")
    }

    func testWhatIsRefused() {
        XCTAssertThrowsError(try ServerCommand.parse(["--ghidra"]))
        XCTAssertThrowsError(try ServerCommand.parse(["--listen", "nowhere"]))
        XCTAssertThrowsError(try ServerCommand.parse(["--store"]))
        XCTAssertThrowsError(try ServerCommand.parse(["--bogus"]))
        XCTAssertThrowsError(try ServerCommand.parse(["frobnicate"]))
        XCTAssertEqual(try ServerCommand.parse(["token", "--replace"]),
                       .token(file: ServerPaths.defaultTokenFile, replace: true))
    }
}

final class TokenFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testATokenIsMadeOnlyItsOwnerMayReadAndReadBack() throws {
        let url = directory.appendingPathComponent("token")
        let token = try TokenFile.make(at: url)
        XCTAssertEqual(token.count, 43)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertEqual(try TokenFile.read(at: url), token)
        XCTAssertThrowsError(try TokenFile.make(at: url))
        XCTAssertNotEqual(try TokenFile.make(at: url, replace: true), token)
    }

    func testAFileOthersMayReadIsRefusedAndNoFileIsNoToken() throws {
        let url = directory.appendingPathComponent("token")
        XCTAssertNil(try TokenFile.read(at: url))
        try TokenFile.make(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try TokenFile.read(at: url)) { error in
            XCTAssertEqual(error as? TokenFile.Failure, .readableByOthers(url.path))
        }
    }
}

final class ServerTests: XCTestCase {
    func testTheServerServesItsStoreBehindItsToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = ServerConfiguration()
        configuration.port = 0
        configuration.store = directory.appendingPathComponent("store")
        configuration.tokenFile = directory.appendingPathComponent("token")
        let token = try TokenFile.make(at: configuration.tokenFile)
        let lines = Lines()
        let server = Server(configuration: configuration, log: { lines.add($0) })
        let port = try await server.start()
        defer { server.stop() }

        let remote = RemoteStore(base: URL(string: "http://127.0.0.1:\(port)")!, token: token)
        let hello = try await remote.hello()
        XCTAssertEqual(hello.store, try ContentStore(root: configuration.store).identity())
        XCTAssertTrue(lines.all.contains { $0.contains("GET /cas/v1/hello 200") }, "\(lines.all)")
        do {
            _ = try await RemoteStore(base: remote.base, token: "wrong").hello()
            XCTFail("answered a wrong token")
        } catch RemoteStore.Failure.refused(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    func testANamedTokenFileMustExist() async throws {
        var configuration = ServerConfiguration()
        configuration.port = 0
        configuration.store = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID())")
        configuration.tokenFile = URL(fileURLWithPath: "/nonexistent/token")
        configuration.tokenRequired = true
        defer { try? FileManager.default.removeItem(at: configuration.store) }
        do {
            try await Server(configuration: configuration, log: { _ in }).start()
            XCTFail("started without its token file")
        } catch {
            XCTAssertTrue("\(error)".contains("does not exist"))
        }
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
