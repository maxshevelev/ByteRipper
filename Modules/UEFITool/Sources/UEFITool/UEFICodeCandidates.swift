import CodeAnalysis
import ECImage
import Foundation
import UEFIImage

/// Which nodes can be a code-analysis module. The unit is the TE/PE32 image,
/// not the FFS file and not the section as a container
/// (`Design/CODE_PANEL_PLAN.md`): the node whose **body** is the image.
///
/// The structural test is cheap and does not read bytes. `isImage` reads the
/// two magic bytes and is the one that decides; a PE32 or TE section whose body
/// is padding is a candidate structurally and not an image.
///
/// An EC firmware image is a module too (`ECImage`): the node the tree cut
/// into the image's parts. Its module is not the node's bytes but
/// [0, extent) with the bytes the EC rewrites normalised, so its identity is
/// `moduleDigest(of:)`'s, never the body's plain SHA-256.
public enum UEFICodeCandidates {
    public static let pe32Section: UInt8 = 0x10
    public static let teSection: UInt8 = 0x12

    /// A section whose type says image, or a file whose body may be one. A
    /// typed file whose body reads as sections is not filtered here; its body
    /// does not begin with the magic, so `isImage` answers.
    public static func isCandidate(_ node: UEFINode) -> Bool {
        if isECImage(node) { return true }
        switch node.kind {
        case .section:
            return node.subtype == pe32Section || node.subtype == teSection
        case .file:
            return true
        default:
            return false
        }
    }

    /// Whether `node`'s body begins `MZ` or `VZ`, read through the reader for
    /// the node's own space.
    public static func isImage(_ node: UEFINode, reader: ImageReader) -> Bool {
        guard isCandidate(node), node.body.count >= 2,
              let magic = reader.bytes(at: node.body.lowerBound, count: 2)
        else { return false }
        return isImage(magic)
    }

    public static func isImage(_ data: Data) -> Bool {
        isImage(Array(data.prefix(2))) || ECFirmware.isEC(data)
    }

    /// The node holding an EC image the parser read (`ECImage.ECFirmware`):
    /// the one its parts are the rows of. No bytes are read.
    public static func isECImage(_ node: UEFINode) -> Bool {
        node.children.first?.kind == .ecImagePart
    }

    /// The module the bytes of a candidate's body are, and its identity: the
    /// bytes themselves for a PE32 or TE image; for an EC image, the part
    /// [0, extent) as read — the dump's own bytes, which the Code panel shows —
    /// identified as `ECFirmware` identifies it. Nil when they are neither.
    public static func module(of data: Data) -> (digest: SHA256Digest, bytes: Data, ec: ECFirmware?)? {
        if isImage(Array(data.prefix(2))) { return (SHA256Digest(data: data), data, nil) }
        guard ECFirmware.isEC(data), let firmware = try? ECFirmware(slice: data),
              let digest = SHA256Digest(hex: firmware.sha256) else { return nil }
        return (digest, Data(data.prefix(firmware.extent)), firmware)
    }

    public static func isImage(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        return (bytes[0] == 0x4D && bytes[1] == 0x5A)      // "MZ"
            || (bytes[0] == 0x56 && bytes[1] == 0x5A)      // "VZ"
    }
}
