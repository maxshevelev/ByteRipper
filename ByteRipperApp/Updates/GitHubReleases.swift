import Foundation
import FreshData

/// A release published on github.com.
struct Release: Equatable, Sendable {
    /// The version its tag names, "0.9.0".
    let version: AppVersion

    /// The release's own page — where a download and the notes are. What the
    /// landing screen opens when its line is clicked.
    let page: URL

    /// The notes as published: markdown, or `nil` when the release has none.
    /// The landing screen shows the first paragraph of them and nothing else
    /// (`summary`); the rest is where a click on the line above goes.
    var body: String? = nil

    /// Whether this release is newer than the version that is running.
    func isNewer(than running: AppVersion) -> Bool { version > running }

    /// The opening paragraph of the notes as plain prose — the only part the
    /// landing screen shows — or `nil` when there is no paragraph to show:
    /// no notes at all, or notes whose first paragraph is empty.
    var summary: String? {
        body.flatMap(Self.firstParagraph(of:))
    }

    /// The first paragraph of a release body, read as the prose it is written
    /// in.
    ///
    /// The body is markdown, but the opening paragraph is the summary the
    /// release is written with — plain sentences, wrapped over source lines the
    /// way a paragraph wraps. The reading is: the first paragraph that says
    /// anything, its wrapped lines joined into one line, and the marks the
    /// prose may carry reduced to the prose itself — **bold** and `code` lose
    /// their marks, a link keeps its words and loses its destination.
    static func firstParagraph(of body: String) -> String? {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        // A paragraph ends at a blank line; a single newline inside one is a
        // wrap, not a break.
        guard let first = normalized.components(separatedBy: "\n\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }

        var text = first
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // `[words](destination)` keeps its words. Measured against the shape
        // the bodies carry: the words have no `]` in them, and the
        // destination has no `)` in it.
        if let links = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)") {
            text = links.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

/// What the landing screen is told about, and which of its two cases it is:
/// the build running, or one the build is older than.
struct ReleaseAnnouncement: Equatable, Sendable {
    let release: Release

    /// Whether the release is the build running — as opposed to being newer
    /// than it, the case that also gets the "available" line.
    let isRunningBuild: Bool
}

/// Where "is there a newer version of this app?" is asked.
///
/// A protocol for the same reason the live data sources are protocols: the app
/// suite must not touch the network. A suite that reaches github.com is a suite
/// that fails on a train, and this one would fail on a bench that simply has no
/// internet — which is not a defect in what is being tested.
protocol ReleaseSource: Sendable {
    /// The newest published release, or `nil` when this repository has
    /// published none. Throws when the question could not be asked at all.
    func latestRelease() async throws -> Release?
}

/// A source with nothing to announce: a repository that has published no
/// releases, and what an app under test asks instead of github.com.
struct NoReleases: ReleaseSource {
    func latestRelease() async throws -> Release? { nil }
}

extension ReleaseSource {
    /// The release the landing screen shows its notes about — the newest
    /// published one, when it is the build running or one newer than it — and
    /// which of the two cases that is.
    ///
    /// Everything that can go wrong, and every case that leaves nothing to say,
    /// answers `nil`: no network, a rate limit, a repository with no releases,
    /// a bundle with no version to compare against, and a build made after the
    /// newest release was published — for that one no published release is
    /// either the build or news about it. The landing screen is there to open a
    /// file, not to report on github.com; a bench whose window says nothing has
    /// lost nothing, and one that is told a check failed has been handed a
    /// problem it cannot act on.
    func releaseToAnnounce(comparedTo running: AppVersion?) async -> ReleaseAnnouncement? {
        guard let running, let release = try? await latestRelease() else { return nil }
        if release.version == running {
            return ReleaseAnnouncement(release: release, isRunningBuild: true)
        }
        return release.isNewer(than: running)
            ? ReleaseAnnouncement(release: release, isRunningBuild: false)
            : nil
    }
}

/// What went wrong on the way to the release. Nothing shows these words — a
/// failed check is silent by design, above — but a thrown error with a name is
/// what a test asserts on and what a future caller can report.
enum ReleaseCheckError: LocalizedError, Equatable {
    case badResponse(status: Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            return "github.com answered \(status)."
        }
    }
}

/// `github.com/maxshevelev/ByteRipper` — where this app's releases are.
///
/// One request for the newest release, held for the run and re-checked once a
/// day (`Freshened`), because the landing screen is drawn again every time the
/// last file is closed: an app that asked github.com on each of those would be
/// spending its rate limit telling a window what it already knew.
///
/// The check is asked of `/releases/latest` rather than of the list, which is
/// the one answer that always has the same shape and that leaves out drafts and
/// prereleases on its own. A bench should not be told that a beta is what to
/// move to.
struct GitHubReleases: ReleaseSource {
    /// The repository the app is published from.
    static let repository = URL(string: "https://github.com/maxshevelev/ByteRipper")!

    /// The API rather than the releases page: the page is a form built for a
    /// reader, and this is a question with one answer.
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/maxshevelev/ByteRipper/releases/latest"
    )!

    /// The one the app asks: one held answer for the whole run, however many
    /// windows are open and however often they are drawn again.
    static let shared = GitHubReleases()

    private let session: URLSession
    private let held: Freshened<Release?>

    init(session: URLSession = .shared) {
        self.session = session
        self.held = Freshened(ttl: 24 * 60 * 60)
    }

    func latestRelease() async throws -> Release? {
        let session = session
        return try await held.value { _ in
            .fresh(try await Self.get(session: session), validator: nil)
        }
    }

    /// What github.com answers, read into a `Release`.
    ///
    /// A repository that has published nothing answers `404`, and that is a
    /// `nil` release rather than a failure: it is the truth about the
    /// repository, not something that went wrong in asking.
    private static func get(session: URLSession) async throws -> Release? {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 20
        // `URLSession.shared` has a cache of its own, and a landing screen
        // drawn again must not be answered out of it: the whole point of the
        // held value above is that the app decides when to ask.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // GitHub answers an anonymous request without one less kindly.
        request.setValue("ByteRipper", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw ReleaseCheckError.badResponse(status: http.statusCode)
        }
        return try release(fromJSON: data)
    }

    /// The release github.com describes, read out of the answer.
    ///
    /// Separate from the request so that the reading of it — which is the part
    /// that can be wrong in ways a network cannot cause — is tested against a
    /// fixture instead of against github.com.
    static func release(fromJSON data: Data) throws -> Release? {
        struct Payload: Decodable {
            var tag_name: String
            var html_url: String
            /// The notes markdown, or `null` when the release has none.
            var body: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = AppVersion(payload.tag_name) else { return nil }
        // A tag whose page the app cannot open is a line that promises a click,
        // so the releases page stands in: the release is listed on it. Measured:
        // `URL(string:)` is no help on its own, because it is happy to make a
        // *relative* URL out of almost anything.
        let page = openable(payload.html_url)
            ?? repository.appendingPathComponent("releases")
        return Release(version: version, page: page, body: payload.body)
    }

    /// A URL that can be opened in a browser: an absolute `http` or `https` one.
    ///
    /// A relative URL is not nothing to `URL(string:)` — it answers "not a url"
    /// with the relative "not%20a%20url" — and handing one of those to
    /// `NSWorkspace` is a click that does nothing at all.
    private static func openable(_ written: String) -> URL? {
        guard let url = URL(string: written),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }
}
