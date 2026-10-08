import CryptoKit
import Foundation
import IOKit
import ByteRipperCore

/// Where the kept patterns live on this Mac, and how they get there
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// `~/Library/Application Support/ByteRipper/Favorites.json`: no panel,
/// correct on first launch, and the place Apple's guidance names for data the
/// app maintains on the user's behalf that is not a document.
///
/// That folder is the user's, not the bundle identifier's — the app is not
/// sandboxed, so there is no container keyed by identifier to keep a test run
/// apart from the real app. A test host therefore never defaults to it
/// (`defaultURL()`).
///
/// The file holds the favourites and nothing else — the recents are a
/// per-machine cache and stay in `UserDefaults`, as do the appearance and the
/// file types. That is why it is not called `Library.json`: a name should not
/// promise more than the file holds.
enum FavoritesFile {
    /// The file the app reads and writes. Settable so tests write a temporary
    /// file instead of the user's own library — and, later, so the library can
    /// be published somewhere the user chose (stage 5 of the plan).
    ///
    /// Pointing it elsewhere drops what the store remembers: the last good copy
    /// is about *a* file, and carrying it to another one would show patterns
    /// that file does not hold.
    static var url: URL = defaultURL() {
        didSet { FavoritePatternStore.forgetLastGood() }
    }

    /// The user's library — or, under test, a throwaway file of the run's own.
    ///
    /// The test host is the real app under another bundle identifier, and
    /// that identifier keeps its preferences apart (`AppDefaults`) but not its
    /// Application Support, which is the user's own folder. A suite that wrote
    /// the favourites without isolating them first would otherwise be writing
    /// the user's library — and the legacy-folder move in `directory(in:)`
    /// would rename the user's folders. Most suites isolate the file
    /// themselves (`isolatedFavoritesFile`); this is the backstop for the ones
    /// that touch the library without meaning to.
    static func defaultURL() -> URL {
        if AppDefaults.isUnderTest {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ByteRipperTests-DefaultLibrary", isDirectory: true)
                .appendingPathComponent("Favorites.json")
        }
        return shippedURL(in: applicationSupport)
    }

    /// The user's Application Support folder.
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Where the shipped app keeps the library, given the Application Support
    /// folder it lives under.
    static func shippedURL(in base: URL) -> URL {
        directory(in: base).appendingPathComponent("Favorites.json")
    }

    /// The folder the library lives in, moving the one the app used under its
    /// old name if that is the only one here.
    ///
    /// The app was called DumpCompare until this release, and its library sat in
    /// `Application Support/DumpCompare`, so the old folder may be sitting
    /// under the same Application Support beside a new one that does not exist
    /// yet. (The sandboxed builds kept theirs in the app's container, which
    /// the unsandboxed app does not read: that library is not carried over.)
    ///
    /// A failed move is not an error to report: it is a reason to go on reading
    /// the library where it already is. Presenting an empty library because a
    /// rename failed would look exactly like losing it.
    static func directory(in base: URL) -> URL {
        let current = base.appendingPathComponent("ByteRipper", isDirectory: true)
        let legacy = base.appendingPathComponent("DumpCompare", isDirectory: true)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: current.path),
              manager.fileExists(atPath: legacy.path)
        else { return current }
        do {
            try manager.moveItem(at: legacy, to: current)
            return current
        } catch {
            return legacy
        }
    }

    /// Reads the document, or nil when there is no file yet — which is a normal
    /// state (a fresh install), not an error.
    static func read() throws -> FavoritesDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FavoritesDocument(fileContents: Data(contentsOf: url))
    }

    /// Writes the document, creating the folder on the way.
    ///
    /// Atomically, so the truth and the base it was last agreed at can never be
    /// from two different rounds. Coordinating with *other* writers belongs to
    /// the shared file, not to this one: nothing else writes here.
    static func write(_ document: FavoritesDocument) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try document.fileContents().write(to: url, options: .atomic)
    }
}

/// This machine, as far as the library is concerned
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// It never syncs — that is the point of it. An entry says which machine last
/// changed it, a library says how many times each machine has written it, and
/// each machine writes a file of its own; all three are meaningless if two
/// machines can claim the same name, or if one machine's name changes under it.
///
/// Taken from the **hardware**, not from anything a person or a network can
/// rename: the Mac's platform UUID, which survives a reinstall, a rename and a
/// reset of this app's settings. A random id is kept only where that cannot be
/// read, and a value already stored is never replaced — an id that changed
/// would leave this machine's own past looking like a stranger's.
enum DeviceIdentity {
    static let userDefaultsKey = "LibraryDeviceIdentity"

    /// The defaults domain the id lives in — the store's, so a test that
    /// isolates one isolates both.
    static var defaults: UserDefaults { FavoritePatternStore.defaults }

    static var current: String {
        if let existing = defaults.string(forKey: userDefaultsKey), !existing.isEmpty {
            return existing
        }
        let minted = hardware() ?? UUID().uuidString
        defaults.set(minted, forKey: userDefaultsKey)
        return minted
    }

    /// The Mac's platform UUID, hashed.
    ///
    /// Hashed because the raw value identifies the machine to anyone who reads
    /// it, and this id is written into files in a folder the user shares. The
    /// hash is as stable and as unique, and says nothing else.
    static func hardware() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                                    kCFAllocatorDefault, 0)
        guard let uuid = value?.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return digest(of: uuid)
    }

    /// A short, stable stand-in for a string: the head of its SHA-256, in hex.
    /// Long enough that two Macs colliding is not a thing that happens, short
    /// enough to read out over a phone.
    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6)
            .map { String(format: "%02X", $0) }.joined()
    }
}
