import PartCodec
import ToolModuleKit
import UEFIImage

/// A host that opens a part of an image and is told what a UEFI panel opened
/// on it should read the bytes as (`Design/UEFI/UPDATE_IN_PARENT.md` §2.1).
///
/// The same opening as `ToolHost.openPart(named:linkedTo:codec:)` — the codec
/// is the whole of what the part is — with one thing a firmware tool-module
/// knows and the seam does not: that a decompressed body is a run of sections
/// rather than an image to scan, or that a node is a volume.
@MainActor public protocol UEFIPartOpening: AnyObject {
    func openPart(named name: String, linkedTo source: Range<UInt64>,
                  layout: UEFIRootLayout, codec: any PartCodec)
}
