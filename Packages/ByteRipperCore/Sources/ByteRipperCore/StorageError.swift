import Foundation

/// Errors thrown by the storage layer.
///
/// The presentation layer maps these to user-facing alerts (§16 of
/// REQUIREMENTS.md). `.permissionDenied` is a file the user may not read or
/// write: its own permissions, or a folder macOS protects and the user refused
/// the app.
public enum StorageError: Error, Equatable, Sendable {
    case fileNotFound
    case isDirectory
    case notRegularFile
    case permissionDenied
    case readFailed
    case writeFailed
    case invalidOffset

    /// Classifies a POSIX `open(2)` errno into a storage error.
    static func fromOpenError(_ code: Int32) -> StorageError {
        switch code {
        case ENOENT: return .fileNotFound
        case EISDIR: return .isDirectory
        case EACCES, EPERM: return .permissionDenied
        default: return .permissionDenied
        }
    }
}
