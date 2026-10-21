import Foundation
import Localization
import UEFIImage

/// What the details say of Acer's DMI area (`AcerDMIStore`): what the
/// integrity checks found in the 8 KiB block, then its fields — the system
/// serial, the motherboard serial, the UUID, the model, the product name —
/// each a way to its row under the block's.
///
/// A row keeps only its place, so the block is read again from the file on
/// each selection: 8 KiB, read in microseconds.
public enum UEFIAcerDMIDetail {
    /// The kinds this reads.
    static func reads(_ kind: UEFINodeKind) -> Bool {
        kind == .acerDMIStore
    }

    /// What the integrity checks found — a problem where a factory block
    /// would not read that way, a note where only the copy went stale — then
    /// the fields, in the order the bench asks them.
    static func build(for node: UEFINode, image: UEFIImage, reader: ImageReader, in language: AppLanguage)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard node.space == .file, reads(node.kind),
              let stored = reader.bytes(node.range),
              let area = AcerDMIArea.found(stored: stored, offset: node.range.lowerBound)
        else { return ([], []) }
        let fields = UEFIDMIEntries.findings(area.findings.map { ($0.text, $0.isProblem) }, in: language)
        let rows = UEFIDMIEntries.rows(area.fields, reader: reader, in: language)
        return (fields, [UEFIDMIEntries.table(rows, among: node.children, in: language)])
    }
}
