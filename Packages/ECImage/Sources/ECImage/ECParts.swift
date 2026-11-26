import Foundation

/// One part of an EC image's slice, by what its bytes are: what the UEFI tree
/// shows under an EC image's row.
public struct ECPart: Equatable, Sendable {
    public enum Kind: UInt8, CaseIterable, Sendable {
        /// The exception and interrupt vectors from offset 0, with the
        /// reserved words after them up to the signature.
        case vectors = 1
        /// The signature block and the version string after it.
        case signature = 2
        /// The code and its constants: the rest of what the linker placed,
        /// up to the `.data` initializer.
        case code = 3
        /// The initial values the reset code copies into RAM (`.data`).
        case dataInitializer = 4
        /// Erased bytes past the image.
        case free = 5
        /// In a read of the chip, the area the EC writes at run time.
        case runtimeData = 6
    }

    public let kind: Kind
    /// Relative to the slice's start, half-open.
    public let range: Range<Int>
}

extension ECFirmware {
    /// The slice cut into its parts, in order, with no gap and no overlap:
    /// the vectors, the signature and version, the code, the `.data`
    /// initializer when the reset code says where it is, the erased space
    /// past the image, and — in a read of the chip — the run-time data area.
    /// A part with no bytes is left out.
    public var parts: [ECPart] {
        var parts: [ECPart] = []
        func add(_ kind: ECPart.Kind, _ lower: Int, _ upper: Int) {
            let lower = max(lower, parts.last?.range.upperBound ?? 0)
            guard lower < upper else { return }
            parts.append(ECPart(kind: kind, range: lower..<upper))
        }
        let textForm = family.signatureForm(of: image) == 2
        let signatureStart = min(textForm ? family.textSignatureOffset : family.signatureOffset, extent)
        let signatureEnd = min(textForm ? family.textSignatureOffset + family.versionLength
                                        : family.versionOffset + family.versionLength, extent)
        add(.vectors, 0, signatureStart)
        add(.signature, signatureStart, signatureEnd)
        if extentSource == .crt0, let source = startup?.dataSource, Int(source) >= signatureEnd {
            add(.code, signatureEnd, Int(source))
            add(.dataInitializer, Int(source), extent)
        } else {
            add(.code, signatureEnd, extent)
        }
        if chipRead {
            add(.free, extent, min(family.runtimeAreaStart, sliceSize))
            add(.runtimeData, family.runtimeAreaStart, sliceSize)
        } else {
            add(.free, extent, sliceSize)
        }
        return parts
    }
}
