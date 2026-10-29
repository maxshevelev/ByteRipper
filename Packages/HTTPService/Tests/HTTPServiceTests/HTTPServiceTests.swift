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

    /// A route may take more than the parser's default, and only it
    /// (`Design/SERVER_HEADLESS_PLAN.md` §5, decision 12).
    func testARouteNamesItsOwnBodyLimit() {
        let upload: @Sendable (HTTPRequest) -> HTTPParser.Admission = { head in
            .admit(maxBodyBytes: head.method == "POST" && head.path == "/upload" ? 4096 : nil, principal: nil)
        }
        var parser = HTTPParser(maxBodyBytes: 10, admit: upload)
        parser.feed(Data("POST /upload HTTP/1.1\r\nContent-Length: 3000\r\n\r\n".utf8))
        XCTAssertEqual(parser.next(), .needMore)
        parser.feed(Data(count: 3000))
        guard case .request(let read) = parser.next() else { return XCTFail("the upload was not read") }
        XCTAssertEqual(read.body.count, 3000)

        for text in ["POST /upload HTTP/1.1\r\nContent-Length: 4097\r\n\r\n",
                     "POST /other HTTP/1.1\r\nContent-Length: 11\r\n\r\n"] {
            var refusing = HTTPParser(maxBodyBytes: 10, admit: upload)
            refusing.feed(Data(text.utf8))
            guard case .refused(let status, _) = refusing.next() else { return XCTFail("not refused: \(text)") }
            XCTAssertEqual(status.code, 413)
        }
    }
}

extension HTTPParserTests {
    /// A request the server will not serve is refused on its headers: the
    /// body is never waited for, so a stranger cannot make the server hold
    /// one (`Design/SERVER_HEADLESS_PLAN.md` §5).
    func testARefusedRequestIsAnsweredBeforeItsBody() {
        let nobody: @Sendable (HTTPRequest) -> HTTPParser.Admission = { _ in
            .refuse(HTTPError(.unauthorized, "a bearer token is required"))
        }
        var parser = HTTPParser(maxBodyBytes: 1 << 30, admit: nobody)
        parser.feed(Data("PUT /cas/v1/objects/ab HTTP/1.1\r\nContent-Length: 536870912\r\n\r\n".utf8))
        guard case .denied(let head, let error, let canContinue) = parser.next() else {
            return XCTFail("waited for the body")
        }
        XCTAssertEqual(head.path, "/cas/v1/objects/ab")
        XCTAssertEqual(error.status, .unauthorized)
        XCTAssertFalse(canContinue, "an unread body ends the connection")

        var bodyless = HTTPParser(maxBodyBytes: 10, admit: nobody)
        bodyless.feed(Data("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n".utf8))
        guard case .denied(_, _, true) = bodyless.next(),
              case .denied(let second, _, true) = bodyless.next() else {
            return XCTFail("a request without a body did not let the next one follow")
        }
        XCTAssertEqual(second.path, "/b")
    }

    /// The answer is asked once per request, however many reads its body takes.
    func testAdmissionIsAskedOncePerRequest() {
        let asked = Counter()
        var parser = HTTPParser(maxBodyBytes: 100, admit: { _ in
            asked.increment()
            return .admit(maxBodyBytes: nil, principal: .all())
        })
        parser.feed(Data("POST /a HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8))
        XCTAssertEqual(parser.next(), .needMore)
        parser.feed(Data("ab".utf8))
        XCTAssertEqual(parser.next(), .needMore)
        parser.feed(Data("cd".utf8))
        guard case .request(let request) = parser.next() else { return XCTFail("no request") }
        XCTAssertEqual(request.principal?.name, "test")
        XCTAssertEqual(asked.value, 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
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
    private func serve(token: String = "s3cret", onRequest: (@Sendable (HTTPActivity) -> Void)? = nil,
                       _ add: (inout HTTPRouter) -> Void) async throws -> (HTTPServer, URL) {
        var router = HTTPRouter()
        add(&router)
        let server = HTTPServer(configuration: .init(port: 0, token: token, maxBodyBytes: 1024,
                                                     onRequest: onRequest),
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
                                                body: Data(text.utf8), token: "s3cret")
            XCTAssertEqual(status, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), text)
        }
        let (status, _) = try await call(base.appendingPathComponent("echo"), method: "POST",
                                         body: Data(count: 2048), token: "s3cret")
        XCTAssertEqual(status, 413)
    }

    /// No anonymous mode, on loopback too (`Design/SERVER_HEADLESS_PLAN.md`
    /// decision 3): a request without the bearer is refused before any route
    /// sees it.
    func testATokenIsRequiredOnEveryAddress() async throws {
        let (server, base) = try await serve { router in
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

    /// The principal the authorizer names reaches the route, and the rights
    /// it does not give are named in the refusal.
    func testTheRouteSeesThePrincipalAndItsRefusalNamesTheRight() async throws {
        struct Reader: HTTPAuthorizer {
            func principal(for request: HTTPRequest) throws -> HTTPPrincipal {
                HTTPPrincipal(id: "t1", name: "laptop", rights: [.casRead])
            }
        }
        var router = HTTPRouter()
        router.add("GET", "/who") { request in
            .bytes(Data((request.principal?.name ?? "nobody").utf8))
        }
        router.add("PUT", "/store", access: .rights([.casWrite])) { _ in .json(["stored": true]) }
        let server = HTTPServer(configuration: .init(port: 0, authorizer: Reader()), router: router)
        let base = URL(string: "http://127.0.0.1:\(try await server.start())")!
        defer { server.stop() }

        let (who, name) = try await call(base.appendingPathComponent("who"))
        XCTAssertEqual(who, 200)
        XCTAssertEqual(String(data: name, encoding: .utf8), "laptop")
        let (refused, body) = try await call(base.appendingPathComponent("store"), method: "PUT")
        XCTAssertEqual(refused, 403)
        XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("cas.write"))
        // The right is an answer field, not only a word of the sentence: a
        // client says which right to add without reading English.
        let named = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(named["right"] as? String, "cas.write")
    }

    /// Every answer, a refusal included, is one activity value — the seam the
    /// console's REST rows are built on (`Design/SERVER_HEADLESS_PLAN.md` §5).
    func testEveryAnswerIsAnActivityValue() async throws {
        let seen = Activities()
        let (server, base) = try await serve(onRequest: { seen.add($0) }) { router in
            router.add("GET", "/hello") { _ in .json(["ok": true]) }
        }
        defer { server.stop() }
        _ = try await call(base.appendingPathComponent("hello"), token: "s3cret")
        _ = try await call(base.appendingPathComponent("hello"))
        let all = seen.all
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].method, "GET")
        XCTAssertEqual(all[0].path, "/hello")
        XCTAssertEqual(all[0].status, .ok)
        XCTAssertEqual(all[0].principal?.name, "test")
        XCTAssertEqual(all[1].status, .unauthorized)
        XCTAssertNil(all[1].principal)
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
        let slow = Task { try await self.call(base.appendingPathComponent("slow"), token: "s3cret") }
        let started = Date()
        let fast = try await call(base.appendingPathComponent("fast"), token: "s3cret")
        XCTAssertEqual(fast.0, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        let slowAnswer = try await slow.value
        XCTAssertEqual(slowAnswer.0, 200)
    }

    /// A name is resolved, and the listener takes the port asked for on that
    /// address — not every interface and a port of the system's choosing.
    func testAHostNameListensOnItsAddressAndTheGivenPort() async throws {
        let name = ProcessInfo.processInfo.hostName
        guard let address = try? HTTPServer.resolve(name) else { throw XCTSkip("\(name) does not resolve here") }
        XCTAssertEqual(try HTTPServer.resolve("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(try HTTPServer.resolve("localhost"), "127.0.0.1")
        XCTAssertThrowsError(try HTTPServer.resolve("no-such-host.invalid"))

        let port = UInt16.random(in: 40000...49000)
        var router = HTTPRouter()
        router.add("GET", "/hello") { _ in .json(["ok": true]) }
        let server = HTTPServer(configuration: .init(host: name, port: port, token: "t"), router: router)
        let listening = try await server.start()
        defer { server.stop() }
        XCTAssertEqual(listening, port)
        XCTAssertEqual(server.boundAddress, address)
        let host = address.contains(":") ? "[\(address)]" : address
        let (status, _) = try await call(URL(string: "http://\(host):\(port)/hello")!, token: "t")
        XCTAssertEqual(status, 200)
    }

    /// A route takes more than the parser's default, over the wire, and the
    /// other routes keep the default (`Design/SERVER_HEADLESS_PLAN.md`
    /// decision 12).
    func testAnUploadRouteTakesMoreThanTheOthers() async throws {
        let (server, base) = try await serve { router in
            router.add("POST", "/upload", maxBodyBytes: 4096) { .json(["bytes": $0.body.count]) }
            router.add("POST", "/echo") { .json(["bytes": $0.body.count]) }
        }
        defer { server.stop() }
        let upload = try await call(base.appendingPathComponent("upload"), method: "POST",
                                    body: Data(count: 3000), token: "s3cret")
        XCTAssertEqual(upload.0, 200)
        let echo = try await call(base.appendingPathComponent("echo"), method: "POST",
                                  body: Data(count: 3000), token: "s3cret")
        XCTAssertEqual(echo.0, 413)
    }

    /// An open route is served without a token, and only it; a route that
    /// names rights refuses a request no server authorized.
    func testAnOpenRouteNeedsNoTokenAndARightsRouteNeedsAPrincipal() async throws {
        let (server, base) = try await serve { router in
            router.add("GET", "/admin/login", access: .open) { request in
                .bytes(Data((request.principal?.name ?? "nobody").utf8))
            }
            router.add("GET", "/admin") { _ in .json(["ok": true]) }
        }
        defer { server.stop() }
        let (login, body) = try await call(base.appendingPathComponent("admin/login"))
        XCTAssertEqual(login, 200)
        XCTAssertEqual(String(data: body, encoding: .utf8), "nobody")
        let (console, _) = try await call(base.appendingPathComponent("admin"))
        XCTAssertEqual(console, 401)

        var router = HTTPRouter()
        router.add("PUT", "/store", access: .rights([.casWrite])) { _ in .json(["stored": true]) }
        let direct = await router.handle(HTTPRequest(method: "PUT", path: "/store"))
        XCTAssertEqual(direct.status, .unauthorized)
        let granted = await router.handle(HTTPRequest(method: "PUT", path: "/store", principal: .all()))
        XCTAssertEqual(granted.status, .ok)
    }

    func testTheTokenComparisonNeedsEveryByte() {
        XCTAssertTrue(HTTPBearer.matches("Bearer abc", token: "abc"))
        XCTAssertFalse(HTTPBearer.matches("Bearer abcd", token: "abc"))
        XCTAssertFalse(HTTPBearer.matches("Bearer ab", token: "abc"))
        XCTAssertFalse(HTTPBearer.matches("Basic abc", token: "abc"))
        XCTAssertFalse(HTTPBearer.matches(nil, token: "abc"))
        XCTAssertEqual(HTTPBearer.token("Bearer abc"), "abc")
        XCTAssertEqual(HTTPBearer.token("bearer abc"), "abc", "the scheme's name is matched in any case")
        XCTAssertNil(HTTPBearer.token("Bearer "))
        XCTAssertNil(HTTPBearer.token("Basic abc"))
    }
}

/// What the server reported, in order, from any thread.
final class Activities: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HTTPActivity] = []
    func add(_ activity: HTTPActivity) { lock.lock(); items.append(activity); lock.unlock() }
    var all: [HTTPActivity] { lock.lock(); defer { lock.unlock() }; return items }
}
