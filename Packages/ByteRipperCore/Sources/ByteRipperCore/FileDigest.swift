import CryptoKit
import Foundation

/// SHA-256 of what a workspace lays its kept content over: the file on disk a
/// project points to, and the bases it writes beside itself
/// (`Design/PERSISTENT_UNDO_PLAN.md`, "Integrity"). Size and date are a quick
/// first look; this is what decides.
public enum FileDigest {
    /// The digest of the file at `url`, read in slices, never whole.
    public static func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let slice = try handle.read(upToCount: 1 << 20), !slice.isEmpty {
            hasher.update(data: slice)
        }
        return Data(hasher.finalize())
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// A digest made in pieces, as bytes are written.
    public struct Running {
        private var hasher = SHA256()

        public init() {}

        public mutating func update(_ bytes: [UInt8]) {
            hasher.update(data: bytes)
        }

        public func finalize() -> Data {
            Data(hasher.finalize())
        }
    }
}
