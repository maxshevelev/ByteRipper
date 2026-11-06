import AgentKit
import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// The review kit: read from the skills folder on the server, fetched and
/// kept by the app, offered to agents as prompts and resources.
final class ReviewKitTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewKitTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheCheckoutsKitHasBothRolesAndTheRulesAndNothingElse() throws {
        let kit = try ReviewKit.read(skills: ReviewKit.resolvedSkills())
        let paths = kit.manifest.files.map(\.path)
        XCTAssertTrue(paths.contains("review-roles/roles/reviewer.md"))
        XCTAssertTrue(paths.contains("review-roles/roles/verifier.md"))
        XCTAssertTrue(paths.contains("ghidra-uefi/SKILL.md"))
        XCTAssertTrue(paths.contains("ghidra-uefi/reference/description.md"))
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix(".md") && ReviewKitCache.safe($0) }, "\(paths)")
        // Every resource a role tells the agent to read is in the kit.
        for role in ReviewKit.roles {
            let text = try XCTUnwrap(kit.prompt(named: role.name, mac: "Bench")).text
            XCTAssertFalse(text.contains("{{"), "\(role.name): a placeholder left")
            XCTAssertTrue(text.contains("\(role.title) · Bench"))
            let named = text.components(separatedBy: ReviewKit.resourceScheme).dropFirst()
                .map { String($0.prefix { !"`) ,\n".contains($0) }) }
            XCTAssertFalse(named.isEmpty, role.name)
            for path in named where path.hasSuffix(".md") {
                XCTAssertNotNil(kit.texts[path], "\(role.name) names \(path), which the kit has not got")
            }
        }
    }

    func testTheVersionFollowsTheContentNotTheOrder() {
        let one = ReviewKit(texts: ["a.md": "one", "b.md": "two"])
        let same = ReviewKit(texts: ["b.md": "two", "a.md": "one"])
        let changed = ReviewKit(texts: ["a.md": "one", "b.md": "three"])
        XCTAssertEqual(one.manifest, same.manifest)
        XCTAssertNotEqual(one.manifest.version, changed.manifest.version)
        XCTAssertEqual(one.manifest.files.map(\.path), ["a.md", "b.md"])
    }

    func testOnlyTheRulesAreResourcesAndOnlyTheRolesArePrompts() async throws {
        let kit = Self.kit()
        XCTAssertEqual(kit.resources.map(\.uri), ["byteripper://kit/ghidra-uefi/SKILL.md"])
        XCTAssertNil(kit.resource(uri: "byteripper://kit/review-roles/roles/reviewer.md"))
        XCTAssertNil(kit.resource(uri: "file:///etc/passwd"))
        XCTAssertEqual(kit.resource(uri: "byteripper://kit/ghidra-uefi/SKILL.md")?.text, "# Rules")

        let server = FakeServer(kit: kit)
        let content = ReviewKitContent(cache: cache(server), mac: { "Bench" })
        let prompts = await content.prompts()
        XCTAssertEqual(prompts.map(\.name), ["reviewer", "verifier"])
        let reviewer = try await content.prompt(named: "reviewer", arguments: [:])
        XCTAssertEqual(reviewer.text, "Reviewer · Bench reads byteripper://kit/ghidra-uefi/SKILL.md")
        do {
            _ = try await content.prompt(named: "coder", arguments: [:])
            XCTFail("a role the kit has not got")
        } catch let error as AgentToolError {
            XCTAssertTrue(error.message.contains("reviewer, verifier"), error.message)
        }
    }

    func testTheAppKeepsTheLastKitWhenTheServerCannotBeReached() async throws {
        let server = FakeServer(kit: Self.kit())
        let first = cache(server)
        let fetched = await first.current()
        XCTAssertEqual(fetched?.manifest, Self.kit().manifest)

        server.reachable = false
        let later = cache(server)   // the app started again
        let kept = await later.current()
        XCTAssertEqual(kept?.manifest, Self.kit().manifest, "the copy on disk")
    }

    func testAChangedKitIsFetchedAgainAndOnlyTheChangedFiles() async throws {
        let server = FakeServer(kit: Self.kit())
        let cache = cache(server, interval: 0)
        _ = await cache.current()
        XCTAssertEqual(server.filesRead.count, 3)
        server.kit = Self.kit(reviewer: "Reviewer · {{mac}}, again")
        server.filesRead = []
        let changed = await cache.current()
        XCTAssertEqual(changed?.prompt(named: "reviewer", mac: "M")?.text, "Reviewer · M, again")
        XCTAssertEqual(server.filesRead, ["review-roles/roles/reviewer.md"])
        server.filesRead = []
        _ = await cache.current()
        XCTAssertEqual(server.filesRead, [], "the same version reads no file")
    }

    func testAFileThatDoesNotMatchItsManifestIsNotTaken() async throws {
        let server = FakeServer(kit: Self.kit())
        server.tamper = "ghidra-uefi/SKILL.md"
        let cache = cache(server)
        let kit = await cache.current()
        XCTAssertNil(kit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("kit/manifest.json").path))
    }

    func testAManifestNamingAPathOutOfTheFolderIsRefused() {
        XCTAssertFalse(ReviewKitCache.safe("../secret.md"))
        XCTAssertFalse(ReviewKitCache.safe("/etc/x.md"))
        XCTAssertFalse(ReviewKitCache.safe("a//b.md"))
        XCTAssertFalse(ReviewKitCache.safe("ghidra-uefi/scripts/cas.py"))
        XCTAssertTrue(ReviewKitCache.safe("ghidra-uefi/reference/cas.md"))
    }

    func testNoServerNamedOffersNothingEvenWithACopyOnDisk() async throws {
        let server = FakeServer(kit: Self.kit())
        _ = await cache(server).current()
        let none = ReviewKitCache(folder: directory.appendingPathComponent("kit"), source: { nil })
        let kit = await none.current()
        XCTAssertNil(kit)
        let content = ReviewKitContent(cache: none, mac: { "M" })
        let prompts = await content.prompts()
        let resources = await content.resources()
        XCTAssertEqual(prompts, [])
        XCTAssertEqual(resources, [])
    }

    // MARK: -

    private static func kit(reviewer: String = "Reviewer · {{mac}} reads byteripper://kit/ghidra-uefi/SKILL.md") -> ReviewKit {
        ReviewKit(texts: ["review-roles/roles/reviewer.md": reviewer,
                          "review-roles/roles/verifier.md": "Verifier · {{mac}}",
                          "ghidra-uefi/SKILL.md": "# Rules"])
    }

    private func cache(_ server: FakeServer, interval: TimeInterval = 60) -> ReviewKitCache {
        ReviewKitCache(folder: directory.appendingPathComponent("kit"), interval: interval, source: { server.source })
    }
}

/// The analysis server's kit routes, in memory.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (kit: ReviewKit, reachable: Bool, tamper: String?, read: [String])

    init(kit: ReviewKit) { state = (kit, true, nil, []) }

    var kit: ReviewKit { get { lock.withLock { state.kit } } set { lock.withLock { state.kit = newValue } } }
    var reachable: Bool { get { lock.withLock { state.reachable } } set { lock.withLock { state.reachable = newValue } } }
    var tamper: String? { get { lock.withLock { state.tamper } } set { lock.withLock { state.tamper = newValue } } }
    var filesRead: [String] { get { lock.withLock { state.read } } set { lock.withLock { state.read = newValue } } }

    var source: ReviewKitCache.Source {
        ReviewKitCache.Source(manifest: { [self] in
            guard reachable else { throw URLError(.cannotConnectToHost) }
            return try JSONEncoder().encode(kit.manifest)
        }, file: { [self] path in
            guard reachable else { throw URLError(.cannotConnectToHost) }
            lock.withLock { state.read.append(path) }
            if path == tamper { return Data("changed on the way".utf8) }
            return Data((kit.texts[path] ?? "").utf8)
        })
    }
}
