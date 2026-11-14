import XCTest
@testable import IntelCPUID

/// Answers each file of the repository from what the test says of it, and
/// records the validator each was asked with.
private final class RepositoryStub: URLProtocol {
    struct Answer {
        var status = 200
        var body = Data()
        var etag: String?
        var offline = false
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: Answer] = [:]
        private(set) var asked: [(file: String, etag: String?)] = []

        subscript(file: String) -> Answer? {
            get { lock.lock(); defer { lock.unlock() }; return answers[file] }
            set { lock.lock(); answers[file] = newValue; lock.unlock() }
        }

        func ask(_ request: URLRequest) -> Answer {
            lock.lock()
            defer { lock.unlock() }
            let file = request.url!.lastPathComponent
            asked.append((file, request.value(forHTTPHeaderField: "If-None-Match")))
            return answers[file] ?? Answer(status: 404)
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return asked.count }
    }

    nonisolated(unsafe) static var script = Script()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = RepositoryStub.script.ask(request)
        if answer.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: answer.etag.map { ["ETag": $0] } ?? [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}

private let day: TimeInterval = 24 * 60 * 60

/// The one repository every reader of the tables asks: what it installs, what
/// it keeps, and how often it asks.
final class IntelCPUIDRepositoryTests: XCTestCase {
    private var script: RepositoryStub.Script!
    private var ticker: Ticker!

    private let names = "IntelCPUIDBrandNames.json"
    private let signatures = "IntelMicrocodeSignatures.json"
    private let notes = "extra-entries.json"

    override func setUp() {
        super.setUp()
        script = RepositoryStub.Script()
        RepositoryStub.script = script
        ticker = Ticker()
        ProcessorTables.install(.empty)
    }

    override func tearDown() {
        ProcessorTables.install(.empty)
        super.tearDown()
    }

    private func repository(_ folder: URL?) -> IntelCPUIDRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RepositoryStub.self]
        let ticker = self.ticker!
        return IntelCPUIDRepository(session: URLSession(configuration: config), folder: folder, ttl: day,
                                    now: { ticker.now })
    }

    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IntelCPUID-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func namesFile(_ code: String, version: Int = 1) -> RepositoryStub.Answer {
        ok("""
        {"formatVersion": \(version), "entries": [{"cpuids": ["806EA"], "codeNames": ["Kaby Lake Refresh U"],
          "cores": [], "productFamilies": [], "steppings": ["Y0"], "segments": [],
          "processors": [{"name": "Intel Core i5-8250U", "sSpec": ["\(code)"]}]}]}
        """, etag: "n-\(code)")
    }
    private var signaturesFile: RepositoryStub.Answer { ok(#"{"formatVersion": 1, "updates": []}"#, etag: "s1") }
    private func notesFile(_ note: String) -> RepositoryStub.Answer {
        ok(#"{"entries": [{"cpuids": ["806EA"], "codeNames": ["Kaby Lake Refresh U"], "note": "\#(note)"}]}"#,
           etag: "x-\(note)")
    }
    private func ok(_ body: String, etag: String) -> RepositoryStub.Answer {
        RepositoryStub.Answer(status: 200, body: Data(body.utf8), etag: etag)
    }
    private let notModified = RepositoryStub.Answer(status: 304)
    private let offline = RepositoryStub.Answer(offline: true)

    private var installedCode: String? { ProcessorTables.current.families.first?.processors.first?.sSpec.first }
    private var installedNote: String? {
        ProcessorTables.current.families.first.flatMap { ProcessorTables.current.notes(on: $0)?.note }
    }

    /// The first read installs the files and keeps them; a second refresh the
    /// same day asks nothing; after a day `304`s keep what is held.
    func testTheTablesAreReadKeptAndCheckedOnceADay() async throws {
        let folder = folder()
        script[names] = namesFile("SR3LA")
        script[signatures] = signaturesFile
        script[notes] = notesFile("first")
        let repository = repository(folder)
        await repository.refresh()
        XCTAssertEqual(installedCode, "SR3LA")
        XCTAssertEqual(installedNote, "first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(names).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(notes).path))

        await repository.refresh()
        XCTAssertEqual(script.count, 3, "the same day asks nothing")

        ticker.advance(day + 1)
        script[names] = notModified
        script[signatures] = notModified
        script[notes] = notModified
        await repository.refresh()
        XCTAssertEqual(script.asked.suffix(3).map(\.etag), ["n-SR3LA", "s1", "x-first"], "each asked with its kept ETag")
        XCTAssertEqual(installedCode, "SR3LA")
        XCTAssertEqual(installedNote, "first")
    }

    /// A run with no network shows what the last good read kept; with nothing
    /// kept, nothing is known — the app has no table of its own.
    func testWithNoNetworkTheKeptCopyIsWhatIsShown() async throws {
        let folder = folder()
        script[names] = namesFile("SR3LA")
        script[signatures] = signaturesFile
        await repository(folder).refresh()

        ProcessorTables.install(.empty)
        script[names] = offline
        script[signatures] = offline
        await repository(folder).refresh()
        XCTAssertEqual(installedCode, "SR3LA", "the kept copy stands in for the network")

        ProcessorTables.install(.empty)
        await repository(self.folder()).refresh()
        XCTAssertNil(installedCode, "nothing kept, nothing known")
    }

    /// A file of a newer format — a push this build cannot read — leaves the
    /// tables as they were, and is not kept.
    func testANewerFormatLeavesTheTablesAsTheyWere() async throws {
        let folder = folder()
        script[names] = namesFile("SR3LA")
        script[signatures] = signaturesFile
        let repository = repository(folder)
        await repository.refresh()

        ticker.advance(day + 1)
        script[names] = namesFile("SRXXX", version: 2)
        script[signatures] = notModified
        await repository.refresh()
        XCTAssertEqual(installedCode, "SR3LA")
        let kept = try String(contentsOf: folder.appendingPathComponent(names), encoding: .utf8)
        XCTAssertTrue(kept.contains("SR3LA"), "the newer file is not kept")
    }

    /// The notes are what the tables can do without: when they cannot be had
    /// the tables are installed all the same, and a later answer brings them.
    func testTheTablesDoNotWaitOnTheNotes() async throws {
        let folder = folder()
        script[names] = namesFile("SR3LA")
        script[signatures] = signaturesFile
        script[notes] = offline
        let repository = repository(folder)
        await repository.refresh()
        XCTAssertEqual(installedCode, "SR3LA")
        XCTAssertNil(installedNote)

        ticker.advance(day + 1)
        script[names] = notModified
        script[signatures] = notModified
        script[notes] = notesFile("late")
        await repository.refresh()
        XCTAssertEqual(installedNote, "late")
        XCTAssertEqual(installedCode, "SR3LA")
    }
}
