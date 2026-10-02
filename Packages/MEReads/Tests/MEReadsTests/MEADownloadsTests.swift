import XCTest
import MEFirmware
@testable import MEReads

/// `MEADownloads` — upstream's three files started side by side when a reading
/// begins — and the status line that says which are still coming.
@MainActor
final class MEADownloadsTests: XCTestCase {
    /// A source that holds nothing, whose every fetch waits for the test to
    /// let it finish, and which counts what it was asked.
    private actor Gate: MEADataSource {
        var asked: [String] = []
        private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        let holds: Bool

        init(holds: Bool = false) { self.holds = holds }

        private func wait(_ name: String) async {
            asked.append(name)
            await withCheckedContinuation { waiting[name, default: []].append($0) }
        }

        func release(_ name: String) {
            waiting.removeValue(forKey: name)?.forEach { $0.resume() }
        }

        func database() async throws -> MEADatabase {
            await wait("MEA.dat")
            throw MEADataError.rateLimited
        }
        func huffmanDictionaries() async throws -> HuffmanDictionaries {
            await wait("Huffman.dat")
            throw MEADataError.rateLimited
        }
        func fileTable() async throws -> FileTable {
            await wait("FileTable.dat")
            throw MEADataError.rateLimited
        }
        nonisolated var fetchesOverTheNetwork: Bool { true }
        nonisolated func heldDatabase() async -> MEADatabase? { holds ? MEADatabase.parse("") : nil }
        nonisolated func heldHuffmanDictionaries() async -> HuffmanDictionaries? { nil }
        nonisolated func heldFileTable() async -> FileTable? { nil }
    }

    private func settle(until condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// All three start at once, a second prefetch while they run starts none of
    /// its own, and each leaves the list as it finishes.
    func testTheFilesDownloadSideBySideAndOnce() async {
        let downloads = MEADownloads()
        let gate = Gate()
        var seen: [Set<MEADatabaseFile>] = []
        _ = downloads.observe { seen.append($0) }

        downloads.prefetch(from: gate)
        await settle { downloads.active.count == 3 }
        XCTAssertEqual(downloads.active, [.database, .huffman, .fileTable], "all three at once")
        downloads.prefetch(from: gate)
        await settle { await gate.asked.count >= 3 }
        let asked = await gate.asked
        XCTAssertEqual(asked.sorted(), ["FileTable.dat", "Huffman.dat", "MEA.dat"], "each asked once")

        await gate.release("MEA.dat")
        await settle { downloads.active == [.huffman, .fileTable] }
        XCTAssertEqual(downloads.active, [.huffman, .fileTable])
        await gate.release("Huffman.dat")
        await gate.release("FileTable.dat")
        await settle { downloads.active.isEmpty }
        XCTAssertEqual(seen.last, [], "and the list ends empty")
    }

    /// A file the source already holds is not downloaded and not shown.
    func testAHeldFileIsNotDownloaded() async {
        let downloads = MEADownloads()
        let gate = Gate(holds: true)
        downloads.prefetch(from: gate)
        await settle { downloads.active.count == 2 }
        XCTAssertEqual(downloads.active, [.huffman, .fileTable])
        await gate.release("Huffman.dat")
        await gate.release("FileTable.dat")
        await settle { downloads.active.isEmpty }
    }

    /// A source that answers at once has nothing to start early.
    func testALocalSourceStartsNothing() async {
        struct Local: MEADataSource {
            func database() async throws -> MEADatabase { MEADatabase.parse("") }
        }
        let downloads = MEADownloads()
        downloads.prefetch(from: Local())
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(downloads.active, [])
    }

    /// The line names what is still downloading, in the order the analysis
    /// reads them, and the reading itself once nothing is.
    func testTheStatusLineSaysWhatIsHappening() async {
        XCTAssertEqual(MEAReadingStatus.line(for: []), "Reading ME…")
        XCTAssertEqual(MEAReadingStatus.line(for: [.fileTable, .database]), "Downloading MEA.dat, FileTable.dat…")

        let downloads = MEADownloads()
        let gate = Gate()
        var said: [String] = []
        let status = MEAReadingStatus(downloads: downloads) { said.append($0) }
        downloads.prefetch(from: gate)
        await settle { downloads.active.count == 3 }
        XCTAssertEqual(said.first, "Reading ME…")
        XCTAssertEqual(said.last, "Downloading MEA.dat, Huffman.dat, FileTable.dat…")
        status.stop()
        await gate.release("MEA.dat")
        await settle { downloads.active.count == 2 }
        XCTAssertEqual(said.last, "Downloading MEA.dat, Huffman.dat, FileTable.dat…", "a stopped status says nothing more")
        await gate.release("Huffman.dat")
        await gate.release("FileTable.dat")
        await settle { downloads.active.isEmpty }
    }
}
