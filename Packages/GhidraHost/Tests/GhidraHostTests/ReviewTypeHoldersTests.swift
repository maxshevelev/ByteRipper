import CodeAnalysis
import Foundation
import XCTest
@testable import GhidraHost

/// The modules an applied proposal tells include those whose program holds a
/// replaced type their C never prints: AmdSocFp6CznPei held `APOB_INFO` and
/// printed only `APOB_HOB_INFO`, so no use named it, and its next publish
/// would have been refused unwarned (issue 8ba08281). No Ghidra.
final class ReviewTypeHoldersTests: XCTestCase {
    private var directory: URL!
    private var store: ContentStore!
    private var host: GhidraHost!
    private let recipe = AnalysisRecipe(id: "code-v10-test", exporter: 10, ghidra: "12.2", script: "ExportCode.java")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewTypeHolders-\(UUID().uuidString)", isDirectory: true)
        store = try ContentStore(root: directory.appendingPathComponent("store"))
        host = GhidraHost(configuration: .init(projectsRoot: directory.appendingPathComponent("projects"),
                                               idle: 300, holder: "ReviewTypeHoldersTests"),
                          writer: store)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func publish(_ name: String, rev: Int, reviewTypes: [String], printed: [String]) throws {
        let module = ModuleIdentity(sha256: SHA256Digest(data: Data(name.utf8)), size: name.utf8.count, name: name)
        let review = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "functions": [:], "comments": [], "data": [:],
            "types": reviewTypes.map { ["name": $0, "c": "typedef struct _\($0) { int Unknown00; } \($0);"] }])
        let digest = try store.putObject(review)
        let artifact = try JSONSerialization.data(withJSONObject: [
            "functions": [["entry": "0x10", "name": "Reads", "c": printed.map { "\($0) *Info;" }.joined(separator: "\n")]],
            "types": printed.map { ["name": $0, "c": "typedef struct _\($0) { int Unknown00; } \($0);"] }])
        _ = try store.putAnalysis(module: module, recipe: recipe, artifact: artifact,
                                  reading: AnalysisReading(rev: rev, review: digest))
    }

    func testAProgramHoldingATypeItsCNeverPrintsIsAHolder() async throws {
        try publish("AmdSocFp6CznPei", rev: 93, reviewTypes: ["APOB_HOB_INFO", "APOB_INFO"], printed: ["APOB_HOB_INFO"])
        try publish("AmdSocFp6RnPei", rev: 12, reviewTypes: ["APOB_HOB_INFO"], printed: ["APOB_HOB_INFO"])

        // What the uses alone find: nobody prints APOB_INFO.
        let used = try await host.typeUses(name: "APOB_INFO", limit: 1)
        let uses = try JSONSerialization.jsonObject(with: used)
        XCTAssertEqual(((uses as? [String: Any])?["modules"] as? [Any])?.count, 0, "\(uses)")

        let holders = await host.reviewTypeHolders(["APOB_INFO"])
        XCTAssertEqual(holders.map(\.name), ["AmdSocFp6CznPei"])
        XCTAssertEqual(holders.first?.revision, 93)
        // A tag names the same type.
        let tagged = await host.reviewTypeHolders(["_APOB_INFO"])
        XCTAssertEqual(tagged.map(\.name), ["AmdSocFp6CznPei"])
        let printed = await host.reviewTypeHolders(["APOB_HOB_INFO"])
        XCTAssertEqual(printed.map(\.name), ["AmdSocFp6CznPei", "AmdSocFp6RnPei"])
    }
}
