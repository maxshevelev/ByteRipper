import XCTest
@testable import ByteRipper

/// The question the landing screen asks — is there a newer release? — and what
/// counts as an answer (`ReleaseSource`, `GitHubReleases`).
///
/// No test here reaches github.com: the source is a stub, and the reading of
/// the answer is tried against a fixture the size of a line. A suite that
/// needed the network would fail on a train, which is not a defect in the app.
final class ReleaseCheckTests: XCTestCase {

    /// A source that answers whatever the test says, without a network.
    private struct StubSource: ReleaseSource {
        var release: Release?
        var failure: ReleaseCheckError?

        func latestRelease() async throws -> Release? {
            if let failure { throw failure }
            return release
        }
    }

    private func release(_ version: String) throws -> Release {
        Release(
            version: try XCTUnwrap(AppVersion(version)),
            page: try XCTUnwrap(URL(string: "https://github.com/maxshevelev/ByteRipper/releases")),
        )
    }

    // MARK: - Is it newer?

    func testANewerReleaseIsTheAnswer() async throws {
        let newest = try release("0.9.0")

        let answer = await StubSource(release: newest)
            .newerRelease(than: try XCTUnwrap(AppVersion("0.8.2")))

        XCTAssertEqual(answer, newest)
        XCTAssertEqual(answer?.page, newest.page, "and it comes with where to open it")
    }

    /// What is published being what is running is not news.
    func testTheVersionRunningIsNotAnUpdate() async throws {
        let answer = await StubSource(release: try release("0.8.2"))
            .newerRelease(than: try XCTUnwrap(AppVersion("0.8.2")))

        XCTAssertNil(answer)
    }

    /// A build made after the release was published — a bench on a nightly, or
    /// an app whose release notes have not been written yet — is not told to go
    /// back to the older one.
    func testAnOlderReleaseIsNotAnUpdate() async throws {
        let answer = await StubSource(release: try release("0.8.2"))
            .newerRelease(than: try XCTUnwrap(AppVersion("0.9.0")))

        XCTAssertNil(answer)
    }

    // MARK: - Saying nothing

    /// Everything that can go wrong answers "nothing to say". The landing screen
    /// is there to open a file; a bench told that a check failed has been handed
    /// a problem it cannot act on.
    func testAQuestionThatCouldNotBeAskedIsNotAnAnnouncement() async throws {
        let running = try XCTUnwrap(AppVersion("0.8.2"))

        let offline = await StubSource(failure: .badResponse(status: 503))
            .newerRelease(than: running)
        XCTAssertNil(offline)

        let nonePublished = await StubSource(release: nil).newerRelease(than: running)
        XCTAssertNil(nonePublished)
    }

    /// With no version to compare against there is no comparison to make, and
    /// guessing one would announce an update to a build that may be newer than
    /// the release.
    func testABuildWithNoVersionIsToldNothing() async throws {
        let answer = await StubSource(release: try release("0.9.0")).newerRelease(than: nil)

        XCTAssertNil(answer)
    }

    // MARK: - Reading github.com's answer

    func testTheAnswerIsReadIntoTheReleaseItNames() throws {
        let json = Data("""
        {"tag_name": "v0.9.0", "name": "ByteRipper 0.9.0",
         "html_url": "https://github.com/maxshevelev/ByteRipper/releases/tag/v0.9.0",
         "draft": false, "prerelease": false}
        """.utf8)

        let release = try XCTUnwrap(GitHubReleases.release(fromJSON: json))

        XCTAssertEqual(release.version, AppVersion("0.9.0"), "the tag is the version")
        XCTAssertEqual(release.page.absoluteString,
                       "https://github.com/maxshevelev/ByteRipper/releases/tag/v0.9.0")
    }

    /// A tag with no number in it cannot be said to be newer than anything, and
    /// a line claiming one would be a line that cannot be acted on.
    func testATagWithNoNumberInItIsNoRelease() throws {
        let json = Data("""
        {"tag_name": "nightly", "html_url": "https://github.com/maxshevelev/ByteRipper/releases/tag/nightly"}
        """.utf8)

        XCTAssertNil(try GitHubReleases.release(fromJSON: json))
    }

    /// A release the app cannot open is a line that promises a click. The
    /// releases page is where the release is listed, so that is where it goes.
    func testAReleaseWithNoUsablePageFallsBackToTheReleasesPage() throws {
        let json = Data("""
        {"tag_name": "v0.9.0", "html_url": "not a url"}
        """.utf8)

        let release = try XCTUnwrap(GitHubReleases.release(fromJSON: json))

        XCTAssertEqual(release.page, GitHubReleases.repository.appendingPathComponent("releases"))
        XCTAssertEqual(release.page.host, "github.com")
    }

    /// What was asked is github's own API for this one release, and it is asked
    /// as the app — an anonymous request without a user agent is answered less
    /// kindly.
    func testTheCheckAsksTheAPIForTheLatestRelease() {
        XCTAssertEqual(GitHubReleases.latestReleaseURL.host, "api.github.com")
        XCTAssertEqual(GitHubReleases.latestReleaseURL.path,
                       "/repos/maxshevelev/ByteRipper/releases/latest")
        XCTAssertEqual(GitHubReleases.repository.host, "github.com")
    }
}
