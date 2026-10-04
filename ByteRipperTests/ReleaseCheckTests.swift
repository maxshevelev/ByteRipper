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

    // MARK: - What is announced

    /// What is published being newer than what is running is news: the
    /// release, and the case it is in — the one that also gets the "available"
    /// line.
    func testANewerReleaseIsAnnouncedAsOne() async throws {
        let newest = try release("0.9.0")

        let answer = await StubSource(release: newest)
            .releaseToAnnounce(comparedTo: try XCTUnwrap(AppVersion("0.8.2")))

        XCTAssertEqual(answer?.release, newest)
        XCTAssertFalse(answer?.isRunningBuild ?? true, "it is the newer case")
        XCTAssertEqual(answer?.release.page, newest.page,
                       "and it comes with where to open it")
    }

    /// What is published being what is running is not an update, but it is the
    /// build: its notes are what the landing screen tells about.
    func testTheRunningBuildIsAnnouncedAsOne() async throws {
        let answer = await StubSource(release: try release("0.8.2"))
            .releaseToAnnounce(comparedTo: try XCTUnwrap(AppVersion("0.8.2")))

        XCTAssertEqual(answer?.release, try release("0.8.2"))
        XCTAssertTrue(answer?.isRunningBuild ?? false, "it is the build running")
    }

    /// A build made after the release was published — a bench on a nightly, or
    /// an app whose release notes have not been written yet — is not told
    /// anything: no published release is either the build or news about it.
    func testAnOlderPublishedReleaseIsNotAnnounced() async throws {
        let answer = await StubSource(release: try release("0.8.2"))
            .releaseToAnnounce(comparedTo: try XCTUnwrap(AppVersion("0.9.0")))

        XCTAssertNil(answer)
    }

    // MARK: - Saying nothing

    /// Everything that can go wrong answers "nothing to say". The landing screen
    /// is there to open a file; a bench told that a check failed has been handed
    /// a problem it cannot act on.
    func testAQuestionThatCouldNotBeAskedIsNotAnAnnouncement() async throws {
        let running = try XCTUnwrap(AppVersion("0.8.2"))

        let offline = await StubSource(failure: .badResponse(status: 503))
            .releaseToAnnounce(comparedTo: running)
        XCTAssertNil(offline)

        let nonePublished = await StubSource(release: nil).releaseToAnnounce(comparedTo: running)
        XCTAssertNil(nonePublished)
    }

    /// With no version to compare against there is no comparison to make, and
    /// guessing one would announce an update to a build that may be newer than
    /// the release.
    func testABuildWithNoVersionIsToldNothing() async throws {
        let answer = await StubSource(release: try release("0.9.0"))
            .releaseToAnnounce(comparedTo: nil)

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

    /// The notes come with the release: the landing screen's "What's new"
    /// section is drawn from the body, so a body github.com sends is one the
    /// release carries.
    func testTheNotesComeWithTheRelease() throws {
        let json = Data("""
        {"tag_name": "v0.9.0", "html_url": "https://github.com/maxshevelev/ByteRipper/releases/tag/v0.9.0",
         "body": "A release about the structure tree.\\n\\n### Smaller things\\n\\n- One more thing."}
        """.utf8)

        let release = try XCTUnwrap(GitHubReleases.release(fromJSON: json))

        XCTAssertEqual(release.body,
                       "A release about the structure tree.\n\n### Smaller things\n\n- One more thing.")
        XCTAssertEqual(release.summary, "A release about the structure tree.")
    }

    /// GitHub answers `null` for a release written without notes, and that is
    /// no notes rather than an empty one: the section simply stays off.
    func testAReleaseWithoutNotesHasNone() throws {
        let json = Data("""
        {"tag_name": "v0.9.0", "html_url": "https://github.com/maxshevelev/ByteRipper/releases/tag/v0.9.0",
         "body": null}
        """.utf8)

        let release = try XCTUnwrap(GitHubReleases.release(fromJSON: json))

        XCTAssertNil(release.body)
        XCTAssertNil(release.summary)
    }

    // MARK: - The first paragraph

    /// The paragraph is wrapped over source lines the way a paragraph wraps;
    /// the reading joins them, and the next paragraph — where the sections and
    /// the lists live — is not part of it.
    func testTheFirstParagraphJoinsItsWrappedLinesAndStopsAtTheBlankLine() {
        let body = """
        A release about the structure tree reading what was padding before: the
        variable stores of every vendor the bench meets. And the ME Analyzer
        shows its summary the moment the region is read.

        ### Smaller things

        - One more thing.
        """

        XCTAssertEqual(Release.firstParagraph(of: body),
                       "A release about the structure tree reading what was padding before: the "
                       + "variable stores of every vendor the bench meets. And the ME Analyzer "
                       + "shows its summary the moment the region is read.")
    }

    /// The prose may carry the marks the bodies allow, and the reading reduces
    /// them to the prose: bold and code lose their marks, a link keeps its
    /// words and loses its destination.
    func testTheMarksTheProseCarriesAreReducedToTheProse() {
        let body = "Reads the **variable stores** and the `FSEG` header, as [the book](https://github.com/maxshevelev/ByteRipper) says."

        XCTAssertEqual(Release.firstParagraph(of: body),
                       "Reads the variable stores and the FSEG header, as the book says.")
    }

    /// Blank lines before the first paragraph are not a paragraph; a body of
    /// nothing at all leaves the section with nothing to show.
    func testABodyWithNoParagraphToReadHasNoSummary() {
        XCTAssertNil(Release.firstParagraph(of: ""))
        XCTAssertNil(Release.firstParagraph(of: "\n\n   \n\n"))
        XCTAssertEqual(Release.firstParagraph(of: "\n\nThe real opening."), "The real opening.")
    }
}
