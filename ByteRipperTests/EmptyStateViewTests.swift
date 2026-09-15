import XCTest
@testable import ByteRipper

/// §3.1 empty state: the landing screen is a large clickable icon (replacing
/// the old titled Open File button), a "Drop files here" headline and the
/// up-to-two-files hint. Clicking the icon is wired to the same open-panel
/// action the button used.
@MainActor
final class EmptyStateViewTests: XCTestCase {
    private func makeEmptyView() -> EmptyStateView {
        let view = EmptyStateView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return view
    }

    /// The whole landing screen, from one built view: the Open File affordance
    /// is an icon button — the titled button is gone, replaced by a borderless
    /// button whose image carries the "Open File" accessibility label and fires
    /// the open-panel action — under the headline and the up-to-two-files hint.
    func testOpenFileIconReplacesTitledButtonUnderTheHeadlineAndHint() {
        let view = makeEmptyView()
        let buttons = descendants(of: view, NSButton.self)

        XCTAssertFalse(buttons.contains { $0.title == "Open File" },
                       "the titled Open File button must be gone")
        guard let icon = buttons.first(where: { $0.accessibilityLabel() == "Open File" }) else {
            return XCTFail("an icon button labelled Open File must exist")
        }
        XCTAssertFalse(icon.isBordered)
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.action, #selector(MainViewController.presentOpenPanel))

        let labels = descendants(of: view, NSTextField.self).map { $0.stringValue }
        XCTAssertTrue(labels.contains("Drop files here"), "the headline must be shown")
        XCTAssertTrue(labels.contains("Up to two files can be compared side by side."),
                      "the up-to-two-files hint must be shown")
    }

    /// The landing screen signs off with the app's name and its number, taken
    /// from the bundle the test runs hosted in — so this asserts the label is
    /// the bundle's own name and version, not a copy of today's number that
    /// every release would have to remember to bump.
    func testLandingScreenShowsAppNameAndVersionUnderTheHint() {
        let view = makeEmptyView()
        let labels = descendants(of: view, NSTextField.self).map { $0.stringValue }

        XCTAssertTrue(labels.contains(EmptyStateView.appNameAndVersion),
                      "the app name and version must be shown under the hint")
        XCTAssertTrue(EmptyStateView.appNameAndVersion.hasPrefix("ByteRipper"),
                      "the line must name the app")
    }

    /// The version is the landing screen's anchor under the hint, not another
    /// quiet caption: larger than the hint above it, and the semibold face.
    func testTheVersionLineIsBiggerAndBolderThanTheHint() throws {
        let view = makeEmptyView()
        let labels = descendants(of: view, NSTextField.self)
        let version = try XCTUnwrap(
            labels.first { $0.stringValue == EmptyStateView.appNameAndVersion },
            "the version line"
        )
        let hint = try XCTUnwrap(
            labels.first { $0.stringValue.hasPrefix("Up to two files") },
            "the hint above it"
        )

        let size = try XCTUnwrap(version.font?.pointSize)
        XCTAssertGreaterThan(size, try XCTUnwrap(hint.font?.pointSize),
                             "the version is larger than the hint")
        XCTAssertEqual(version.font, .systemFont(ofSize: size, weight: .semibold),
                       "and it is the semibold one")
    }

    /// A newer release is announced under the version line, and the line knows
    /// where to go — nothing is announced until there is one, because an empty
    /// window is not the place for a line about nothing.
    func testANewerReleaseIsAnnouncedUnderTheVersionLine() throws {
        let view = makeEmptyView()
        XCTAssertNil(view.releaseLineForTesting, "nothing announced to begin with")

        let page = try XCTUnwrap(
            URL(string: "https://github.com/maxshevelev/ByteRipper/releases/tag/v0.9.0")
        )
        view.showAvailableRelease(
            Release(version: try XCTUnwrap(AppVersion("0.9.0")), page: page)
        )

        let line = try XCTUnwrap(view.releaseLineForTesting)
        XCTAssertEqual(line.text, "Version 0.9.0 is available on GitHub")
        XCTAssertEqual(line.page, page, "and clicking it opens that release")
    }

}
