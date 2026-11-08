import Foundation

/// Gathers the files handed to the app in one gesture into one batch.
///
/// Two files dropped together on the Dock icon do not arrive together: the
/// system hands the app one open event per file, back to back, and each
/// opened on its own made a window apiece where the two were meant to be
/// compared in one (`HandedFilesPlacement`). So a file is held for a moment;
/// one that follows it within that moment joins it, and the batch opens once,
/// when the files stop coming.
@MainActor
final class HandedFilesBatch {
    /// How long a file waits for the next. Long enough for the events of one
    /// drop — they follow within milliseconds — and short enough not to be
    /// felt.
    static let window: Duration = .milliseconds(250)

    private let delay: Duration
    private let open: ([URL]) -> Void
    private var urls: [URL] = []
    private var pending: Task<Void, Never>?

    init(delay: Duration = HandedFilesBatch.window, open: @escaping ([URL]) -> Void) {
        self.delay = delay
        self.open = open
    }

    /// Adds `incoming` to the batch and starts its moment again. A file
    /// handed twice is one file.
    func add(_ incoming: [URL]) {
        for url in incoming where !urls.contains(url) {
            urls.append(url)
        }
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Opens what has gathered, now.
    func flush() {
        pending?.cancel()
        pending = nil
        guard !urls.isEmpty else { return }
        let batch = urls
        urls = []
        open(batch)
    }
}
