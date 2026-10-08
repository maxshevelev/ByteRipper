import Foundation

/// Cuts a byte stream into the lines MCP sends one message on.
///
/// The stream arrives in whatever pieces the socket hands over: half a message,
/// three and a half, a message split inside a multi-byte character. This holds
/// the unfinished tail until its newline comes, and nothing else.
///
/// A line longer than `maxLineBytes` is refused rather than buffered: the
/// bytes are dropped as they arrive, up to the next newline, and the line is
/// reported once as too long. A peer that never sends a newline therefore
/// costs a bounded buffer, not the app's memory.
public struct LineFramer: Sendable {
    public enum Line: Equatable, Sendable {
        case message(Data)
        /// A line that went past the bound. Its bytes are gone.
        case tooLong
    }

    public let maxLineBytes: Int
    private var buffer = Data()
    /// The current line has gone past the bound and is being skipped.
    private var discarding = false

    public init(maxLineBytes: Int = 4 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    /// Takes the next piece of the stream and returns the lines it completed.
    /// Blank lines are not messages and are not returned; a carriage return
    /// before the newline is dropped, so a peer that writes `\r\n` is read the
    /// same as one that writes `\n`.
    public mutating func append(_ chunk: Data) -> [Line] {
        var lines: [Line] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding {
                discarding = false
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if buffer.count + piece.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: true)
                lines.append(.tooLong)
                continue
            }
            buffer.append(contentsOf: piece)
            if buffer.last == 0x0D { buffer.removeLast() }
            if !buffer.isEmpty { lines.append(.message(buffer)) }
            buffer = Data()
        }
        guard !discarding else { return lines }
        if buffer.count + rest.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: true)
            discarding = true
            lines.append(.tooLong)
        } else {
            buffer.append(contentsOf: rest)
        }
        return lines
    }
}
