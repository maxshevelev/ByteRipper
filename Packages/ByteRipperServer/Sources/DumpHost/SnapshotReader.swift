import Foundation
import ToolModuleKit

/// A document's bytes as they were read at open: the snapshot of
/// `Design/SERVER_HEADLESS_PLAN.md` decision 9.
///
/// The file is read whole into memory, never mapped. A mapped file is not a
/// snapshot: a writer that rewrites it in place changes the bytes under an
/// agent, and one that truncates it ends the process with `SIGBUS`.
public struct SnapshotReader: ToolContentReader {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var size: UInt64 { UInt64(data.count) }

    public func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            throw SnapshotReader.OutOfRange(offset: offset, length: length, size: size)
        }
        let start = data.startIndex + Int(offset)
        return [UInt8](data[start..<start + length])
    }

    public struct OutOfRange: Error, CustomStringConvertible {
        public let offset: UInt64
        public let length: Int
        public let size: UInt64

        public var description: String {
            "\(length) bytes at 0x\(String(offset, radix: 16, uppercase: true)) run past the end of a "
                + "\(size)-byte document"
        }
    }
}
