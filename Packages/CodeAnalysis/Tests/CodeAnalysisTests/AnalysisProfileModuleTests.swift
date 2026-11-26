import Foundation
import XCTest
@testable import CodeAnalysis

/// The analysis profiles in the store: derived from a module's identity, and
/// the stamp a revision records. The catalogue's own tests are in
/// AnalysisProfiles.
final class AnalysisProfileModuleTests: XCTestCase {
    private func ec(_ family: String) -> ECModuleFacts {
        ECModuleFacts(family: family, extent: 0x2497C, extentSource: "crt0", sliceSize: 0x30000,
                      rawSHA256: String(repeating: "0", count: 64), masked: [], chipRead: false,
                      hostUpdateSize: nil, version: nil)
    }

    func testAPE32OrTEModuleIsUEFI() {
        let identity = ModuleIdentity(sha256: SHA256Digest(data: Data("pe".utf8)), size: 2, name: "m",
                                      kind: "PE32", phase: "pei")
        XCTAssertEqual(AnalysisProfile.derive(for: identity)?.stamp, "uefi@1")
    }

    func testAnITEECModuleIsEcIteNds32() {
        let identity = ModuleIdentity(sha256: SHA256Digest(data: Data("ec".utf8)), size: 2, name: "m",
                                      kind: "EC", ec: ec("ite-nds32"))
        XCTAssertEqual(AnalysisProfile.derive(for: identity), .ecIteNds32)
        XCTAssertEqual(AnalysisProfile.derive(for: identity)?.stamp, "ec-ite-nds32@1")
    }

    func testTheLibraryKindsAreTheStoresKinds() {
        XCTAssertEqual(AnalysisProfile.uefi.libraryKindValues, [.edk2, .amd, .intel])
        XCTAssertEqual(AnalysisProfile.ecIteNds32.libraryKindValues, [.toolchain, .ite])
        for profile in AnalysisProfile.catalogue {
            XCTAssertEqual(profile.libraryKindValues.count, profile.libraryKinds.count, profile.id)
        }
    }

    // MARK: - The revision's stamp

    /// A history and a reading written before revisions recorded a profile
    /// read without one.
    func testAnOldRevisionReadsWithoutAProfile() throws {
        let review = SHA256Digest(data: Data("review".utf8)).hex
        let old = """
            {"schema":1,"module":"\(review)","revisions":[{"rev":1,"review":"\(review)",\
            "recorded_at":"2026-01-01T00:00:00Z","by":"agent"}]}
            """
        let history = try JSONDecoder().decode(ReviewHistory.self, from: Data(old.utf8))
        XCTAssertEqual(history.revisions.count, 1)
        XCTAssertNil(history.revisions[0].profile)
        let reading = try JSONDecoder().decode(AnalysisReading.self, from: Data(#"{"rev":2,"review":"\#(review)"}"#.utf8))
        XCTAssertNil(reading.profile)

        var stamped = history.revisions[0]
        stamped.profile = "uefi@1"
        let data = try JSONEncoder().encode(stamped)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""profile":"uefi@1""#))
        XCTAssertEqual(try JSONDecoder().decode(ReviewRevision.self, from: data).profile, "uefi@1")
    }

    /// The store records the profile the reading carries in the revision.
    func testARecordedRevisionKeepsTheReadingsProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let module = SHA256Digest(data: Data("module".utf8))
        let first = try store.putObject(Data(#"{"schema":1,"n":1}"#.utf8))
        let history = try store.recordRevision(module: module,
                                               reading: AnalysisReading(rev: 1, review: first, profile: "ec-ite-nds32@1"))
        XCTAssertEqual(history.revisions.last?.profile, "ec-ite-nds32@1")
        let second = try store.putObject(Data(#"{"schema":1,"n":2}"#.utf8))
        let next = try store.recordRevision(module: module, reading: AnalysisReading(rev: 2, review: second))
        // No analysis named rev 1, so the store numbers this one 1 again, and
        // it carries its own reading's profile: none.
        XCTAssertNil(next.revisions.last?.profile)
        XCTAssertEqual(try store.reviewHistory(module: module)?.revisions.last?.review, second)
    }
}
