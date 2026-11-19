import Foundation
import Localization

/// Watches a file on disk for external modifications (§5.5).
///
/// Opens the file read-only (`O_EVTONLY`) and listens for write/rename/delete
/// events on a background queue. Events are debounced and delivered once on the
/// main actor via `onChange`. The watcher holds no document state — the caller
/// (the pane) decides what the event means and whether to prompt.
final class FileChangeWatcher {
    /// How long events are coalesced before one is delivered. A `var` so tests
    /// can shorten it: three tests were spending a second each waiting out a
    /// literal, and an inverted expectation ("nothing fires after stop") has to
    /// outlast whatever this is.
    static var debounceInterval: TimeInterval = 0.4

    /// Fired on the main actor after an external change, debounced.
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.maxik.ByteRipper.fileWatcher")

    init(url: URL) {
        start(url: url)
    }

    deinit {
        stop()
    }

    /// Restarts the watcher for `url`, dropping any pending debounce. Called
    /// after a save/revert when the file's inode may have been replaced by an
    /// atomic write — the old descriptor would otherwise keep watching an
    /// unlinked file forever.
    func rebind(to url: URL?) {
        stop()
        if let url {
            start(url: url)
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }

    // MARK: - Internals

    private func start(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        source = src
        src.setEventHandler { [weak self] in
            self?.scheduleNotify()
        }
        // The source closes the descriptor it was made with, and nothing else.
        // A handler that asked the watcher instead closed nothing once the
        // watcher was gone — `deinit` cancels, the handler runs later — and
        // after a `rebind` it could close the new file's descriptor, not this
        // one: either way a descriptor stayed open on a file long deleted.
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
    }

    /// Coalesces bursts of events (a save can produce several writes) into one
    /// `onChange` delivery a short while after the last one.
    private func scheduleNotify() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onChange?()
            }
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }
}
