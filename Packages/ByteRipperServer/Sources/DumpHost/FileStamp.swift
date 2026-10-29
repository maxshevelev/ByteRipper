import Foundation

/// What a `stat` says of a file, for telling whether it is still the one
/// read (`Design/SERVER_HEADLESS_PLAN.md` decision 9).
///
/// Inode, ctime, mtime and size — not mtime and size alone: a dump of the
/// same chip has the same size, and `cp -p`, `rsync -a` or an unpacked
/// archive keep another file's mtime, while ctime cannot be set and changes
/// on every write, and the inode changes when the file is replaced
/// atomically.
public struct FileStamp: Codable, Equatable, Sendable {
    public var inode: UInt64
    public var ctime: Int64
    public var ctimeNanoseconds: Int64
    public var mtime: Int64
    public var mtimeNanoseconds: Int64
    public var size: UInt64

    enum CodingKeys: String, CodingKey {
        case inode
        case ctime
        case ctimeNanoseconds = "ctime_ns"
        case mtime
        case mtimeNanoseconds = "mtime_ns"
        case size
    }

    /// The file's stamp now; nil when the `stat` fails — deleted or renamed.
    public static func of(_ url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileStamp(inode: UInt64(info.st_ino),
                         ctime: Int64(info.st_ctimespec.tv_sec), ctimeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
                         mtime: Int64(info.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                         size: UInt64(info.st_size))
    }
}

/// How a document's file stands against the one read.
public enum DiskState: String, Codable, Sendable {
    /// The file is there but is not the one read.
    case changed
    /// The `stat` fails: deleted or renamed.
    case gone
}
