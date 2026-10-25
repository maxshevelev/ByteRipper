import Foundation
import XCTest
@testable import CodeAnalysis

/// The stored zip a bundle is: what this side writes, what it refuses to
/// guess at, and what the Python side's archive looks like to it.
final class BundleArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func written(_ entries: [String: Data]) throws -> URL {
        let url = directory.appendingPathComponent("bundle.zip")
        try BundleArchive.write(entries: entries, to: url)
        return url
    }

    func testEveryEntryComesBackWithItsBytes() throws {
        let entries = [
            "bundle.json": Data(#"{"schema":1}"#.utf8),
            "analyses/aa/manifest.json": Data(#"{"artifact":"bb"}"#.utf8),
            "objects/bb": Data([0x00, 0xFF, 0x7F, 0x80, 0x0A, 0x00])
        ]
        let url = try written(entries)
        XCTAssertEqual(try BundleArchive.read(from: url), entries)
    }

    func testANameThatIsNotAnEntryNameIsRefused() {
        XCTAssertThrowsError(try BundleArchive.write(entries: ["../outside": Data()],
                                                     to: directory.appendingPathComponent("a.zip")))
        XCTAssertThrowsError(try BundleArchive.write(entries: ["/absolute": Data()],
                                                     to: directory.appendingPathComponent("b.zip")))
        XCTAssertThrowsError(try BundleArchive.write(entries: ["": Data()],
                                                     to: directory.appendingPathComponent("c.zip")))
    }

    func testACompressedEntryIsRefusedRatherThanGuessedAt() throws {
        let url = try written(["bundle.json": Data(#"{"schema":1}"#.utf8)])
        var bytes = [UInt8](try Data(contentsOf: url))
        // The local header's method is at +8, the central record's at +10.
        // The end record is the last 22 bytes; its directory offset is at +16.
        bytes[8] = 8
        let end = bytes.count - 22
        let centralOffset = Int(bytes[end + 16])
            | Int(bytes[end + 17]) << 8
            | Int(bytes[end + 18]) << 16
            | Int(bytes[end + 19]) << 24
        bytes[centralOffset + 10] = 8
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try BundleArchive.read(from: url))
    }

    func testAnEntryWhoseBytesChangedIsRefused() throws {
        let url = try written(["bundle.json": Data(#"{"schema":1}"#.utf8)])
        var bytes = [UInt8](try Data(contentsOf: url))
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        let dataStart = 30 + nameLength + extraLength
        bytes[dataStart] ^= 0xFF
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try BundleArchive.read(from: url))
    }

    func testThePythonFixtureIsThreeEntries() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bundle", withExtension: "zip",
                                                  subdirectory: "Fixtures"))
        let entries = try BundleArchive.read(from: url)
        XCTAssertEqual(Set(entries.keys), [
            "bundle.json",
            "analyses/eb3e84db961245ce7e7bd38a111c36552e9731e0f83e36ac1276179daf626460"
                + "/code-v2-ghidra-12.1.2/manifest.json",
            "objects/59151d9fbb9bb266ff8bf503cca88b1625a64a7b48ca0bea02d619702731eaca"
        ])
        let manifestPath = try XCTUnwrap(entries.keys.first { $0.hasPrefix("analyses/") })
        let manifest = try JSONSerialization.jsonObject(
            with: XCTUnwrap(entries[manifestPath])) as? [String: Any]
        XCTAssertEqual(manifest?["schema"] as? Int, 1)
    }
}
