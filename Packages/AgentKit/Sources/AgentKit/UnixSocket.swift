import Foundation

/// The Unix-domain socket the agent service listens on and the relay connects
/// to (`Design/AGENT_PLAN.md`, "Transport").
///
/// A file in the user's own Library, mode 0600 inside a folder of 0700: the
/// file system is the authentication. Whoever can open it is the user already,
/// and nothing reaches it from the network — so there is no port to pick, no
/// token to hand out, and no firewall prompt.
///
/// Blocking reads, one thread per connection. There are one or two clients at
/// a time, and a thread that sleeps in `read` is the simplest correct thing:
/// no partial-write bookkeeping, no readiness sources to keep alive.
public enum UnixSocket {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// `sun_path` holds 104 bytes on macOS, the terminator included.
        case pathTooLong(String)
        /// Another process — a second copy of the app — is listening there.
        case inUse(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let path): return "Socket path too long: \(path)"
            case .inUse(let path): return "Another process is listening on \(path)"
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Connects to the socket at `path` and returns the open descriptor.
    public static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        noSigPipe(fd)
        var address = try address(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure.system("connect", code)
        }
        return fd
    }

    /// Writes all of `data`, retrying a write the kernel took only part of.
    /// False once the other end has gone.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    /// Reads what is there, up to 64 KiB, waiting for at least a byte. Nil at
    /// the end of the stream or on an error, which mean the same to a caller:
    /// the other end is gone.
    public static func readSome(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { return Data(buffer[0..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A write to a socket whose reader has gone raises SIGPIPE, and SIGPIPE's
    /// default is to end the process — the whole app, for one client that
    /// closed its terminal. This makes such a write fail with EPIPE instead.
    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// Listens on a socket path and hands over every connection made to it.
public final class UnixSocketListener: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()
    /// The write end of the pipe the accepting thread also waits on: a byte
    /// written to it is how `stop()` wakes that thread. Closing a descriptor
    /// another thread is blocked in `accept` on is not guaranteed to wake it,
    /// and its number could be handed to the next socket opened while the
    /// thread is still about to use it.
    private var stopFD: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit { stop() }

    /// Starts listening. A socket file left by a process that has gone is
    /// removed; one that something still answers on is not, and this throws
    /// `inUse` — the other copy of the app keeps its clients.
    public func start(onConnection: @escaping @Sendable (UnixSocketConnection) -> Void) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            if let fd = try? UnixSocket.connect(to: path) {
                Darwin.close(fd)
                throw UnixSocket.Failure.inUse(path)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.Failure.system("socket", errno) }
        var address = try UnixSocket.address(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocket.Failure.system("bind", code)
        }
        chmod(path, 0o600)
        var pipeFDs: [Int32] = [-1, -1]
        guard listen(fd, 8) == 0, pipe(&pipeFDs) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocket.Failure.system("listen", code)
        }
        lock.withLock { stopFD = pipeFDs[1] }
        let wakeFD = pipeFDs[0]

        let thread = Thread {
            var watched = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0)]
            while true {
                let ready = poll(&watched, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if watched[1].revents != 0 { break }
                guard watched[0].revents & Int16(POLLIN) != 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                UnixSocket.noSigPipe(client)
                onConnection(UnixSocketConnection(fd: client))
            }
            // This thread is the only one that uses these, so it is the one
            // that lets them go.
            Darwin.close(fd)
            Darwin.close(wakeFD)
        }
        thread.name = "AgentSocket.accept"
        thread.start()
    }

    /// Stops listening and removes the socket file. Connections already made
    /// stay open until their own `close`.
    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = stopFD
            stopFD = -1
            return fd
        }
        guard fd >= 0 else { return }
        unlink(path)
        var byte: UInt8 = 1
        _ = Darwin.write(fd, &byte, 1)
        Darwin.close(fd)
    }
}

/// One accepted client: its bytes in, on a thread of its own, and bytes out.
public final class UnixSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let writes = DispatchQueue(label: "AgentSocket.write")
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Reads until the client goes, handing over each chunk as it arrives, and
    /// then calls `onClose` once.
    public func startReading(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            while let chunk = UnixSocket.readSome(fd) {
                onData(chunk)
            }
            close()
            // Released here, by the one thread that reads it, and after the
            // writes already queued: nothing can be inside a call on this
            // descriptor when its number goes back to the system.
            writes.async { [fd] in Darwin.close(fd) }
            onClose()
        }
        thread.name = "AgentSocket.read"
        thread.start()
    }

    /// Sends `data`, in order with everything sent before it. A write after
    /// the client has gone is dropped.
    public func write(_ data: Data) {
        writes.async { [self] in
            guard !lock.withLock({ isClosed }) else { return }
            if !UnixSocket.writeAll(fd, data) { close() }
        }
    }

    public func close() {
        let first = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        // Wakes the reading thread, which ends, releases the descriptor and
        // reports the close.
        shutdown(fd, SHUT_RDWR)
    }
}
