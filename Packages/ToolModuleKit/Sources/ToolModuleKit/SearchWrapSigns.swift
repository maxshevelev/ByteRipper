import AppKit

/// The sign on the plate a search shows when it has come round to the other
/// end: an arrow round a capsule, its head top right for a search that ran off
/// the end, bottom left for one that ran off the start. The hex view's find and
/// the tree's search both show it, so they say it with the one sign — which is
/// why it lives here, where the app and a tool-module can both reach it.
///
/// The plain circular arrows stand in on a macOS that does not have the
/// capsule ones: those arrived in SF Symbols 6, and the app runs on 14.
public enum SearchWrapSigns {
    public static let forward = symbolName(
        "arrow.trianglehead.topright.capsulepath.clockwise", or: "arrow.clockwise")
    public static let backward = symbolName(
        "arrow.trianglehead.bottomleft.capsulepath.clockwise", or: "arrow.counterclockwise")

    /// The sign for a search that went `forward` or backward.
    public static func sign(forward isForward: Bool) -> String {
        isForward ? forward : backward
    }

    private static func symbolName(_ preferred: String, or fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil
            ? preferred : fallback
    }
}
