import CoreServices
import Foundation

/// Says when the store's analyses may have changed, whoever changed them.
///
/// The store is written by the Ghidra skill in another process, by a project
/// import here, or by a CLI. Every one of them ends a write by renaming a
/// manifest into `analyses/`, so a file-system event stream on that folder is
/// the change notification the store has no other way to give — immediate,
/// and costing nothing while nothing is written. The event is a hint: the
/// caller reads the index again, and the index decides.
///
/// The stream watches the nearest folder that exists, so a store the skill
/// creates after launch is seen too.
public final class CodeStoreWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let analyses: String
    private let onChange: @Sendable () -> Void

    /// - Parameters:
    ///   - latency: how long FSEvents gathers events before it reports them;
    ///     a manifest, its folder and its temp file arrive as one call.
    ///   - onChange: called on the main queue.
    public init(root: URL, latency: TimeInterval = 0.3,
                onChange: @escaping @Sendable () -> Void) {
        // FSEvents reports real paths (`/private/var/…` for a temporary
        // folder), and the store may not exist yet: resolve the nearest folder
        // that does, and put the rest of the path back on it.
        var watched = root.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: watched.path), watched.path != "/" {
            missing.insert(watched.lastPathComponent, at: 0)
            watched.deleteLastPathComponent()
        }
        let real = watched.withUnsafeFileSystemRepresentation { path in
            path.flatMap { realpath($0, nil) }.map { resolved in
                defer { free(resolved) }
                return String(cString: resolved)
            }
        } ?? watched.path
        analyses = ([real] + missing + ["analyses"]).joined(separator: "/")
            .replacingOccurrences(of: "//", with: "/")
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context,
            [real] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        stop()
    }

    /// Ends the stream. Safe to call twice; the watcher is inert after it.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Whether one of the paths FSEvents reported is inside `analyses/` — or
    /// is a folder above it, which FSEvents names when it had to coalesce.
    func concernsAnalyses(_ paths: [String]) -> Bool {
        paths.contains { path in
            path == analyses || path.hasPrefix(analyses + "/") || analyses.hasPrefix(path + "/")
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<CodeStoreWatcher>.fromOpaque(info).takeUnretainedValue()
        let reported = unsafeBitCast(paths, to: NSArray.self)
        let list = (0..<count).compactMap { reported[$0] as? String }
        if watcher.concernsAnalyses(list) {
            watcher.onChange()
        }
    }
}
