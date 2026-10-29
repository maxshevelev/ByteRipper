import Foundation

/// How much the server holds open at once (`Design/SERVER_HEADLESS_PLAN.md`
/// decisions 11 and 12). Only open documents count: a missing row holds no
/// bytes. Decompressed buffers are measured, not capped.
public struct DumpLimits: Equatable, Sendable {
    /// `--max-documents`.
    public var documents = 8
    /// `--max-open-bytes`, over the files' sizes.
    public var openBytes: UInt64 = 512 << 20
    /// `--max-upload-bytes`, for the upload route alone.
    public var uploadBytes: UInt64 = 256 << 20

    public init() {}

    /// A size in the words of a refusal: `512 MiB`.
    static func words(_ bytes: UInt64) -> String {
        bytes >= 1 << 20 && bytes % (1 << 20) == 0 ? "\(bytes >> 20) MiB" : "\(bytes) bytes"
    }
}

/// Why a row holds its id and serves nothing (decision 18): the file is gone,
/// its path is outside the roots, the root it was opened under is not there,
/// or a limit refused it.
public enum MissingReason: Codable, Equatable, Sendable {
    case gone
    case outsideRoots
    /// A `--dump-roots` directory that does not resolve: the document is
    /// untouched, the volume is not mounted or the root is mistyped. Named,
    /// because "the file is gone" would send the operator looking at the file.
    case rootMissing(String)
    /// The limit, in words: `the limit of 8 open documents`.
    case limit(String)

    public var message: String {
        switch self {
        case .gone: return "the file is gone"
        case .outsideRoots: return "its path is outside the dump roots"
        case .rootMissing(let root): return "the dump root \(root) is not there"
        case .limit(let limit): return "opening it would pass \(limit)"
        }
    }
}
