import XCTest
@testable import AgentKit

final class UnixSocketTests: XCTestCase {
    private var folder: String!

    override func setUp() {
        super.setUp()
        // Short on purpose: a socket path has to fit in 104 bytes.
        folder = "/tmp/ak-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private var path: String { folder + "/agent.sock" }

    /// Reads from `fd` until `count` bytes have come or a second has passed.
    private func read(_ fd: Int32, count: Int) -> Data {
        var received = Data()
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while received.count < count, let chunk = UnixSocket.readSome(fd) {
            received.append(chunk)
        }
        return received
    }

    func testAClientsBytesReachTheConnectionAndItsAnswerComesBack() throws {
        let listener = UnixSocketListener(path: path)
        try listener.start { connection in
            connection.startReading(onData: { connection.write(Data("echo:".utf8) + $0) }, onClose: {})
        }
        defer { listener.stop() }

        let fd = try UnixSocket.connect(to: path)
        defer { close(fd) }
        XCTAssertTrue(UnixSocket.writeAll(fd, Data("ping\n".utf8)))
        XCTAssertEqual(String(decoding: read(fd, count: 10), as: UTF8.self), "echo:ping\n")
    }

    func testOnlyTheOwnerMayOpenTheSocket() throws {
        let listener = UnixSocketListener(path: path)
        try listener.start { _ in }
        defer { listener.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// A second copy of the app must not take the first one's clients away.
    func testASocketSomethingStillAnswersOnIsNotTakenOver() throws {
        let first = UnixSocketListener(path: path)
        try first.start { _ in }
        defer { first.stop() }
        XCTAssertThrowsError(try UnixSocketListener(path: path).start { _ in }) {
            XCTAssertEqual($0 as? UnixSocket.Failure, .inUse(path))
        }
    }

    /// What a crash leaves behind is a file nobody answers on; it is replaced.
    func testASocketFileLeftByAProcessThatHasGoneIsReplaced() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
        let listener = UnixSocketListener(path: path)
        try listener.start { _ in }
        defer { listener.stop() }
        let fd = try UnixSocket.connect(to: path)
        close(fd)
    }

    func testStoppingRemovesTheFileAndRefusesNewClients() throws {
        let listener = UnixSocketListener(path: path)
        try listener.start { _ in }
        listener.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try UnixSocket.connect(to: path))
        // And the path can be listened on again straight away.
        let again = UnixSocketListener(path: path)
        try again.start { _ in }
        again.stop()
    }

    /// A client that closes is reported, once.
    func testAClosingClientIsReported() throws {
        let closed = expectation(description: "closed")
        let listener = UnixSocketListener(path: path)
        try listener.start { connection in
            connection.startReading(onData: { _ in }, onClose: { closed.fulfill() })
        }
        defer { listener.stop() }
        let fd = try UnixSocket.connect(to: path)
        close(fd)
        wait(for: [closed], timeout: 2)
    }

    /// Writing to a client that has gone fails quietly rather than raising
    /// SIGPIPE, which would end the whole app.
    func testWritingToAClientThatHasGoneDoesNotEndTheProcess() throws {
        let accepted = expectation(description: "accepted")
        let box = Box()
        let listener = UnixSocketListener(path: path)
        try listener.start { connection in
            box.connection = connection
            accepted.fulfill()
        }
        defer { listener.stop() }
        let fd = try UnixSocket.connect(to: path)
        wait(for: [accepted], timeout: 2)
        close(fd)
        for _ in 0..<50 { box.connection?.write(Data(repeating: 0x41, count: 64 << 10)) }
        Thread.sleep(forTimeInterval: 0.2)
    }

    func testAPathTooLongForTheKernelIsRefusedByName() {
        let long = "/tmp/" + String(repeating: "x", count: 120)
        XCTAssertThrowsError(try UnixSocket.connect(to: long)) {
            XCTAssertEqual($0 as? UnixSocket.Failure, .pathTooLong(long))
        }
    }
}

private final class Box: @unchecked Sendable {
    var connection: UnixSocketConnection?
}
