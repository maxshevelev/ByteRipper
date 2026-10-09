import CryptoKit
import Foundation
import MEFirmware

/// Two dumps' ME file systems compared file by file, by what the files hold
/// (`Design/AGENT_PLAN.md`, stage 9).
///
/// Why not by address: an MFS volume moves its pages to spread the wear, so
/// one machine's two dumps keep the same file in different places, and a byte
/// comparison of the partition mostly finds pages moved. Here a file is matched
/// by what the volume calls it — its low-level index in MFS, its file ID in EFS
/// — and compared by its content, the Integrity table left off and compared
/// apart: the table's counters and HMAC change when a file is written again,
/// whether or not what it holds did.
///
/// One value for the agent's `me_files_compare` and for a panel that will show
/// it; neither computes anything of its own. The names are the file table's,
/// put on the way the panel names its rows (`MFSFileNames`, `EFSFileNames`) —
/// the model keeps saying numbers.
public struct MEFileComparison: Sendable, Equatable {
    public enum Volume: String, Sendable, CaseIterable {
        case mfs, efs
    }

    /// What became of one file between the two dumps.
    public enum Status: String, Sendable {
        /// The same content; `moved` says whether it is stored elsewhere.
        case same
        /// Content of another length, or bytes that differ.
        case different
        case onlyInA
        case onlyInB
        /// One side's chain ended early or ran in a circle, so what it holds is
        /// not known whole and no verdict is given.
        case incomplete
        /// Of one length on both sides, and neither the bytes nor a digest to
        /// tell — an analysis made before the model kept them.
        case unknown
    }

    /// One dump's copy of a file.
    public struct Side: Sendable, Equatable {
        /// What the volume stores for the file, Integrity table included.
        public var storedSize: Int
        /// The content, the table left off.
        public var contentSize: Int
        /// Where it is stored, in the file's order (`MFSFile.extents`). Empty
        /// for an analysis made before the model kept them.
        public var extents: [Range<Int>]
        public var contentDigest: String?
        public var integrity: MFSIntegrityTable?
        public var complete: Bool

        public init(storedSize: Int, contentSize: Int, extents: [Range<Int>],
                    contentDigest: String?, integrity: MFSIntegrityTable?, complete: Bool) {
            self.storedSize = storedSize
            self.contentSize = contentSize
            self.extents = extents
            self.contentDigest = contentDigest
            self.integrity = integrity
            self.complete = complete
        }
    }

    public struct Row: Sendable, Equatable {
        public var volume: Volume
        /// The low-level index (MFS) or the file ID (EFS): what the volume
        /// calls the file, and what the two dumps are matched by.
        public var key: Int
        /// The file table's name for it, from either dump; nil where neither
        /// names it.
        public var name: String?
        public var status: Status
        public var a: Side?
        public var b: Side?
        /// The same content kept at other addresses.
        public var moved: Bool
        /// For a file of one length on both sides whose bytes were read: how
        /// many of its content bytes differ. Nil otherwise.
        public var differingBytes: Int?
        /// Whether the Integrity tables differ, where both sides have one.
        public var integrityDiffers: Bool?
        /// Whether the file table says the engine encrypts the file; nil where
        /// no table names it. An encrypted file written again with a new nonce
        /// differs in nearly every byte whether or not what it says changed.
        public var encrypted: Bool?

        public init(volume: Volume, key: Int, name: String?, status: Status, a: Side?, b: Side?,
                    moved: Bool, differingBytes: Int?, integrityDiffers: Bool?, encrypted: Bool? = nil) {
            self.volume = volume
            self.key = key
            self.name = name
            self.status = status
            self.a = a
            self.b = b
            self.moved = moved
            self.differingBytes = differingBytes
            self.integrityDiffers = integrityDiffers
            self.encrypted = encrypted
        }
    }

    /// Why a volume's files could not be compared. A volume named here has no
    /// rows: listing the other side's files as "only in" would say they were
    /// missing when nothing was looked at.
    public struct Gap: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// The dump has no such volume.
            case absent
            /// The partition is there and holds no volume that could be read —
            /// for EFS, most often a System page that is erased.
            case unreadable
            /// The MFS volume header is missing or its signature is wrong.
            case badSignature
            /// The EFS volume was read but not cut into files: that needs the
            /// file table, which was not to be had or does not describe it.
            case filesNotNamed
        }

        public var volume: Volume
        /// Which dump: `true` for A.
        public var inA: Bool
        public var reason: Reason

        public init(volume: Volume, inA: Bool, reason: Reason) {
            self.volume = volume
            self.inA = inA
            self.reason = reason
        }
    }

    public var rows: [Row]
    public var gaps: [Gap]

    /// The rows in volume and key order, MFS first.
    public init(rows: [Row], gaps: [Gap]) {
        self.rows = rows
        self.gaps = gaps
    }

    /// Names for one dump's files; `.none` when nothing was looked up.
    public struct Names: Sendable {
        public var mfs: MFSFileNames
        public var efs: EFSFileNames

        public static let none = Names(mfs: .none, efs: .none)

        public init(mfs: MFSFileNames, efs: EFSFileNames) {
            self.mfs = mfs
            self.efs = efs
        }
    }

    /// Compares `a`'s files with `b`'s. `readA` and `readB` return a stretch
    /// of their dump at the addresses the analyses use, or nil when they
    /// cannot; with them a differing file says how many bytes differ, without
    /// them it says only that it differs.
    public static func compare(_ a: FirmwareAnalysis, _ b: FirmwareAnalysis,
                               names: (a: Names, b: Names) = (.none, .none),
                               readA: ((Range<Int>) -> Data?)? = nil,
                               readB: ((Range<Int>) -> Data?)? = nil) -> MEFileComparison {
        var rows: [Row] = []
        var gaps: [Gap] = []
        for volume in Volume.allCases {
            let left = files(volume, in: a)
            let right = files(volume, in: b)
            switch (left, right) {
            case (.missing(.absent), .missing(.absent)):
                continue
            case (.missing, _), (_, .missing):
                // Each side that has no files to give says why, so a volume
                // absent from one dump and unreadable in the other says both.
                if case .missing(let why) = left { gaps.append(Gap(volume: volume, inA: true, reason: why)) }
                if case .missing(let why) = right { gaps.append(Gap(volume: volume, inA: false, reason: why)) }
            case (.files(let left), .files(let right)):
                for key in Set(left.keys).union(right.keys).sorted() {
                    let name = volume.name(key, names.a) ?? volume.name(key, names.b)
                    var row = row(volume, key, name: name, left[key], right[key],
                                  readA: readA, readB: readB)
                    row.encrypted = volume.encrypted(key, names.a) ?? volume.encrypted(key, names.b)
                    rows.append(row)
                }
            }
        }
        return MEFileComparison(rows: rows, gaps: gaps)
    }

    // MARK: - One file

    private static func row(_ volume: Volume, _ key: Int, name: String?,
                            _ a: Side?, _ b: Side?,
                            readA: ((Range<Int>) -> Data?)?,
                            readB: ((Range<Int>) -> Data?)?) -> Row {
        var row = Row(volume: volume, key: key, name: name, status: .same, a: a, b: b,
                      moved: false, differingBytes: nil, integrityDiffers: nil)
        guard let a, let b else {
            row.status = a == nil ? .onlyInB : .onlyInA
            return row
        }
        if let left = a.integrity, let right = b.integrity {
            row.integrityDiffers = left != right
        }
        guard a.complete, b.complete else {
            row.status = .incomplete
            return row
        }
        let left = readA.flatMap { content(of: a, $0) }
        let right = readB.flatMap { content(of: b, $0) }
        if let left, let right {
            row.status = left == right ? .same : .different
            if left.count == right.count, left != right {
                row.differingBytes = zip(left, right).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
            }
        } else if let left = a.contentDigest, let right = b.contentDigest {
            row.status = a.contentSize == b.contentSize && left == right ? .same : .different
        } else {
            row.status = a.contentSize == b.contentSize ? .unknown : .different
        }
        row.moved = row.status == .same && !a.extents.isEmpty && !b.extents.isEmpty
            && a.extents != b.extents
        return row
    }

    /// The file's content read through its extents, nil where any stretch
    /// cannot be read, the extents do not add up to what the file stores, or
    /// what was read is not what the analysis found there — the bytes changed
    /// since, and the digest is then the better witness of what was analysed.
    static func content(of side: Side, _ read: (Range<Int>) -> Data?) -> Data? {
        guard !side.extents.isEmpty,
              side.extents.reduce(0, { $0 + $1.count }) == side.storedSize else { return nil }
        var bytes = Data(capacity: side.storedSize)
        for extent in side.extents {
            guard let piece = read(extent), piece.count == extent.count else { return nil }
            bytes.append(piece)
        }
        let content = bytes.prefix(side.contentSize)
        if let digest = side.contentDigest,
           SHA256.hash(data: content).map({ String(format: "%02X", $0) }).joined() != digest {
            return nil
        }
        return content
    }

    // MARK: - One dump's files

    private enum Files {
        case missing(Gap.Reason)
        case files([Int: Side])
    }

    private static func files(_ volume: Volume, in analysis: FirmwareAnalysis) -> Files {
        switch volume {
        case .mfs:
            guard let mfs = analysis.mfsVolume else {
                return .missing(analysis.regions.contains { $0.name == "MFS" } ? .unreadable : .absent)
            }
            guard mfs.signatureValid else { return .missing(.badSignature) }
            var sides: [Int: Side] = [:]
            for file in mfs.files {
                sides[file.index] = Side(storedSize: file.size,
                                         contentSize: file.contentSize ?? file.size,
                                         extents: file.extents ?? [],
                                         contentDigest: file.contentDigest,
                                         integrity: file.integrity,
                                         complete: file.chainIntact ?? true)
            }
            return .files(sides)
        case .efs:
            guard let efs = analysis.efsVolume else {
                return .missing(analysis.regions.contains { $0.name == "EFS" } ? .unreadable : .absent)
            }
            guard let files = efs.files else { return .missing(.filesNotNamed) }
            var sides: [Int: Side] = [:]
            for file in files {
                sides[file.fileID] = Side(storedSize: file.storedSize,
                                          contentSize: file.contentSize,
                                          extents: file.extents ?? [],
                                          contentDigest: file.contentDigest,
                                          integrity: file.integrity,
                                          complete: true)
            }
            return .files(sides)
        }
    }
}

extension MEFileComparison.Volume {
    func name(_ key: Int, _ names: MEFileComparison.Names) -> String? {
        switch self {
        case .mfs: return names.mfs.path(for: key)
        case .efs: return names.efs.name(for: key)
        }
    }

    func encrypted(_ key: Int, _ names: MEFileComparison.Names) -> Bool? {
        switch self {
        case .mfs: return names.mfs.record(for: key)?.encryption
        case .efs: return names.efs.record(for: key)?.encryption
        }
    }
}
