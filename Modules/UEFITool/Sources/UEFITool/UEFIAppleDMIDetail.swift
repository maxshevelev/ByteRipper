import Foundation
import Localization
import UEFIImage

/// What the details say of Apple's identity (`AppleDMIArea`), on the SysF
/// store it is read from: what a technician should know before trusting it,
/// then the serial number, the configuration code, the sales order number
/// and the board's serial, each a way to the variable it is read from.
///
/// A row keeps only its place, so the store's entries are read again from
/// the file on each selection: a few dozen headers, read in microseconds.
public enum UEFIAppleDMIDetail {
    /// The area `node` is the SysF store of; nil for any other node.
    static func area(for node: UEFINode, reader: ImageReader) -> AppleDMIArea? {
        guard node.kind == .sysFStore, node.space == .file else { return nil }
        return AppleDMIArea.read(store: node, reader: reader)
    }

    /// The notes, then the values, in the order a Mac's own tools list them.
    static func build(for node: UEFINode, reader: ImageReader, in language: AppLanguage)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard let area = area(for: node, reader: reader) else { return ([], []) }
        let fields = UEFIDMIEntries.findings(area.findings.map { ($0.text, false) }, in: language)
        let rows = area.values.map { value in
            UEFIDMIEntries.Row(name: value.name.text(in: language), value: value.value, source: value.entry)
        }
        return (fields, [UEFIDMIEntries.table(rows, among: node.children, in: language)])
    }

    /// `Apple SysF store · C02QMDJVG940`: the store's name and the serial it
    /// holds, or the board's where the store keeps no serial.
    static func row(for node: UEFINode, reader: ImageReader?, in language: AppLanguage) -> String? {
        guard let reader, let area = area(for: node, reader: reader),
              let who = area.serialNumber ?? area.boardSerial
        else { return nil }
        return L("%1$@ · %2$@", in: language, node.displayName(in: language), who)
    }
}
