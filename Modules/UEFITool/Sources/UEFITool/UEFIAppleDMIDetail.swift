import Foundation
import Localization
import UEFIImage

/// What the details say of Apple's identity (`AppleDMIArea`), on the SysF
/// store it is read from: the serial number, the configuration code, the
/// sales order number and the board's serial, then what a technician should
/// know before trusting them.
///
/// A row keeps only its place, so the store's entries are read again from
/// the file on each selection: a few dozen headers, read in microseconds.
public enum UEFIAppleDMIDetail {
    /// The area `node` is the SysF store of; nil for any other node.
    static func area(for node: UEFINode, reader: ImageReader) -> AppleDMIArea? {
        guard node.kind == .sysFStore, node.space == .file else { return nil }
        return AppleDMIArea.read(store: node, reader: reader)
    }

    /// The fields, in the order a Mac's own tools list them, then the notes.
    static func build(for node: UEFINode, reader: ImageReader, in language: AppLanguage)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard let area = area(for: node, reader: reader) else { return ([], []) }
        func shown(_ text: String?) -> String { (text?.isEmpty ?? true) ? "—" : text! }
        var fields: [UEFIDetailField] = [
            .init(L("Serial number", in: language), shown(area.serialNumber)),
            .init(L("Configuration code", in: language), shown(area.configCode)),
            .init(L("Sales order number", in: language), shown(area.orderNumber)),
            .init(L("MLB (board serial)", in: language), shown(area.boardSerial)),
        ]
        for finding in area.findings {
            fields.append(.init(L("Note", in: language), finding.text.text(in: language)))
        }
        return (fields, [])
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
