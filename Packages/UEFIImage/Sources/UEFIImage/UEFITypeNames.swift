import Foundation

/// The names a consumer shows for the one-byte type codes, so a tool-module's
/// detail panel does not re-derive the tables (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// The tables themselves stay private to the parser; this is the thin public
/// edge a reader that has a type byte and wants a word for it goes through.
public enum UEFITypeNames {
    /// The name of an FFS file type byte (§5.6). Unknown codes keep their
    /// number, which is the only thing there is to say about a vendor type.
    public static func file(_ type: UInt8) -> String { FFS.typeName(type) }

    /// The name of a section type byte (§6.1).
    public static func section(_ type: UInt8) -> String { Section.typeName(type) }

    /// The file types a search can name, in the order of the type byte: the
    /// ones with a name of their own. A vendor's `OEM file` and `Debug file`
    /// ranges are many codes under one name, and are left out.
    public static let fileTypes: [UInt8] = Array(0x01...0x0F) + [FFS.padType]

    /// The section types the parser knows (§6.1), in the order of the type byte.
    public static let sectionTypes: [UInt8] = (0...UInt8.max).filter(Section.isKnown)
}
