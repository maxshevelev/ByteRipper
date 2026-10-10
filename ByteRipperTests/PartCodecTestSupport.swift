import Foundation
import PartCodec
import ToolModuleKit
import UEFIContentSource
import UEFIImage
@testable import ByteRipper

/// Bytes a test hands over as a part: they open as given — whatever the
/// source holds — and go back through `back`. What a test of the panels needs
/// is a part with known bytes; what the codec does with them on the way back
/// is the codec's own test.
struct GivenBytesCodec: PartCodec {
    var bytes: [UInt8]
    var back: any PartCodec

    func decode(_ parent: PartParent) throws -> [UInt8] { bytes }
    func encode(_ part: [UInt8], into parent: PartParent) throws -> PartUpdate {
        try back.encode(part, into: parent)
    }
    var isImmediate: Bool { back.isImmediate }
    var keepsOffsets: Bool { back.keepsOffsets }
    var badge: PartBadge? { back.badge }
}

/// A body that is not the file's bytes: what a decompressed body is to the
/// bookmarks, without a compressed section having to exist.
struct ElsewhereCodec: PartCodec {
    func decode(_ parent: PartParent) throws -> [UInt8] { try parent.sourceBytes() }
    func encode(_ part: [UInt8], into parent: PartParent) throws -> PartUpdate {
        throw PartRefusal(title: .verbatim("This cannot be put back"), message: .verbatim("A test body."))
    }
    var keepsOffsets: Bool { false }
}

extension DocumentOrigin {
    /// The two shapes the panel tests build origins in.
    enum Kind {
        case copy
        case decompressed

        var codec: any PartCodec {
            switch self {
            case .copy: return CopyPartCodec()
            case .decompressed: return ElsewhereCodec()
            }
        }
    }

    convenience init?(parent: PaneViewModel, source: Range<UInt64>, partName: String,
                      layout: UEFIRootLayout, kind: Kind, content: [UInt8]) {
        self.init(parent: parent, source: source, partName: partName, layout: layout,
                  codec: kind.codec, content: content)
    }
}

extension ToolHost {
    /// A copy with the test's own bytes in it.
    func openPart(_ bytes: [UInt8], named name: String, linkedTo source: Range<UInt64>) {
        openPart(named: name, linkedTo: source, codec: GivenBytesCodec(bytes: bytes, back: CopyPartCodec()))
    }
}

extension PaneToolHost {
    /// The test's bytes, going back through the rebuild planner at `part`.
    func openPart(_ bytes: [UInt8], named name: String, linkedTo source: Range<UInt64>,
                  layout: UEFIRootLayout, part: UEFIRebuild.Target) {
        openPart(named: name, linkedTo: source, layout: layout,
                 codec: GivenBytesCodec(bytes: bytes, back: UEFIPartCodec(target: part)))
    }
}
