import Foundation
import ByteRipperCore

/// The folder a synced collection is published to, remembered across launches
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// **A folder, not a file.** Every machine writes a file of its own and reads
/// everyone else's (`fileName(for:)`), so what the app has to reach is the
/// folder they all sit in, along with the copies a sync client leaves beside
/// them when it cannot decide. A single file would also be the wrong thing to
/// hold on to: every atomic write replaces it, this Mac's, every other Mac's
/// and iCloud's.
///
/// So the user chooses a folder their Mac syncs, and the files inside it are
/// the app's to name.
///
/// Generic in the *kind* of collection, because none of this is about patterns:
/// a folder, a name for each machine's file in it, and a path that outlives a
/// launch are what anything the app syncs will need (`SyncedCollectionKind`).
enum SyncFolder<Kind: SyncedCollectionKind> {
    static var folderPathKey: String { Kind.folderPathKey }

    /// The domain the location lives in — the owning store's, so a test that
    /// isolates one isolates both.
    static var defaults: UserDefaults { Kind.defaults }

    /// What every library file in the folder is called, before the part that
    /// says which machine wrote it. It is the name a stranger sees, in a folder
    /// among other people's files, where the app's own word for the feature
    /// says nothing and the content has to.
    static var fileStem: String { Kind.fileStem }
    static var fileExtension: String { SyncFolderAccess.fileExtension }

    /// **One file per machine.** Each Mac writes its own and reads everyone
    /// else's; no file ever has two writers, so there is nothing for a sync
    /// client to arbitrate — no "last write wins", no conflicted copies, and no
    /// version quietly discarded between two machines that were both offline.
    ///
    /// The name is a hash of the machine's id and nothing else. Not its
    /// *hostname*: a laptop takes a new one from whatever network it joins, and
    /// anybody can change one whenever they like — and a file whose name moves
    /// is a machine that starts writing a second file and leaves the first
    /// behind for ever. Not the id itself either: it goes into a folder the
    /// user shares, and a hash identifies the file as well while saying nothing
    /// about the Mac. Which Mac wrote it is *inside* the file, where a changed
    /// name is a changed line rather than a new file.
    static func fileName(for device: String) -> String {
        "\(fileStem) (\(DeviceIdentity.digest(of: device))).\(fileExtension)"
    }

    /// The file *this* machine writes inside `folder`.
    static func file(in folder: URL, device: String? = nil) -> URL {
        folder.appendingPathComponent(fileName(for: device ?? DeviceIdentity.current))
    }

    /// Every machine's library file in `folder`, in a fixed order so two runs
    /// merge the same folder the same way.
    ///
    /// Matched by name rather than by content: a file that cannot be read yet
    /// — a placeholder iCloud has not downloaded — has to be in the list, or
    /// the merge would treat a machine that is present as one that never wrote.
    static func libraryFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isLibraryFile).sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Whether a name is one of this app's library files: a machine's own, and
    /// nothing else.
    ///
    /// One bracketed label, and it has to be a machine's stamp: twelve hex
    /// digits. That is what keeps everything else out of the library — the
    /// copies a sync client leaves ("… (A93F1C0D22B7) 2.json", "… (conflicted
    /// copy 2026-09-05).json") and any file the user named themselves. The app
    /// does not read them, fold them in or remove them: a file it did not write
    /// is the user's to look at.
    static func isLibraryFile(_ name: String) -> Bool {
        guard name.hasSuffix(".\(fileExtension)") else { return false }
        let opening = "\(fileStem) ("
        guard name.hasPrefix(opening), name.hasSuffix(").\(fileExtension)") else { return false }
        let label = name.dropFirst(opening.count).dropLast(").\(fileExtension)".count)
        return label.count == stampLength
            && label.allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }

    /// How long a machine's stamp is, in characters (`DeviceIdentity.digest`).
    static var stampLength: Int { SyncFolderAccess.stampLength }

    /// The folder the library is published to, or nil when the library is
    /// kept to this Mac.
    ///
    /// Kept as a plain path. The app is not sandboxed, so a path is all it
    /// takes to reach a folder again: nothing has to be re-earned at launch,
    /// and nothing goes stale when a sync client replaces a file inside it.
    /// What macOS still guards is a handful of places — Documents, Desktop,
    /// iCloud Drive — and there it asks the user once, the first time the app
    /// reaches in, and remembers the answer for this app.
    static func restore() -> URL? {
        guard let path = defaults.string(forKey: folderPathKey) else {
            hasAccess = false
            return nil
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        hasAccess = isReachable(folder)
        return folder
    }

    /// Whether the folder was there to be written to the last time the app
    /// looked: when it was restored at launch, or when it was chosen.
    ///
    /// False means the remembered path leads nowhere the app can write — a
    /// drive that is not mounted, a folder moved or deleted in the Finder, or
    /// one the user refused the app when macOS asked. Writing will fail until
    /// the folder is back or the user points at another.
    static var hasAccess: Bool {
        get { SyncFolderAccess.granted[Kind.fileStem] ?? false }
        set { SyncFolderAccess.granted[Kind.fileStem] = newValue }
    }

    /// Whether `folder` is a directory this app may write into.
    private static func isReachable(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: folder.path)
    }

    /// Remembers `folder` as the place the library is published to.
    ///
    /// Called again after every publish, which is a write into the folder that
    /// just succeeded — so it is also what says the folder is reachable now.
    static func remember(_ folder: URL) {
        defaults.set(folder.standardizedFileURL.path, forKey: folderPathKey)
        hasAccess = true
    }

    static func forget() {
        hasAccess = false
        defaults.removeObject(forKey: folderPathKey)
    }

    /// Where the panel opens when the library has never been published: iCloud
    /// Drive if the user has it, and their Documents folder otherwise.
    static func suggestedFolder() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) { return iCloud }
        return home.appendingPathComponent("Documents")
    }
}


/// Which folders this run has a live grant for, by collection.
///
/// Beside `SyncFolder` rather than in it: a generic type cannot hold a stored
/// static, and this is state about the running app rather than about a kind.
enum SyncFolderAccess {
    static var granted: [String: Bool] = [:]

    /// What every one of these files is called, after the machine's stamp.
    static let fileExtension = "json"

    /// How long a machine's stamp is, in characters (`DeviceIdentity.digest`).
    static let stampLength = 12
}
