import XCTest
@testable import ByteRipper

/// Version numbers — a bundle's `CFBundleShortVersionString` and a release tag
/// like "v0.8.2" — read and compared (`AppVersion`).
final class AppVersionTests: XCTestCase {

    // MARK: - Reading

    /// A tag is a bundle's version with a "v" in front of it, and the two have
    /// to read as the same version: one names what has been published and the
    /// other what is running, and they are compared with each other.
    func testATagAndABundleVersionAreTheSameVersion() throws {
        XCTAssertEqual(AppVersion("v0.8.2")?.text, "0.8.2")
        XCTAssertEqual(AppVersion("0.8.2")?.text, "0.8.2")
        XCTAssertEqual(AppVersion("V1.0")?.text, "1.0")
        XCTAssertEqual(AppVersion("  v1.0  ")?.text, "1.0", "whitespace is not the number")
        XCTAssertEqual(AppVersion("v0.8.2"), AppVersion("0.8.2"))
    }

    /// Nothing that is not a version is called one. A "latest" a caller can
    /// compare against a release is worse than no answer at all.
    func testTextWithNoNumberInItIsNotAVersion() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion(".."))
    }

    /// A number after the version is a label, not part of it.
    func testATailThatIsNotANumberIsNotPartOfTheVersion() throws {
        let version = try XCTUnwrap(AppVersion("0.9.0-beta"))

        XCTAssertEqual(version.parts, [0, 9, 0], "the number is read up to the label")
        XCTAssertEqual(version.text, "0.9.0-beta", "and the label is still shown")
        XCTAssertEqual(version, AppVersion("0.9.0"))
        XCTAssertLessThan(version, try XCTUnwrap(AppVersion("0.9.1")))
    }

    // MARK: - Comparing

    /// The reason this is a type. As text, "0.8.10" sorts *before* "0.8.9", so a
    /// string comparison would send a bench running 0.8.9 to an older release
    /// and tell it that was an update.
    func testTheTenthPatchIsNewerThanTheNinth() throws {
        let older = try XCTUnwrap(AppVersion("0.8.9"))
        let newer = try XCTUnwrap(AppVersion("0.8.10"))

        XCTAssertLessThan(older, newer)
        XCTAssertGreaterThan(newer, older)
        XCTAssertGreaterThan(older.text, newer.text,
                             "and as strings, which is what the numbers are for")
    }

    func testAMissingPartReadsAsZero() {
        XCTAssertEqual(AppVersion("0.9"), AppVersion("0.9.0"))
        XCTAssertEqual(AppVersion("1"), AppVersion("1.0.0"))
        XCTAssertEqual(AppVersion("0.9"), AppVersion("0.9.0.0"))
        XCTAssertNotEqual(AppVersion("0.9"), AppVersion("0.9.1"))
        XCTAssertLessThan(AppVersion("0.9")!, AppVersion("0.9.0.1")!)
    }

    func testVersionsComparePartByPartFromTheFront() {
        let versions = ["0.8.2", "0.8.10", "0.9", "0.9.0", "0.10.0", "1.0"].compactMap(AppVersion.init)
        XCTAssertEqual(versions.sorted(), [
            AppVersion("0.8.2"), AppVersion("0.8.10"), AppVersion("0.9"),
            AppVersion("0.9.0"), AppVersion("0.10.0"), AppVersion("1.0"),
        ].compactMap { $0 })
    }

    // MARK: - The build that is running

    /// The suite runs hosted in the app, and the app knows what it is — which is
    /// what a release gets compared against.
    func testTheRunningBuildHasAVersion() throws {
        let current = try XCTUnwrap(AppVersion.current, "the host app's own version")

        XCTAssertFalse(current.parts.isEmpty)
        XCTAssertFalse(current.text.isEmpty)
    }
}
