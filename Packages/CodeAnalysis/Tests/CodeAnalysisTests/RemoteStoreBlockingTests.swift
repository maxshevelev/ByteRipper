import XCTest
@testable import CodeAnalysis

/// `objectBlocking` is called from inside tasks, each blocking a thread of the
/// cooperative pool; its wait must not need that pool.
final class RemoteStoreBlockingTests: XCTestCase {
    private let payload = Data("an object".utf8)

    private func store() -> RemoteStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedServer.self]
        return RemoteStore(base: URL(string: "http://stub.invalid")!, token: nil,
                           session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        StubbedServer.answer = nil
    }

    func testFetchesTheObject() throws {
        let payload = self.payload
        StubbedServer.answer = { _ in (200, payload) }
        XCTAssertEqual(try store().objectBlocking(SHA256Digest(data: payload)), payload)
    }

    func testAnObjectThatIsNotItsDigestIsCorrupt() {
        StubbedServer.answer = { _ in (200, Data("another".utf8)) }
        let digest = SHA256Digest(data: payload)
        XCTAssertThrowsError(try store().objectBlocking(digest)) { error in
            XCTAssertEqual(error as? CodeAnalysisError, .objectCorrupt(digest.hex))
        }
    }

    func testARefusalKeepsTheServersWords() {
        StubbedServer.answer = { _ in (404, Data(#"{"error":"no such object"}"#.utf8)) }
        XCTAssertThrowsError(try store().objectBlocking(SHA256Digest(data: payload))) { error in
            XCTAssertEqual(error as? RemoteStore.Failure,
                           .refused(status: 404, message: "no such object", rights: []))
        }
    }

    /// More waits than the pool has threads: at the priority the app reads at,
    /// and at the default, which is the one a task-based wait would starve at.
    func testAFullCooperativePoolStillGetsItsAnswers() {
        let payload = self.payload
        let digest = SHA256Digest(data: payload)
        StubbedServer.answer = { _ in (200, payload) }
        let store = store()
        for priority in [TaskPriority.userInitiated, nil] {
            let count = ProcessInfo.processInfo.activeProcessorCount * 3
            let answered = expectation(description: "every wait answered")
            answered.expectedFulfillmentCount = count
            for _ in 0..<count {
                Task.detached(priority: priority) {
                    if (try? store.objectBlocking(digest)) == payload { answered.fulfill() }
                }
            }
            wait(for: [answered], timeout: 30)
        }
    }
}

private final class StubbedServer: URLProtocol {
    nonisolated(unsafe) static var answer: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.answer!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
