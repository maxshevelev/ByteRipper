import Foundation
import FirmwareCompression

/// Putting an edited part back into the image it came out of
/// (`Design/UEFI/UPDATE_IN_PARENT.md` §6, §8).
///
/// Pure: the file's bytes and the part's new bytes go in, and what comes out is
/// either one run of bytes to write over the file or the reason there is none.
/// Nothing is written here, and nothing is guessed — a change that would need a
/// rebase, a moved FIT target or more room than a volume has is refused, with
/// the numbers.
///
/// The work climbs from the changed node to the level that absorbs the change
/// in size: a section is laid out again inside its parent, a file inside its
/// volume, and a volume takes room from its own free space. A part inside a
/// compressed section is compressed again the way the section was, and the
/// section — now another size — is put back one space further out, the same
/// way, until the file itself is reached. The result is parsed again before it
/// is handed back (§8).
public enum UEFIRebuild {
    /// The part being put back: a node's bytes in a space, or — with no range —
    /// the whole of what a compressed section decompressed to.
    public struct Target: Hashable, Sendable {
        public var space: ByteSpace
        public var range: Range<UInt64>?

        public init(space: ByteSpace, range: Range<UInt64>? = nil) {
            self.space = space
            self.range = range
        }
    }

    /// One run of bytes to write over the file, and what the reader should
    /// know about it.
    public struct Plan: Equatable, Sendable {
        public var offset: UInt64
        public var bytes: [UInt8]
        public var warnings: [String]
        /// Where the part is held in the file once the plan is written: the
        /// node's new range, or the outermost compressed section's — which a
        /// link to the part follows from then on.
        public var source: Range<UInt64>
    }

    /// The part a zone of the file is, when a structure the planner can lay
    /// out again — a volume, a file or a section — covers exactly that range.
    public static func target(forFileRange range: Range<UInt64>, in image: UEFIImage) -> Target? {
        let kinds: Set<UEFINodeKind> = [.volume, .file, .section]
        guard image.allNodes.contains(where: { $0.fileRange == range && kinds.contains($0.kind) }) else {
            return nil
        }
        return Target(space: .file, range: range)
    }

    public struct Refusal: Error, Equatable, Sendable {
        public var message: String

        public init(_ message: String) {
            self.message = message
        }
    }

    /// A run of the file whose hash something checks
    /// (`BOOT_GUARD_PROTECTED_RANGES.md` §2) — what a change must not touch
    /// unknowingly (§6.4).
    public struct ProtectedRange: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// Part of the Boot Guard IBB: checked before the firmware runs.
            case ibb
            /// Covered by a hash the firmware itself checks: AMI, Phoenix,
            /// Insyde, a PMDA list.
            case vendorHash
        }

        public var kind: Kind
        public var range: Range<UInt64>
        public var name: String

        public init(kind: Kind, range: Range<UInt64>, name: String) {
            self.kind = kind
            self.range = range
            self.name = name
        }
    }

    /// Said with a plan the protected ranges were not given for (§6.4).
    public static let rangesNotChecked =
        "Boot Guard and vendor protected ranges were not checked: an edit inside one stops the platform starting."

    /// What writing `replacement` back at `target` takes, over the whole of
    /// `file`.
    ///
    /// - Parameter protected: the file's protected ranges, when they have been
    ///   read. A change to a byte inside the IBB is refused and one inside a
    ///   vendor hash range is warned about; nil says they were not checked.
    ///   - maximumCompressionFallback: a part inside compressed sections is
    ///     compressed again at the normal level; when the rebuild then does not
    ///     fit, it is done again at the maximum level before it is refused.
    ///     Off, the normal level is all there is — for a test that has to see
    ///     where the normal level stops.
    ///   - progress: called on the planning thread with what is being done and
    ///     how far the whole plan has got — for a status bar, since compressing
    ///     a DXE volume again takes seconds.
    public static func plan(
        _ replacement: [UInt8],
        at target: Target,
        in file: [UInt8],
        limits: UEFIParser.Limits = .init(),
        protected: [ProtectedRange]? = nil,
        maximumCompressionFallback: Bool = true,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) -> Result<Plan, Refusal> {
        let report = Reporter(progress)
        report.phase("Reading the structure of the image")
        // The ranges are the caller's to give (`protected`), not this parse's.
        let image = UEFIParser.parse(file, limits: limits, readsProtectedRanges: false) {
            report.fraction(Reporter.reading * $0)
        }
        var compressions = 0
        if case .decompressed(let chain) = target.space { compressions = chain.count }
        var context = Context(file: file, image: image, limits: limits,
                              report: report, compressions: compressions, effort: .normal)
        do {
            let rebuilt: [UInt8]
            do {
                rebuilt = try context.put(replacement, at: target)
            } catch let refusal as Refusal where compressions > 0 && maximumCompressionFallback {
                // Compressed at the normal level, the part did not go back —
                // most often because the stream is longer than the room it had.
                // Only then is it worth the time the maximum level takes: the
                // whole layout again, every section on the way compressed as
                // small as the encoder can make it.
                context = Context(file: file, image: image, limits: limits,
                                  report: report, compressions: compressions, effort: .maximum)
                do {
                    rebuilt = try context.put(replacement, at: target)
                } catch {
                    throw refusal
                }
                context.warnings.append(
                    "The compressed data did not fit at the normal compression level, so it was compressed again at the maximum level."
                )
            }
            guard rebuilt.count == file.count else {
                throw Refusal("The rebuilt image is not the size of the file. Nothing was changed.")
            }
            report.phase("Checking the rebuilt image")
            report.fraction(Reporter.checking)
            try verify(rebuilt, against: image, target: target, expected: context.targetBytes, limits: limits,
                       progress: { report.fraction(Reporter.checking + (1 - Reporter.checking) * $0) })
            defer { report.fraction(1) }
            let changes = changedRuns(rebuilt, file)
            var warnings = context.warnings
            if let protected {
                warnings += try protectionWarnings(changes, protected)
            } else {
                warnings.append(rangesNotChecked)
            }
            let source = context.fileSource ?? 0..<0
            guard let first = changes.first?.lowerBound, let last = changes.last?.upperBound else {
                return .success(Plan(offset: 0, bytes: [], warnings: warnings, source: source))
            }
            return .success(Plan(offset: first, bytes: Array(rebuilt[Int(first)..<Int(last)]),
                                 warnings: warnings, source: source))
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal("\(error)"))
        }
    }

    // MARK: - Protected ranges (§6.4)

    /// The runs of bytes the rebuild changes — what a hash over the file sees,
    /// as opposed to the span written, which also rewrites bytes as they were.
    static func changedRuns(_ rebuilt: [UInt8], _ file: [UInt8]) -> [Range<UInt64>] {
        var runs: [Range<UInt64>] = []
        var start: Int?
        for index in file.indices {
            if rebuilt[index] != file[index] {
                if start == nil { start = index }
            } else if let run = start {
                runs.append(UInt64(run)..<UInt64(index))
                start = nil
            }
        }
        if let run = start { runs.append(UInt64(run)..<UInt64(file.count)) }
        return runs
    }

    /// A change inside the IBB refuses; one inside a vendor hash range is
    /// something the reader has to know.
    static func protectionWarnings(_ runs: [Range<UInt64>], _ protected: [ProtectedRange]) throws -> [String] {
        var warnings: [String] = []
        for range in protected {
            guard let hit = runs.first(where: { $0.overlaps(range.range) }) else { continue }
            switch range.kind {
            case .ibb:
                throw Refusal(
                    "The change writes at 0x\(hex(max(hit.lowerBound, range.range.lowerBound))) inside “\(range.name)”, part of the Boot Guard IBB: the processor checks it before the firmware runs, and an edit there stops the platform starting (§6.4 of UPDATE_IN_PARENT.md). Nothing was changed."
                )
            case .vendorHash:
                // A list names several ranges one way — every entry of an
                // Insyde flash device map is its "range" — and a change
                // through two of them is still one thing to say.
                let warning = "The change writes inside “\(range.name)”: the hash the firmware checks it against no longer matches."
                if !warnings.contains(warning) { warnings.append(warning) }
            }
        }
        return warnings
    }

    // MARK: - Progress

    /// What a rebuild is doing, and how far the whole of it has got, from 0
    /// to 1.
    public struct Progress: Equatable, Sendable {
        public var phase: String
        public var fraction: Double
    }

    /// Hands progress on from whichever thread the work is on: the phase as it
    /// changes, the fraction only ever forward.
    final class Reporter: @unchecked Sendable {
        /// Where the phases end on the bar: reading the image, compressing
        /// again up to `checking`, then checking the result.
        static let reading = 0.2
        static let checking = 0.8

        private let sink: (@Sendable (Progress) -> Void)?
        private let lock = NSLock()
        private var current = Progress(phase: "", fraction: 0)

        init(_ sink: (@Sendable (Progress) -> Void)?) {
            self.sink = sink
        }

        func phase(_ phase: String) {
            update { $0.phase = phase }
        }

        func fraction(_ fraction: Double) {
            update { $0.fraction = max($0.fraction, min(fraction, 1)) }
        }

        private func update(_ change: (inout Progress) -> Void) {
            guard let sink else { return }
            lock.lock()
            change(&current)
            let snapshot = current
            lock.unlock()
            sink(snapshot)
        }
    }

    // MARK: - Verifying (§8)

    /// The kinds of complaint that mean a structure is broken, rather than
    /// merely unusual.
    private static let damage = [
        "checksumMismatch", "decompressionFailed", "decompressedTooLarge",
        "decompressedSizeMismatch", "sizeMismatch", "truncated", "zeroSize"
    ]

    private static func damageCounts(_ image: UEFIImage) -> [String: Int] {
        var counts: [String: Int] = [:]
        for diagnostic in image.diagnostics {
            let name = String("\(diagnostic.kind)".prefix { $0 != "(" })
            if damage.contains(name) { counts[name, default: 0] += 1 }
        }
        return counts
    }

    /// The rebuilt image parses with no more damage than the original had, and
    /// the part reads back from where it was put.
    private static func verify(
        _ rebuilt: [UInt8],
        against original: UEFIImage,
        target: Target,
        expected: [UInt8],
        limits: UEFIParser.Limits,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let before = damageCounts(original)
        let after = damageCounts(UEFIParser.parse(
            rebuilt, limits: limits, readsProtectedRanges: false, progress: progress
        ))
        for (kind, count) in after where count > before[kind, default: 0] {
            throw Refusal(
                "Putting it back would leave the image with a new \(kind) — a fault in the rebuild, not in the edit. Nothing was changed."
            )
        }
        let readers = SpaceReaders(file: ImageReader(rebuilt), limits: limits)
        let start = target.range?.lowerBound ?? 0
        guard let reader = readers.reader(for: target.space),
              reader.bytes(at: start, count: UInt64(expected.count)) == expected,
              target.range != nil || reader.count == UInt64(expected.count)
        else {
            throw Refusal("The part does not read back from the rebuilt image. Nothing was changed.")
        }
    }

    // MARK: - The work

    private final class Context {
        let file: [UInt8]
        let image: UEFIImage
        let limits: UEFIParser.Limits
        let readers: SpaceReaders
        var warnings: [String] = []
        /// The target's bytes as they will read back — the replacement with
        /// its own sizes and checksums put right.
        var targetBytes: [UInt8] = []
        /// The first range of the file this rebuild puts new bytes at — the
        /// target itself, or the outermost compressed section holding it — as it
        /// stands afterwards.
        var fileSource: Range<UInt64>?
        private var isTarget = true

        /// Progress, and how many compressed sections the rebuild will compress
        /// again: the bar between reading and checking is theirs to share.
        let report: Reporter
        let compressions: Int
        private var compressed = 0
        /// How hard every section on the way is compressed.
        let effort: FirmwareCompression.Effort

        init(file: [UInt8], image: UEFIImage, limits: UEFIParser.Limits, report: Reporter, compressions: Int,
             effort: FirmwareCompression.Effort) {
            self.file = file
            self.image = image
            self.limits = limits
            self.report = report
            self.compressions = compressions
            self.effort = effort
            readers = SpaceReaders(file: ImageReader(file), limits: limits)
        }

        /// The new file, with `replacement` at `target` and everything around
        /// it put right.
        func put(_ replacement: [UInt8], at target: Target) throws -> [UInt8] {
            let space = target.space
            // Normalizing a node keeps its length, so this is its range after.
            if space == .file, fileSource == nil, let range = target.range {
                fileSource = range.lowerBound..<(range.lowerBound + UInt64(replacement.count))
            }
            let original = try bytes(of: space)
            let newSpace: [UInt8]
            // The file is never replaced whole: even a volume that fills it is a
            // structure with a size of its own to keep.
            if let range = target.range, space == .file || range != 0..<UInt64(original.count) {
                newSpace = try replaceNode(range, with: replacement, in: space, bytes: original)
            } else {
                newSpace = replacement
                if isTarget { targetBytes = replacement }
            }
            isTarget = false
            guard let section = compressedSection(holding: space) else { return newSpace }
            let parentBytes = try bytes(of: section.space)
            let rebuilt = try recompressed(section, holding: newSpace, parentBytes: parentBytes)
            return try put(rebuilt, at: Target(space: section.space, range: section.range))
        }

        // MARK: Spaces

        func bytes(of space: ByteSpace) throws -> [UInt8] {
            if space == .file { return file }
            guard let reader = readers.reader(for: space), let bytes = reader.bytes(reader.all) else {
                throw Refusal("A compressed section on the way to the part no longer decompresses.")
            }
            return bytes
        }

        /// The compressed section whose buffer `space` is; nil for the file.
        func compressedSection(holding space: ByteSpace) -> UEFINode? {
            guard case .decompressed(let chain) = space, let last = chain.last else { return nil }
            let parent: ByteSpace = chain.count == 1 ? .file : .decompressed(chain: Array(chain.dropLast()))
            return image.allNodes.first {
                $0.space == parent && $0.kind == .section && $0.header.lowerBound == last
            }
        }

        func topNodes(in space: ByteSpace) throws -> [UEFINode] {
            guard space != .file else { return image.roots }
            guard let section = compressedSection(holding: space) else {
                throw Refusal("The compressed section the part came out of is not in the image any more.")
            }
            return section.children.filter { $0.space == space }
        }

        /// The nodes from the top of `space` down to the innermost one covering
        /// exactly `range`.
        func path(to range: Range<UInt64>, in space: ByteSpace) throws -> [UEFINode] {
            var path: [UEFINode] = []
            var nodes = try topNodes(in: space)
            while let node = nodes.first(where: {
                $0.space == space && $0.range.lowerBound <= range.lowerBound
                    && range.upperBound <= $0.range.upperBound && !$0.range.isEmpty
            }) {
                path.append(node)
                nodes = node.children
            }
            guard let exact = path.lastIndex(where: { $0.range == range }) else {
                throw Refusal("The part is not a whole structure of the image, so it cannot be laid out again.")
            }
            return Array(path[...exact])
        }

        // MARK: Climbing

        func replaceNode(
            _ range: Range<UInt64>, with replacement: [UInt8], in space: ByteSpace, bytes: [UInt8]
        ) throws -> [UInt8] {
            let path = try path(to: range, in: space)
            let node = path[path.count - 1]
            var current = try normalized(node, replacement, path: path, bytes: bytes)
            if isTarget { targetBytes = current }
            var child = node
            for parent in path.dropLast().reversed() {
                current = try rebuild(parent, replacing: child, with: current,
                                      path: path, bytes: bytes, space: space)
                child = parent
            }
            if UInt64(current.count) == child.range.count {
                var result = bytes
                result.replaceSubrange(Int(child.range.lowerBound)..<Int(child.range.upperBound), with: current)
                return result
            }
            guard space != .file else {
                return try settled(child, with: current, among: image.roots, end: UInt64(bytes.count),
                                   endName: "the end of the file", bytes: bytes)
            }
            // A buffer is a run of sections from its first byte.
            return run(try topNodes(in: space), replacing: child, with: current, bytes: bytes)
        }

        /// `replacement` for `node`, with the node's own size, checksums and
        /// tail made to fit what it now is.
        func normalized(_ node: UEFINode, _ replacement: [UInt8], path: [UEFINode], bytes: [UInt8]) throws -> [UInt8] {
            switch node.kind {
            case .file:
                return try Bytes.file(replacement, name: node.name,
                                      volumeRevision: volumeRevision(path),
                                      ffsVersion: ffsVersion(path, space: node.space))
            case .section:
                return try Bytes.sized(replacement, name: node.name)
            case .volume:
                return Bytes.volumeHeaderChecksummed(try volumeSized(replacement, name: node.name))
            default:
                return replacement
            }
        }

        func rebuild(
            _ parent: UEFINode, replacing child: UEFINode, with new: [UInt8],
            path: [UEFINode], bytes: [UInt8], space: ByteSpace
        ) throws -> [UInt8] {
            switch parent.kind {
            case .section:
                let header = Array(bytes[Int(parent.header.lowerBound)..<Int(parent.header.upperBound)])
                let body: [UInt8]
                if parent.subtype == Section.firmwareVolumeImage {
                    body = Array(bytes[Int(parent.body.lowerBound)..<Int(child.range.lowerBound)]) + new
                        + Array(bytes[Int(child.range.upperBound)..<Int(parent.body.upperBound)])
                } else {
                    body = run(parent.children, replacing: child, with: new, bytes: bytes)
                }
                noteSigned(parent)
                return try Bytes.withCRC32(Bytes.sized(header + body, name: parent.name), of: parent,
                                          headerLength: header.count)
            case .file:
                let header = Array(bytes[Int(parent.header.lowerBound)..<Int(parent.header.upperBound)])
                let tail = Array(bytes[Int(parent.tail.lowerBound)..<Int(parent.tail.upperBound)])
                let body = run(parent.children, replacing: child, with: new, bytes: bytes)
                let upper = Array(path.prefix { $0.id != parent.id }) + [parent]
                return try Bytes.file(header + body + tail, name: parent.name,
                                      volumeRevision: volumeRevision(upper),
                                      ffsVersion: ffsVersion(upper, space: space))
            case .volume:
                // A volume a section holds grows by blocks and the section takes
                // the new size (§6.5); one in the file grows into the empty space
                // after it, unless it holds the Volume Top File, whose end is
                // pinned (§7). One at the top of a buffer does not grow.
                let at = path.firstIndex { $0.id == parent.id } ?? 0
                let growth: VolumeGrowth
                if at > 0 && path[at - 1].kind == .section {
                    growth = .inSection
                } else if space == .file, !parent.flattened.contains(where: isVolumeTop) {
                    growth = .intoEmptySpace
                } else {
                    growth = .none
                }
                return try rebuildVolume(parent, replacing: child, with: new, bytes: bytes, space: space,
                                         growth: growth)
            default:
                guard UInt64(new.count) == child.range.count else {
                    let result = try settled(child, with: new, among: parent.children, end: parent.range.upperBound,
                                             endName: "the end of “\(parent.name)”", bytes: bytes)
                    return Array(result[Int(parent.range.lowerBound)..<Int(parent.range.upperBound)])
                }
                var result = Array(bytes[Int(parent.range.lowerBound)..<Int(parent.range.upperBound)])
                let at = Int(child.range.lowerBound - parent.range.lowerBound)
                result.replaceSubrange(at..<(at + new.count), with: new)
                return result
            }
        }

        // MARK: A structure at its own length (§7)

        /// `bytes` with `new` in place of `child`, at exactly its own length: the
        /// difference is taken from, or given back to, the empty bytes right
        /// after it, so whatever follows them — the next volume, the next
        /// region's contents — stays at its offset.
        func settled(
            _ child: UEFINode, with new: [UInt8], among siblings: [UEFINode],
            end: UInt64, endName: String, bytes: [UInt8]
        ) throws -> [UInt8] {
            let old = child.range
            let oldLength = old.upperBound - old.lowerBound
            let newLength = UInt64(new.count)
            if child.flattened.contains(where: isVolumeTop) {
                throw Refusal(
                    "“\(child.name)” holds the Volume Top File, which has to end at the top of the address space, so it keeps its size of 0x\(hex(oldLength)) bytes and this one is 0x\(hex(newLength)) (§7 of UPDATE_IN_PARENT.md)."
                )
            }
            let next = siblings.first {
                $0.space == child.space && $0.kind != .padding && !$0.range.isEmpty
                    && $0.range.lowerBound >= old.upperBound
            }
            let limit = min(next?.range.lowerBound ?? end, end)
            let empty = emptyByte(after: child, limit: limit, bytes: bytes)
            var result = bytes
            if newLength > oldLength {
                let needed = newLength - oldLength
                var room: UInt64 = 0
                while old.upperBound + room < limit, bytes[Int(old.upperBound + room)] == empty { room += 1 }
                guard room >= needed else {
                    let before = next.map { "“\($0.name)”" } ?? endName
                    throw Refusal(
                        "“\(child.name)” is 0x\(hex(needed)) bytes longer than before, and only 0x\(hex(room)) empty bytes follow it before \(before), which stays where it is (§7 of UPDATE_IN_PARENT.md)."
                    )
                }
                result.replaceSubrange(Int(old.lowerBound)..<Int(old.upperBound + needed), with: new)
            } else {
                let freed = [UInt8](repeating: empty, count: Int(oldLength - newLength))
                result.replaceSubrange(Int(old.lowerBound)..<Int(old.upperBound), with: new + freed)
            }
            let change = newLength > oldLength
                ? "0x\(hex(newLength - oldLength)) bytes longer, taken from the empty space after it"
                : "0x\(hex(oldLength - newLength)) bytes shorter, given back to the empty space after it"
            var warning = "“\(child.name)” is now 0x\(hex(newLength)) bytes, \(change); what follows stays where it was."
            if child.kind == .volume {
                warning += " The flash map the firmware carries (PCDs, vendor tables, an Insyde FDM) still gives its old size."
            }
            warnings.append(warning)
            return result
        }

        /// What fills the bytes after `child`: the byte already there when it
        /// is an erased one, otherwise the volume's own erase polarity.
        func emptyByte(after child: UEFINode, limit: UInt64, bytes: [UInt8]) -> UInt8 {
            if child.range.upperBound < limit {
                let there = bytes[Int(child.range.upperBound)]
                if there == 0xFF || there == 0x00 { return there }
            }
            if child.kind == .volume {
                return (Bytes.u32(bytes, Int(child.range.lowerBound) + 0x2C) & FV.erasePolarity) != 0 ? 0xFF : 0x00
            }
            return 0xFF
        }

        /// A volume put back whole with a length its header does not give:
        /// `FvLength` and the block map's one entry rewritten to it, when it is
        /// a whole number of that entry's blocks.
        func volumeSized(_ volume: [UInt8], name: String) throws -> [UInt8] {
            guard volume.count >= Int(FV.headerSize) else {
                throw Refusal("“\(name)” is shorter than a volume header.")
            }
            let length = UInt64(volume.count)
            var declared: UInt64 = 0
            for index in 0..<8 { declared |= UInt64(volume[0x20 + index]) << (8 * UInt64(index)) }
            guard declared != length else { return volume }
            guard let blockLength = Bytes.oneBlockLength(volume, at: 0, end: volume.count),
                  length % blockLength == 0, length / blockLength <= UInt64(UInt32.max)
            else {
                throw Refusal(
                    "“\(name)” is 0x\(hex(length)) bytes, and its header says 0x\(hex(declared)): a volume is whole blocks of its block map, and this one cannot be made to say the new length."
                )
            }
            var bytes = volume
            Bytes.put(length, count: 8, at: 0x20, in: &bytes)
            Bytes.put32(UInt32(length / blockLength), at: Int(FV.headerSize), in: &bytes)
            warnings.append("“\(name)” said it was 0x\(hex(declared)) bytes: its header now gives 0x\(hex(length)).")
            return bytes
        }

        /// A run of sections laid out again from its first byte, four-byte
        /// aligned, with `child` replaced by `new`.
        func run(_ children: [UEFINode], replacing child: UEFINode, with new: [UInt8], bytes: [UInt8]) -> [UInt8] {
            let padByte = children.first { $0.kind == .padding }
                .map { bytes[Int($0.range.lowerBound)] } ?? 0x00
            var out: [UInt8] = []
            for node in children where node.kind != .padding && node.space == child.space {
                out += [UInt8](repeating: padByte, count: Bytes.padding(out.count, to: 4))
                out += node.id == child.id
                    ? new
                    : Array(bytes[Int(node.range.lowerBound)..<Int(node.range.upperBound)])
            }
            return out
        }

        // MARK: Volumes (§6.3)

        /// Whether a volume that runs out of free space may grow, and into what.
        enum VolumeGrowth {
            case none
            /// Held by a section, which takes the new size (§6.5).
            case inSection
            /// In the file: into the empty bytes after it, which `settled` checks (§7).
            case intoEmptySpace
        }

        func rebuildVolume(
            _ volume: UEFINode, replacing child: UEFINode, with new: [UInt8],
            bytes: [UInt8], space: ByteSpace, growth: VolumeGrowth
        ) throws -> [UInt8] {
            let start = volume.range.lowerBound
            let body = volume.body
            let empty: UInt8 = (Bytes.u32(bytes, Int(start) + 0x2C) & FV.erasePolarity) != 0 ? 0xFF : 0x00
            let revision = volume.subtype ?? 2
            let ffs = volume.guid.flatMap(KnownGUIDs.ffsVersion(ofFileSystem:)) ?? 2
            let children = volume.children.filter { $0.space == space }
            guard let index = children.firstIndex(where: { $0.id == child.id }) else {
                throw Refusal("“\(child.name)” is not laid out in “\(volume.name)”.")
            }

            let old = child.range
            let newEnd = old.lowerBound + UInt64(new.count)
            let alignedEnd = body.lowerBound + UInt64(Bytes.aligned(Int(newEnd - body.lowerBound), to: 8))
            let after = children[(index + 1)...].filter { $0.kind != .padding }

            // What moves, and where the room comes from.
            var moving: [UEFINode] = []
            var absorbStart = body.upperBound
            var absorbEnd = body.upperBound
            var padBeforeTop: UEFINode?
            for (offset, node) in after.enumerated() {
                if node.kind == .file, !isVolumeTop(node) {
                    let rest = Array(after.dropFirst(offset))
                    if rest.count == 2, isEmptyPad(rest[0], bytes: bytes, empty: empty), isVolumeTop(rest[1]) {
                        padBeforeTop = rest[0]
                        absorbStart = rest[0].range.lowerBound
                        absorbEnd = rest[1].range.lowerBound
                        break
                    }
                    moving.append(node)
                    continue
                }
                if node.kind == .freeSpace {
                    absorbStart = node.range.lowerBound
                    absorbEnd = node.range.upperBound
                } else {
                    absorbStart = node.range.lowerBound
                    absorbEnd = node.range.lowerBound
                }
                break
            }
            if moving.isEmpty, padBeforeTop == nil, after.isEmpty {
                absorbStart = max(Bytes.alignedUp(old.upperBound, base: body.lowerBound, to: 8), absorbStart)
                absorbStart = min(absorbStart, body.upperBound)
            }
            if moving.last.map({ _ in true }) == true, absorbStart == body.upperBound, absorbEnd == body.upperBound,
               let last = moving.last {
                absorbStart = min(body.upperBound, Bytes.alignedUp(last.range.upperBound, base: body.lowerBound, to: 8))
                absorbEnd = absorbStart
            }

            if space == .file {
                for node in moving {
                    if node.flattened.contains(where: \.isFixed) {
                        throw Refusal(
                            "“\(node.name)” would move, and it is fixed at its address — the Volume Top File, a FIT target or a file marked fixed (§6.4 of UPDATE_IN_PARENT.md)."
                        )
                    }
                    if let type = node.subtype, [0x03, 0x04, 0x06, 0x08].contains(type) {
                        throw Refusal(
                            "“\(node.name)” would move, and it is code that runs in place from flash: moving it needs a rebase this editor does not do (§6.4 of UPDATE_IN_PARENT.md)."
                        )
                    }
                }
            }

            let alignment = moving.map { fileAlignment($0, bytes: bytes, ffsVersion: ffs) }.max().map { max($0, 8) } ?? 8
            let oldNext = moving.first?.range.lowerBound ?? absorbStart
            var newNext: Int64
            if moving.isEmpty {
                newNext = Int64(alignedEnd)
            } else {
                let distance = Int64(alignedEnd) - Int64(oldNext)
                let steps = distance >= 0
                    ? (distance + Int64(alignment) - 1) / Int64(alignment)
                    : -((-distance) / Int64(alignment))
                newNext = Int64(oldNext) + steps * Int64(alignment)
                while newNext - Int64(alignedEnd) > 0, newNext - Int64(alignedEnd) < Int64(FFS.headerSize) {
                    newNext += Int64(alignment)
                }
            }
            let shift = newNext - Int64(oldNext)
            let newAbsorbStart = Int64(absorbStart) + shift

            if newAbsorbStart > Int64(absorbEnd) {
                // Growing into the empty space needs some to be there at all;
                // with none the refusal below says what the volume has.
                let canGrow = growth == .inSection
                    || (growth == .intoEmptySpace && Int(volume.range.upperBound) < bytes.count
                        && [0x00, 0xFF].contains(bytes[Int(volume.range.upperBound)]))
                if canGrow, padBeforeTop == nil, absorbEnd == body.upperBound {
                    return try grownVolume(volume, replacing: child, with: new, bytes: bytes, space: space,
                                           needed: UInt64(newAbsorbStart - Int64(absorbEnd)),
                                           saysSo: growth == .inSection)
                }
                throw Refusal(
                    "“\(volume.name)” has 0x\(hex(absorbEnd - absorbStart)) bytes free where it can take room, and the change needs 0x\(hex(UInt64(newAbsorbStart - Int64(absorbStart)))) (§6.3 of UPDATE_IN_PARENT.md)."
                )
            }
            if let pad = padBeforeTop {
                let size = Int64(absorbEnd) - newAbsorbStart
                guard size == 0 || size >= Int64(FFS.headerSize) else {
                    throw Refusal("There is no room left for the pad file in front of the Volume Top File in “\(volume.name)”.")
                }
                _ = pad
            }

            var out = Array(bytes[Int(start)..<Int(old.lowerBound)])
            out += new
            out += [UInt8](repeating: empty, count: Int(alignedEnd - newEnd))
            if !moving.isEmpty {
                let gap = Int(newNext - Int64(alignedEnd))
                if gap > 0 {
                    out += Bytes.padFile(size: gap, guid: Bytes.zeroGUID, revision: revision, empty: empty)
                }
                out += Array(bytes[Int(oldNext)..<Int(absorbStart)])
            }
            if let pad = padBeforeTop {
                let size = Int(Int64(absorbEnd) - newAbsorbStart)
                if size > 0 {
                    let guid = Array(bytes[Int(pad.range.lowerBound)..<Int(pad.range.lowerBound + 16)])
                    out += Bytes.padFile(size: size, guid: guid, revision: revision, empty: empty)
                }
            } else {
                out += [UInt8](repeating: empty, count: Int(Int64(absorbEnd) - newAbsorbStart))
            }
            out += Array(bytes[Int(absorbEnd)..<Int(volume.range.upperBound)])
            guard UInt64(out.count) == volume.range.count else {
                throw Refusal("“\(volume.name)” did not come out its own size — a fault in the rebuild. Nothing was changed.")
            }
            return out
        }

        /// A volume a section holds, grown by whole blocks until the change fits
        /// (§6.5): `FvLength`, the block map's one entry and the header checksum
        /// rewritten, the new blocks erased, and the layout done again in the
        /// longer volume — whose free space now runs to its new end.
        func grownVolume(
            _ volume: UEFINode, replacing child: UEFINode, with new: [UInt8],
            bytes: [UInt8], space: ByteSpace, needed: UInt64, saysSo: Bool
        ) throws -> [UInt8] {
            let start = Int(volume.range.lowerBound)
            let end = Int(volume.range.upperBound)
            guard let blockLength = Bytes.oneBlockLength(bytes, at: start, end: end) else {
                throw Refusal(
                    "“\(volume.name)” has no room for 0x\(hex(needed)) more bytes, and its block map is not one a new size can be written into (§6.5 of UPDATE_IN_PARENT.md)."
                )
            }
            let length = UInt64(volume.range.count)
            guard length % blockLength == 0 else {
                throw Refusal(
                    "“\(volume.name)” has no room for 0x\(hex(needed)) more bytes, and its size is not a whole number of its blocks (§6.5 of UPDATE_IN_PARENT.md)."
                )
            }
            let extra = (needed + blockLength - 1) / blockLength * blockLength
            let newLength = length + extra
            guard newLength / blockLength <= UInt64(UInt32.max) else {
                throw Refusal("“\(volume.name)” would need more blocks than its block map can count.")
            }
            let empty: UInt8 = (Bytes.u32(bytes, start + 0x2C) & FV.erasePolarity) != 0 ? 0xFF : 0x00

            var longer = Array(bytes[start..<end]) + [UInt8](repeating: empty, count: Int(extra))
            Bytes.put(newLength, count: 8, at: 0x20, in: &longer)
            Bytes.put32(UInt32(newLength / blockLength), at: Int(FV.headerSize), in: &longer)
            longer = Bytes.volumeHeaderChecksummed(longer)
            let grownBytes = Array(bytes[..<start]) + longer + Array(bytes[end...])

            var bigger = volume
            bigger.body = volume.body.lowerBound..<(volume.body.upperBound + extra)
            if let last = bigger.children.lastIndex(where: { $0.space == space }),
               bigger.children[last].kind == .freeSpace {
                let free = bigger.children[last].body
                bigger.children[last].body = free.lowerBound..<bigger.body.upperBound
            } else {
                var tail = UEFINode(kind: .freeSpace, name: "Free space",
                                    range: volume.body.upperBound..<bigger.body.upperBound, isErased: true)
                tail.space = space
                tail.id = NodeID([-1])
                bigger.children.append(tail)
            }
            // A volume growing into the empty space after it is said by
            // `settled`, with what that means for the flash map.
            if saysSo { warnings.append("“\(volume.name)” grew by 0x\(hex(extra)) bytes to make room.") }
            return try rebuildVolume(bigger, replacing: child, with: new, bytes: grownBytes, space: space,
                                     growth: .none)
        }

        func isVolumeTop(_ node: UEFINode) -> Bool {
            node.kind == .file && node.guid == KnownGUIDs.volumeTopFile
        }

        func isEmptyPad(_ node: UEFINode, bytes: [UInt8], empty: UInt8) -> Bool {
            node.kind == .file && node.subtype == FFS.padType
                && bytes[Int(node.body.lowerBound)..<Int(node.body.upperBound)].allSatisfy { $0 == empty }
        }

        /// The alignment a file's data needs, from its attributes.
        func fileAlignment(_ file: UEFINode, bytes: [UInt8], ffsVersion: Int) -> UInt64 {
            let attributes = bytes[Int(file.header.lowerBound) + 0x13]
            let slot = Int((attributes & 0x38) >> 3)
            let powers: [UInt64] = ffsVersion == 3 && attributes & 0x02 != 0
                ? [17, 18, 19, 20, 21, 22, 23, 24]
                : [0, 4, 7, 9, 10, 12, 15, 16]
            return 1 << powers[slot]
        }

        // MARK: Compressed sections (§5)

        func recompressed(_ section: UEFINode, holding buffer: [UInt8], parentBytes: [UInt8]) throws -> [UInt8] {
            let reader = ImageReader(parentBytes)
            guard let located = CompressedSection.locate(at: section.header.lowerBound, in: reader),
                  case .success(let decoded) = CompressedSection.decode(located, in: reader,
                                                                        limit: limits.maxDecompressedSize)
            else {
                throw Refusal("“\(section.name)” no longer decompresses, so it cannot be compressed again the same way.")
            }
            // The stretch of the bar between reading and checking that this
            // section's encode, one of `compressions`, has to itself.
            let share = (Reporter.checking - Reporter.reading) / Double(max(compressions, 1))
            let low = Reporter.reading + share * Double(compressed)
            compressed += 1
            let size = ByteCountFormatter.string(fromByteCount: Int64(buffer.count), countStyle: .file)
            report.phase(effort == .maximum
                ? "Compressing “\(section.name)” again at the maximum level (\(size))"
                : "Compressing “\(section.name)” (\(size))")
            let report = self.report
            let stream: [UInt8]
            do {
                stream = try FirmwareCompression.compress(
                    buffer, like: decoded,
                    from: Array(parentBytes[Int(located.body.lowerBound)..<Int(located.body.upperBound)]),
                    effort: effort,
                    progress: { report.fraction(low + share * $0) }
                )
            } catch {
                throw Refusal("“\(section.name)” could not be compressed again: \(error).")
            }
            var header = Array(parentBytes[Int(section.header.lowerBound)..<Int(located.body.lowerBound)])
            if section.subtype == Section.compression {
                let common = Bytes.u24(header, 0) == Section.extendedSizeMarker ? 8 : 4
                Bytes.put32(UInt32(buffer.count), at: common, in: &header)
            }
            noteSigned(section)
            return try Bytes.sized(header + stream, name: section.name)
        }

        /// A signed or authenticated section on the way out no longer checks.
        func noteSigned(_ section: UEFINode) {
            guard section.subtype == Section.guidDefined, let guid = section.guid else { return }
            if guid == Bytes.signedGUID {
                warnings.append("“\(section.name)” is signed, and its signature no longer matches what it holds.")
            }
        }

        // MARK: What a node is read by

        func volumeRevision(_ path: [UEFINode]) -> UInt8 {
            path.last(where: { $0.kind == .volume })?.subtype ?? 2
        }

        func ffsVersion(_ path: [UEFINode], space: ByteSpace) -> Int {
            if let volume = path.last(where: { $0.kind == .volume }) {
                return volume.guid.flatMap(KnownGUIDs.ffsVersion(ofFileSystem:)) ?? 2
            }
            return space == .file ? 2 : 3
        }
    }

    // MARK: - Bytes

    /// The fields this rebuild writes, in the layouts `UEFI_IMAGE_FORMAT.md`
    /// gives them.
    enum Bytes {
        static let zeroGUID = [UInt8](repeating: 0, count: 16)
        static let crc32GUID = KnownGUIDs.guid("FC1BCDB0-7D31-49AA-936A-A4600D9DD083")
        static let signedGUID = KnownGUIDs.guid("0F9D89E8-9259-4F76-A5AF-0C89E34023DF")

        static func u24(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
        }

        static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            u24(bytes, at) | UInt32(bytes[at + 3]) << 24
        }

        static func put(_ value: UInt64, count: Int, at: Int, in bytes: inout [UInt8]) {
            for index in 0..<count { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }

        static func put32(_ value: UInt32, at: Int, in bytes: inout [UInt8]) {
            put(UInt64(value), count: 4, at: at, in: &bytes)
        }

        static func padding(_ count: Int, to alignment: Int) -> Int {
            (alignment - count % alignment) % alignment
        }

        static func aligned(_ count: Int, to alignment: Int) -> Int {
            count + padding(count, to: alignment)
        }

        static func alignedUp(_ offset: UInt64, base: UInt64, to alignment: Int) -> UInt64 {
            base + UInt64(aligned(Int(offset - base), to: alignment))
        }

        /// A section's size field made to say how long it now is — in three
        /// bytes, or in the extended field when the header has one.
        static func sized(_ section: [UInt8], name: String) throws -> [UInt8] {
            var bytes = section
            if u24(bytes, 0) == Section.extendedSizeMarker, bytes.count >= 8 {
                guard bytes.count <= Int(UInt32.max) else {
                    throw Refusal("“\(name)” would be larger than a section can say.")
                }
                put32(UInt32(bytes.count), at: 4, in: &bytes)
            } else {
                guard bytes.count < Int(Section.extendedSizeMarker) else {
                    throw Refusal("“\(name)” would grow past 16 MiB, which its short header cannot say.")
                }
                put(UInt64(bytes.count), count: 3, at: 0, in: &bytes)
            }
            return bytes
        }

        /// A file's size, checksums and tail made to fit its bytes (§5.2, §5.4).
        static func file(_ file: [UInt8], name: String, volumeRevision: UInt8, ffsVersion: Int) throws -> [UInt8] {
            var bytes = file
            guard bytes.count >= Int(FFS.headerSize) else {
                throw Refusal("“\(name)” is shorter than a file header.")
            }
            let attributes = bytes[0x13]
            let isLarge = attributes & FFS.largeFile != 0
            let headerSize: Int
            if ffsVersion == 3 && isLarge {
                headerSize = Int(FFS.largeHeaderSize)
                put(UInt64(bytes.count), count: 8, at: 0x18, in: &bytes)
            } else if ffsVersion == 2 && volumeRevision == 2 && isLarge {
                headerSize = Int(FFS.lenovoHeaderSize)
                put(UInt64(bytes.count), count: 4, at: 0x18, in: &bytes)
            } else {
                headerSize = Int(FFS.headerSize)
                guard bytes.count <= 0xFF_FFFF else {
                    throw Refusal("“\(name)” would grow past 16 MiB in a file with no large-file header (§6.4 of UPDATE_IN_PARENT.md).")
                }
                put(UInt64(bytes.count), count: 3, at: 0x14, in: &bytes)
            }
            let tail = volumeRevision == 1 && attributes & FFS.tailPresent != 0 && bytes.count > headerSize ? 2 : 0
            let body = bytes[headerSize..<(bytes.count - tail)]
            bytes[0x11] = attributes & FFS.checksumBit != 0
                ? 0 &- Checksums.sum8(body)
                : (volumeRevision == 1 ? FFS.fixedChecksum : FFS.fixedChecksum2)
            let sum = Checksums.sum8(bytes[0..<headerSize]) &- bytes[0x10] &- bytes[0x11] &- bytes[0x17]
            bytes[0x10] = 0 &- sum
            if tail == 2 {
                bytes[bytes.count - 2] = ~bytes[0x10]
                bytes[bytes.count - 1] = ~bytes[0x11]
            }
            return bytes
        }

        /// An empty pad file of `size` bytes (§5.6).
        static func padFile(size: Int, guid: [UInt8], revision: UInt8, empty: UInt8) -> [UInt8] {
            var bytes = guid + [0, 0, FFS.padType, 0, 0, 0, 0, empty == 0xFF ? 0xF8 : 0x07]
            bytes += [UInt8](repeating: empty, count: size - Int(FFS.headerSize))
            return (try? file(bytes, name: "Pad", volumeRevision: revision, ffsVersion: 2)) ?? bytes
        }

        /// The block length of a volume at `start` whose block map is one
        /// entry and its terminator — the only kind a new length can be written
        /// into (§6.5). Nil for any other.
        static func oneBlockLength(_ bytes: [UInt8], at start: Int, end: Int) -> UInt64? {
            guard end - start >= Int(FV.headerSize + 2 * FV.blockMapEntrySize) else { return nil }
            let headerLength = Int(bytes[start + 0x30]) | Int(bytes[start + 0x31]) << 8
            let map = start + Int(FV.headerSize)
            guard headerLength == Int(FV.headerSize + 2 * FV.blockMapEntrySize),
                  u32(bytes, map + 8) == 0, u32(bytes, map + 12) == 0
            else { return nil }
            let blockLength = UInt64(u32(bytes, map + 4))
            return blockLength > 0 ? blockLength : nil
        }

        static func volumeHeaderChecksummed(_ volume: [UInt8]) -> [UInt8] {
            var bytes = volume
            let length = Int(bytes[0x30]) | Int(bytes[0x31]) << 8
            guard length <= bytes.count else { return bytes }
            bytes[FV.checksumOffset] = 0
            bytes[FV.checksumOffset + 1] = 0
            guard let checksum = Checksums.checksum16(Array(bytes[0..<length])) else { return bytes }
            put(UInt64(checksum), count: 2, at: FV.checksumOffset, in: &bytes)
            return bytes
        }

        /// A CRC32 GUID-defined section whose authentication status is valid
        /// carries the CRC of its data, which changed with it.
        static func withCRC32(_ section: [UInt8], of node: UEFINode, headerLength: Int) -> [UInt8] {
            guard node.subtype == Section.guidDefined, node.guid == crc32GUID else { return section }
            var bytes = section
            let common = u24(bytes, 0) == Section.extendedSizeMarker ? 8 : 4
            let attributes = UInt16(bytes[common + 18]) | UInt16(bytes[common + 19]) << 8
            guard attributes & 0x02 != 0, headerLength >= common + 24 else { return section }
            put32(crc32(bytes[headerLength...]), at: common + 20, in: &bytes)
            return bytes
        }

        static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }
    }

    static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}

private func hex(_ value: UInt64) -> String {
    UEFIRebuild.hex(value)
}
