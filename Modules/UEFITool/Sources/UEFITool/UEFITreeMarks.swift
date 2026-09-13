import Foundation
import ToolModuleKit
import UEFIImage

/// What a row of the UEFI tree wears besides its name (`Design/ROW_MARKS.md`
/// §5.1), decided here so it is tested without a window.
///
/// The rail for every node inside a compressed section and for the section
/// itself while its row is open, the compressed badge on a compressed section,
/// and the problem icon for a wrong checksum or a section that did not
/// decompress. Once the tree's protected ranges have been read, the Boot Guard
/// background, the partly-protected badge, the badge on what holds a list of
/// ranges, and a protected range whose hash does not match
/// (`UEFI/BOOT_GUARD_PROTECTED_RANGES.md` §9.3).
public enum UEFITreeMarks {
    /// Every mark this tree draws — what its legend lists.
    public static let legendMarks: [ToolRowMark] = [
        .protectedIBB, .protectedFirmware, .decompressed, .error, .caution,
        .compressed, .compressedUndecoded, .holdsChecks, .partlyProtected
    ]

    /// - Parameters:
    ///   - badChecksums: the node's checksum fields the last pass found wrong.
    ///   - isOpen: the node's row is open in the outline — state of the view,
    ///     not of the tree, which keeps a branch it has read after the row shuts.
    public static func marks(
        for node: UEFINode,
        in image: UEFIImage,
        badChecksums: Set<UEFIChecksumField> = [],
        isOpen: Bool = false
    ) -> ToolRowMarks {
        var errors: [String] = []
        var cautions: [String] = []
        if !badChecksums.isEmpty {
            errors.append(checksumText(badChecksums))
        }

        var roles: [ToolRowMarks.Role] = []
        var opens = false
        if let compression = node.compression {
            // Opened, or still closed and openable. A section that decodes and
            // is neither did not decompress — unless it had no body to try.
            let open = node.isExpandable || node.children.contains { $0.space != node.space }
            let failed = compression.decodes && !open && !node.body.isEmpty
            roles.append(.compressed(algorithm: compression.algorithm,
                                     decoded: compression.decodes && !failed))
            // The rail starts here while the row is open on what came out of
            // the section, so the reader sees the section and its subtree as one
            // bracket. Shut, or with nothing decompressed under it, there is
            // nothing to tie it to.
            opens = isOpen && node.children.contains { $0.space != node.space }
            if failed {
                cautions.append(decompressionFailure(of: node, in: image)
                    ?? "\(compression.algorithm) data did not decompress")
            }
        }

        if let holds = holdsChecks(node) {
            roles.append(.holdsChecks(holds))
        }
        var protection: ToolRowMarks.Protection?
        if let ranges = image.protectedRanges {
            switch ranges.protection(of: node, in: image) {
            case .ibb: protection = .ibb
            case .protected: protection = .firmware
            // Tinting a region for bytes it mostly is not would say the wrong
            // thing; the badge says "some of this" (ROW_MARKS.md §2).
            case .partial: roles.append(.partlyProtected)
            case nil: break
            }
            let hashes = hashProblems(of: node, in: image, ranges: ranges)
            errors += hashes.errors
            cautions += hashes.cautions
        }

        return ToolRowMarks(
            protection: protection,
            decompressedFrom: decompressedFrom(node, in: image),
            opensDecompressed: opens,
            problem: .worst(errors: errors, cautions: cautions),
            roles: roles
        )
    }

    /// Which of a node's checksums is wrong, since "invalid" alone leaves the
    /// reader to open the detail to find out.
    public static func checksumText(_ fields: Set<UEFIChecksumField>) -> String {
        let names = fields.map(\.label).sorted()
        return names.count == 1
            ? "Invalid \(names[0]) checksum"
            : "Invalid checksums: \(names.joined(separator: ", "))"
    }

    /// The words on the badge of a node that holds a list of protected ranges
    /// — nil for every other node.
    public static func holdsChecks(_ node: UEFINode) -> String? {
        guard node.space == .file else { return nil }
        switch node.kind {
        case .file where node.guid == KnownGUIDs.amiHashFile:
            return "Holds the AMI vendor hash table: ranges the firmware checks at boot"
        case .file where node.guid == KnownGUIDs.phoenixHashFile:
            return "Holds the Phoenix vendor hash table: ranges the firmware checks at boot"
        case .flashDeviceMapStore:
            return "Holds the Insyde flash device map: ranges the firmware checks at boot"
        default:
            return nil
        }
    }

    /// A protected range whose hash does not check out, on the node it starts
    /// at and on the node holding the list that names it (§6.2). An IBB that
    /// does not match is a caution, not an error: the reference implementation
    /// never makes that comparison, and until it is confirmed against boards
    /// known to boot it is not a verdict (§6.1).
    private static func hashProblems(
        of node: UEFINode, in image: UEFIImage, ranges: ProtectedRanges
    ) -> (errors: [String], cautions: [String]) {
        guard let fileRange = node.fileRange, !fileRange.isEmpty else { return ([], []) }
        let holdsList = holdsChecks(node) != nil
        var errors: [String] = []
        var cautions: [String] = []
        for range in ranges.ranges {
            let startsHere = range.range.map {
                $0.lowerBound == fileRange.lowerBound && fileRange.upperBound <= $0.upperBound
            } ?? false
            let namesIt = holdsList && fileRange.contains(range.source.lowerBound)
            guard startsHere || namesIt else { continue }
            switch range.verdict {
            case .mismatch:
                let text = "\(range.kind.name)\(at(range)) does not match its hash"
                if range.kind.isIBB { cautions.append(text) } else { errors.append(text) }
            case .unsupported(let algorithm):
                cautions.append("\(range.kind.name)\(at(range)) could not be checked: "
                                + "\(TCGHash.name(algorithm)) is not computed here")
            case .matches, .unchecked:
                break
            }
        }
        return (unique(errors), unique(cautions))
    }

    private static func at(_ range: ProtectedRange) -> String {
        range.range.map { " at 0x" + String($0.lowerBound, radix: 16, uppercase: true) } ?? ""
    }

    private static func unique(_ lines: [String]) -> [String] {
        var seen: Set<String> = []
        return lines.filter { seen.insert($0).inserted }
    }

    /// The rail's words: which section the node's bytes came out of.
    private static func decompressedFrom(_ node: UEFINode, in image: UEFIImage) -> String? {
        guard case .decompressed(let chain) = node.space, let outermost = chain.first else {
            return nil
        }
        let section = image.innermostNode(containing: outermost)
            .flatMap { $0.header.lowerBound == outermost ? $0.name : nil }
            ?? "a compressed section"
        let hex = "0x" + String(outermost, radix: 16, uppercase: true)
        var text = "Decompressed from \(section) at \(hex)"
        if chain.count > 1 { text += ", \(chain.count) compressed sections deep" }
        return text
    }

    /// What the parse said when this section did not decompress, found where
    /// the parse put it: at the section in the file, or inside the buffer the
    /// section itself sits in.
    private static func decompressionFailure(of node: UEFINode, in image: UEFIImage) -> String? {
        image.diagnostics.first { diagnostic in
            switch diagnostic.kind {
            case .decompressionFailed, .decompressedTooLarge: break
            default: return false
            }
            if node.space == .file {
                return diagnostic.inside == nil && diagnostic.offset == node.header.lowerBound
            }
            return diagnostic.inside == .init(space: node.space, offset: node.header.lowerBound)
        }?.message
    }
}
