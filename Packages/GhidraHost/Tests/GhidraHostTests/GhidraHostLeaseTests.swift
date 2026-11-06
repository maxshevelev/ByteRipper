import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// A module in work (stage 2.4): one holder at a time writes and publishes it,
/// from the take to the give-back, with no term and across any number of
/// publishes; the leases outlive the host; an administrator's close drops the
/// holder's unpublished changes and is said at the holder's next call. Run
/// with `GHIDRA_TYPE_MODULE` naming a module; skipped otherwise.
final class GhidraHostLeaseTests: XCTestCase {
    private var directory: URL!
    private var hosts: [GhidraHost] = []
    private var module: SHA256Digest!

    override func tearDown() async throws {
        for host in hosts { if let module { await host.stop(module) } }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func image() throws -> Data {
        guard let path = ProcessInfo.processInfo.environment["GHIDRA_TYPE_MODULE"] else {
            throw XCTSkip("GHIDRA_TYPE_MODULE is not set")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// A host on this test's store and projects, its leases in the store's private part.
    private func host() throws -> GhidraHost {
        if directory == nil {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GhidraHostLeaseTests-\(UUID().uuidString)", isDirectory: true)
        }
        let store = try ContentStore(root: directory.appendingPathComponent("store"))
        let host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"), idle: 300,
                                                   holder: "first",
                                                   leasesFile: directory.appendingPathComponent("store/private/leases.json")),
                              writer: store)
        hosts.append(host)
        return host
    }

    private func comment(_ host: GhidraHost, _ text: String, holder: String? = nil) async throws {
        let entry = try await firstEntry(host)
        _ = try await host.write(module, "/v1/set/comment", body: try JSONSerialization.data(withJSONObject: [
            "address": entry, "kind": "plate", "text": text]), holder: holder)
    }

    private func plate(_ host: GhidraHost, holder: String? = nil) async throws -> String? {
        let entry = try await firstEntry(host)
        let data = try await host.read(module, "/v1/function/\(entry)", holder: holder)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["plate"] as? String
    }

    private func firstEntry(_ host: GhidraHost) async throws -> String {
        let data = try await host.read(module, "/v1/functions?limit=1", holder: "a reader")
        let functions = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["functions"] as? [[String: Any]]
        return try XCTUnwrap(functions?.first?["entry"] as? String)
    }

    private func refused(_ what: String, contains words: String,
                         _ call: () async throws -> Void) async {
        do {
            try await call()
            XCTFail("\(what) was not refused")
        } catch let error as GhidraHostError {
            XCTAssertEqual(error.status, 409, "\(what): \(error)")
            XCTAssertTrue(error.message.contains(words), "\(what): \(error.message)")
        } catch {
            XCTFail("\(what): \(error)")
        }
    }

    func testOneHolderWritesAndPublishesFromTheTakeToTheGiveBack() async throws {
        let image = try image()
        let host = try host()
        module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")

        await refused("a write before the take", contains: "not in work") {
            try await self.comment(host, "before the take")
        }
        let lease = try await host.take(module)
        XCTAssertEqual(lease.holder, "first")
        let again = try await host.take(module)
        XCTAssertEqual(again, lease, "the holder's second take is the same lease")
        await refused("another holder's take", contains: "in work by first") {
            _ = try await host.take(self.module, holder: "second")
        }

        try await comment(host, "the first holder's")
        await refused("another holder's write", contains: "in work by first") {
            try await self.comment(host, "the second holder's", holder: "second")
        }
        await refused("another holder's publish", contains: "in work by first") {
            _ = try await host.publish(self.module, by: "agent", holder: "second")
        }
        let read = try await plate(host, holder: "second")
        XCTAssertEqual(read, "the first holder's", "reading needs no lease")

        // A publish keeps the module in work: the holder goes on and publishes again.
        _ = try await host.publish(module, by: "agent")
        let kept = await host.workLease(module)
        XCTAssertEqual(kept?.holder, lease.holder)
        XCTAssertEqual(kept?.since, lease.since)
        try await comment(host, "after the publish")
        let published = try await host.publish(module, by: "agent")
        // What the holder did under the lease, for the Activity page: another
        // holder's refused calls are not counted.
        let current = await host.workLease(module)
        let activity = try XCTUnwrap(current)
        XCTAssertEqual(activity.writes, 2)
        XCTAssertEqual(activity.publishes, 2)
        XCTAssertEqual(activity.revision, published.manifest.reading?.rev)
        XCTAssertEqual(activity.lastCall, "publish")
        XCTAssertNotNil(activity.lastAt)
        let summaries = await host.summaries()
        let row = try XCTUnwrap(summaries.first)
        XCTAssertTrue(row.leased)
        XCTAssertEqual(row.holder, "first")
        XCTAssertEqual(row.since, lease.since)
        // The administrator's list carries the same activity.
        let rowsNow = await host.leaseRows()
        let listed = try XCTUnwrap(rowsNow.first)
        XCTAssertEqual(listed.holder, "first")
        XCTAssertEqual(listed.writes, 2)
        XCTAssertEqual(listed.publishes, 2)
        XCTAssertEqual(listed.revision, activity.revision)
        XCTAssertEqual(listed.lastCall, "publish")

        // Given back, another holder takes it.
        _ = try await host.release(module, by: "agent")
        let givenBack = await host.workLease(module)
        XCTAssertNil(givenBack)
        await refused("a write after the give-back", contains: "not in work") {
            try await self.comment(host, "after the give-back")
        }
        let second = try await host.take(module, holder: "second")
        XCTAssertEqual(second.holder, "second")
    }

    func testALeaseOutlivesTheHost() async throws {
        let image = try image()
        let first = try host()
        module = SHA256Digest(data: image)
        _ = try await first.create(module: image, name: "Module")
        let lease = try await first.take(module)
        await first.stop(module)

        let restarted = try host()
        let kept = await restarted.workLease(module)
        XCTAssertEqual(kept, lease)
        await refused("another holder's take after the restart", contains: "in work by first") {
            _ = try await restarted.take(self.module, holder: "second")
        }
        try await comment(restarted, "after the restart")
        let read = try await plate(restarted)
        XCTAssertEqual(read, "after the restart")
    }

    func testAClosedLeaseDropsTheUnpublishedChangesAndIsSaidAtTheNextCall() async throws {
        let image = try image()
        let host = try host()
        module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        try await host.take(module)
        try await comment(host, "published")
        _ = try await host.publish(module, by: "agent")
        try await comment(host, "not published")

        // A client waiting on the lease hears of the close at once.
        let waiting = Task { await host.waitForLeaseEnd(self.module, holder: nil, seconds: 120) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let closed = try await host.closeLease(module, by: "admin")
        XCTAssertEqual(closed.holder, "first")
        XCTAssertEqual(closed.closedBy, "admin")
        let heard = await waiting.value
        XCTAssertEqual(heard["state"], "closed")
        XCTAssertEqual(heard["closed_by"], "admin")
        let folder = await host.project(module).folder
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the working project went to the Trash")
        let rows = await host.leaseRows()
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.holder)
        XCTAssertEqual(row.closed?.closedBy, "admin")

        // The holder's next call says so — a read once, a write until it takes the module again.
        await refused("the holder's first read", contains: "closed by admin") {
            _ = try await self.plate(host)
        }
        let unpublished = try await plate(host)
        XCTAssertEqual(unpublished, "published", "the project is the last published revision again")
        await refused("the holder's write", contains: "closed by admin") {
            try await self.comment(host, "after the close")
        }
        try await host.take(module)
        try await comment(host, "after the close")
        let read = try await plate(host)
        XCTAssertEqual(read, "after the close")
        let cleared = await host.leaseRows()
        XCTAssertTrue(cleared.allSatisfy { $0.closed == nil }, "a take again clears the close")
    }

    func testADiscardGivesTheModuleBackWithoutItsUnpublishedChanges() async throws {
        let image = try image()
        let host = try host()
        module = SHA256Digest(data: image)
        _ = try await host.create(module: image, name: "Module")
        try await host.take(module)
        try await comment(host, "published")
        _ = try await host.publish(module, by: "agent")
        let revision = try await host.writer.latestRevision(module: module)
        try await comment(host, "not published")
        let given = try await host.release(module, by: "agent", discard: true)
        XCTAssertNil(given, "nothing is published")
        let gone = await host.workLease(module)
        XCTAssertNil(gone)
        let after = try await host.writer.latestRevision(module: module)
        XCTAssertEqual(after, revision)
        let read = try await plate(host)
        XCTAssertEqual(read, "published")
    }
}
