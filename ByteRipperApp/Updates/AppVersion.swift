import Foundation

/// A version number — this app's, or one published on github.com — read and
/// compared the way a version number is meant to be.
///
/// The reason this is a type rather than two strings is the comparison. A
/// release tag and a bundle's `CFBundleShortVersionString` are text, and text
/// compares wrongly: "0.8.10" sorts *before* "0.8.9", so a bench running 0.8.9
/// would be sent to a release that is older than what it has. The parts are
/// compared as numbers instead, left to right, with the ones one side is
/// missing read as zero — so "0.9" and "0.9.0" are the same version, as they
/// should be.
struct AppVersion: Comparable, Sendable {
    /// The number as it was written, with a leading "v" taken off: "0.8.2".
    /// This is what a label shows, so it stays spelled the way its source
    /// spelled it.
    let text: String

    /// The parts to compare. A tail that is not a number is not one of them:
    /// "0.9.0-beta" is 0.9.0 with a label after it, which is how the release
    /// that wears it is ordered.
    let parts: [Int]

    /// Reads a version out of a `CFBundleShortVersionString`, or out of a
    /// release tag like "v0.8.2".
    ///
    /// `nil` when there is no number in it at all, so a caller can say nothing
    /// rather than guess at one.
    init?(_ written: String) {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let numbered = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed

        var parts: [Int] = []
        for field in numbered.split(separator: ".", omittingEmptySubsequences: false) {
            // `Int("")` is nil, so a field with no digits in it — the tail of
            // "0.9.0-beta", or an empty field out of "0..2" — stops the read
            // here and leaves the parts before it.
            guard let part = Int(field.prefix { $0.isNumber }) else { break }
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }

        self.text = numbered
        self.parts = parts
    }

    /// The version this build is, from the running bundle.
    ///
    /// `nil` when the bundle has none to read — a test bundle, or a build made
    /// without a version. That is the answer that keeps a caller from comparing
    /// a release against nothing and calling the result an update.
    ///
    /// The landing screen shows the bundle's own spelling of this, not this
    /// value's: one is what a reader is told, the other is what a comparison is
    /// made with.
    static var current: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(AppVersion.init)
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs.parts, rhs.parts) == .orderedSame
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs.parts, rhs.parts) == .orderedAscending
    }

    /// Parts compared as numbers, with the ones a side is missing read as zero
    /// — which is both what makes 0.9.0 newer than 0.9.0.0's own self and what
    /// keeps `==` agreeing with `<`, as `Comparable` requires of them.
    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
