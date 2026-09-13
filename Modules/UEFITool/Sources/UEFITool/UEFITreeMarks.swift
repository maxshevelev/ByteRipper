import Foundation
import ToolModuleKit
import UEFIImage

/// What a row of the UEFI tree wears besides its name (`Design/ROW_MARKS.md`
/// §5.1), decided here so it is tested without a window.
///
/// Today that is the rail for every node inside a compressed section and for
/// the section itself while its row is open,
/// the compressed badge on a compressed section, and the problem icon for a wrong
/// checksum or a section that did not decompress. The Boot Guard background and
/// badges join when the protected ranges are read.
public enum UEFITreeMarks {
    /// Every mark this tree draws — what its legend lists.
    public static let legendMarks: [ToolRowMark] = [
        .decompressed, .error, .caution, .compressed, .compressedUndecoded
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

        return ToolRowMarks(
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
