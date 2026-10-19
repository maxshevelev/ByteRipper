import Cocoa
import Localization
import UniformTypeIdentifiers

/// The projects opened lately, newest first, for **File ▸ Open Recent
/// Project**, and the one that was open when the app last stood
/// (`Design/WORKSPACE_PLAN.md`, "Projects").
///
/// The same shape as `RecentFilesStore`: plain paths in the app's defaults.
/// A list of its own because the two answer different questions — which dump,
/// and which job.
enum RecentProjectsStore {
    static let userDefaultsKey = "RecentProjects"
    static let lastProjectKey = "LastProject"
    static let limit = 10

    static var defaults: UserDefaults { AppDefaults.store }

    static var recent: [String] {
        (defaults.array(forKey: userDefaultsKey) as? [String] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        var entries = recent.filter { $0 != path }
        entries.insert(path, at: 0)
        defaults.set(Array(entries.prefix(limit)), forKey: userDefaultsKey)
    }

    static func clear() {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// The project open when the app last stood, if it is still there: what
    /// a launch reopens when the workspace is restored.
    static var lastProject: URL? {
        get {
            guard let path = defaults.string(forKey: lastProjectKey),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let newValue {
                defaults.set(newValue.standardizedFileURL.path, forKey: lastProjectKey)
            } else {
                defaults.removeObject(forKey: lastProjectKey)
            }
        }
    }
}

extension UTType {
    /// A ByteRipper project: a package — a folder Finder shows as one file —
    /// holding `Project.json` and the bytes nothing else on disk has.
    static let byteRipperProject = UTType(exportedAs: "dev.maxik.byteripper.project", conformingTo: .package)
}

extension URL {
    /// Whether this names a ByteRipper project rather than a dump.
    var isByteRipperProject: Bool {
        pathExtension.lowercased() == "brp"
    }
}

/// Fills **File ▸ Open Recent Project** before each display, as
/// `OpenRecentMenuController` does for the dumps.
@MainActor
final class OpenRecentProjectMenuController: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = RecentProjectsStore.recent
        for path in recent {
            let item = NSMenuItem(
                title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                action: #selector(AppDelegate.openRecentProject(_:)),
                keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            menu.addItem(item)
        }
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Clear Menu"),
                         action: #selector(AppDelegate.clearRecentProjects(_:)), keyEquivalent: "")
        }
    }
}
