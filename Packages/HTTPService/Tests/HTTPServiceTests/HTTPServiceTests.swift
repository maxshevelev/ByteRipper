import XCTest
@testable import HTTPService

final class HTTPParserTests: XCTestCase {
    func testARequestSplitAcrossReadsIsReadWhole() {
        var parser = HTTPParser(maxBodyBytes: 100)
        let wire = Data("POST /cas/v1/objects/ab%20c?wait=5&x HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello".utf8)
        for byte in wire.dropLast() {
            parser.feed(Data([byte]))
            XCTAssertEqual(parser.next(), .needMore)
        }
        parser.feed(Data([wire.last!]))
        guard case .request(let request) = parser.next() else { return XCTFail("no request") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/cas/v1/objects/ab c")
        XCTAssertEqual(request.query, ["wait": "5", "x": ""])
        XCTAssertEqual(request.headers["content-length"], "5")
        XCTAssertEqual(request.body, Data("hello".utf8))
        XCTAssertEqual(parser.next(), .needMore)
    }

    func testTwoRequestsInOneReadAreTwoRequests() {
        var parser = HTTPParser(maxBodyBytes: 100)
        parser.feed(Data("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n".utf8))
        guard case .request(let first) = parser.next(), case .request(let second) = parser.next() else {
            return XCTFail("not two requests")
        }
        XCTAssertEqual([first.path, second.path], ["/a", "/b"])
    }

    func testWhatTheParserRefuses() {
        func refusal(_ text: String, maxBody: Int = 10) -> Int? {
            var parser = HTTPParser(maxBodyBytes: maxBody)
            parser.feed(Data(text.utf8))
            if case .refused(let status, _) = parser.next() { return status.code }
            return nil
        }
        XCTAssertEqual(refusal("GET /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 411)
        XCTAssertEqual(refusal("GET /a HTTP/1.1\r\nContent-Length: 11\r\n\r\n"), 413)
        XCTAssertEqual(refusal("GET /a HTTP/1.1\r\nContent-Length: x\r\n\r\n"), 400)
        XCTAssertEqual(refusal("GARBAGE\r\n\r\n"), 400)
        XCTAssertEqual(refusal("GET /a HTTP/1.1\r\nno colon\r\n\r\n"), 400)
        var parser = HTTPParser(maxBodyBytes: 10)
        parser.maxHeaderBytes = 16
        parser.feed(Data("GET /a HTTP/1.1\r\nX: 0123456789\r\n".utf8))
        guard case .refused(let status, _) = parser.next() else { return XCTFail("not refused") }
        XCTAssertEqual(status.code, 431)
    }
}

final class HTTPRouterTests: XCTestCase {
    func testParametersMethodsAndTheRest() async {
        var router = HTTPRouter()
        router.add("GET", "/cas/v1/objects/:sha") { .bytes(Data($0.parameters["sha"]!.utf8)) }
        router.add("POST", "/files/*rest") { .bytes(Data($0.parameters["rest"]!.utf8)) }
        router.add("GET", "/fails") { _ in throw HTTPError(.conflict, "no") }

        let object = await router.handle(HTTPRequest(method: "GET", path: "/cas/v1/objects/ab"))
        XCTAssertEqual(String(data: object.body, encoding: .utf8), "ab")
        let head = await router.handle(HTTPRequest(method: "HEAD", path: "/cas/v1/objects/ab"))
        XCTAssertEqual(head.status, .ok)
        XCTAssertEqual(head.headers["content-length"], "2")
        XCTAssertTrue(head.body.isEmpty)
        let rest = await router.handle(HTTPRequest(method: "POST", path: "/files/a/b/c"))
        XCTAssertEqual(String(data: rest.body, encoding: .utf8), "a/b/c")
        let wrongMethod = await router.handle(HTTPRequest(method: "PUT", path: "/cas/v1/objects/ab"))
        XCTAssertEqual(wrongMethod.status.code, 405)
        let missing = await router.handle(HTTPRequest(method: "GET", path: "/cas/v1/objects"))
        XCTAssertEqual(missing.status.code, 404)
        let refused = await router.handle(HTTPRequest(method: "GET", path: "/fails"))
        XCTAssertEqual(refused.status.code, 409)
        XCTAssertEqual(String(data: refused.body, encoding: .utf8), #"{"error":"no"}"#)
    }
}

final class HTTPServerTests: XCTestCase {
    private func serve(token: String? = nil, _ add: (inout HTTPRouter) -> Void) async throws -> (HTTPServer, URL) {
        var router = HTTPRouter()
        add(&router)
        let server = HTTPServer(configuration: .init(port: 0, token: token, maxBodyBytes: 1024),
                                router: router)
        let port = try await server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    private func call(_ url: URL, method: String = "GET", body: Data? = nil,
                      token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func testAServedRouteAnswersOverLoopbackWithKeepAlive() async throws {
        let (server, base) = try await serve { router in
            router.add("POST", "/echo") { .bytes($0.body) }
        }
        defer { server.stop() }
        for text in ["one", "two", "three"] {
            let (status, data) = try await call(base.appendingPathComponent("echo"), method: "POST",
                                                body: Data(text.utf8))
            XCTAssertEqual(status, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), text)
        }
        let (status, _) = try await call(base.appendingPathComponent("echo"), method: "POST",
                                         body: Data(count: 2048))
        XCTAssertEqual(status, 413)
    }

    func testATokenIsRequiredWhenSet() async throws {
        let (server, base) = try await serve(token: "s3cret") { router in
            router.add("GET", "/hello") { _ in .json(["ok": true]) }
        }
        defer { server.stop() }
        let url = base.appendingPathComponent("hello")
        let missing = try await call(url)
        XCTAssertEqual(missing.0, 401)
        let wrong = try await call(url, token: "s3cres")
        XCTAssertEqual(wrong.0, 401)
        let right = try await call(url, token: "s3cret")
        XCTAssertEqual(right.0, 200)
    }

    func testANetworkAddressWithoutATokenIsRefused() async {
        let server = HTTPServer(configuration: .init(host: "0.0.0.0", port: 0), router: HTTPRouter())
        do {
            try await server.start()
            XCTFail("started without a token")
        } catch let error as HTTPServer.StartError {
            XCTAssertEqual(error, .tokenRequired("0.0.0.0"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testASlowHandlerHoldsOnlyItsOwnConnection() async throws {
        let (server, base) = try await serve { router in
            router.add("GET", "/slow") { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return .json(["slow": true])
            }
            router.add("GET", "/fast") { _ in .json(["fast": true]) }
        }
        defer { server.stop() }
        let slow = Task { try await self.call(base.appendingPathComponent("slow")) }
        let started = Date()
        let fast = try await call(base.appendingPathComponent("fast"))
        XCTAssertEqual(fast.0, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        let slowAnswer = try await slow.value
        XCTAssertEqual(slowAnswer.0, 200)
    }

    func testTheTokenComparisonNeedsEveryByte() {
        XCTAssertTrue(HTTPServer.authorized("Bearer abc", token: "abc"))
        XCTAssertFalse(HTTPServer.authorized("Bearer abcd", token: "abc"))
        XCTAssertFalse(HTTPServer.authorized("Bearer ab", token: "abc"))
        XCTAssertFalse(HTTPServer.authorized("Basic abc", token: "abc"))
        XCTAssertFalse(HTTPServer.authorized(nil, token: "abc"))
    }
}
