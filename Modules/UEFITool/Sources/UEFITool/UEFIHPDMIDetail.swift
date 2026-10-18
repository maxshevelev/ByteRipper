import Foundation
import Localization
import UEFIImage

/// What the details say of HP's identity (`HPDMIArea`), on the `HP_MUD`
/// entry it is read from: the fields BCU reports — the serial number, the
/// SKU, the family, the CT number, the product name, the UUID — then the
/// build ID, the feature byte and the asset tracking number from the
/// variables beside it, and what a technician should know before trusting
/// them.
///
/// A row keeps only its place, so the store's entries are read again from
/// the file on each selection: a few hundred headers, read in microseconds.
public enum UEFIHPDMIDetail {
    /// The store `node` is an entry of, when it is a VSS one.
    static func store(of node: UEFINode, in image: UEFIImage) -> UEFINode? {
        guard node.kind == .vssEntry, node.space == .file, !node.id.path.isEmpty,
              let store = image.node(NodeID(Array(node.id.path.dropLast()))),
              store.kind == .vssStore || store.kind == .vss2Store
        else { return nil }
        return store
    }

    /// The area `node` is the `HP_MUD` entry of; nil for any other node.
    static func area(for node: UEFINode, image: UEFIImage, reader: ImageReader) -> HPDMIArea? {
        area(for: node, store: store(of: node, in: image), reader: reader)
    }

    /// The same, with the store already in hand — a tree row has its parent.
    static func area(for node: UEFINode, store: UEFINode?, reader: ImageReader) -> HPDMIArea? {
        guard node.kind == .vssEntry, node.guid == HPDMIArea.factoryGuid, let store,
              store.kind == .vssStore || store.kind == .vss2Store,
              let area = HPDMIArea.read(store: store, reader: reader), area.entry == node.range
        else { return nil }
        return area
    }

    /// The fields, in the order BCU lists them, then the notes.
    static func build(for node: UEFINode, image: UEFIImage, reader: ImageReader, in language: AppLanguage)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard let area = area(for: node, image: image, reader: reader) else { return ([], []) }
        func shown(_ text: String?) -> String { (text?.isEmpty ?? true) ? "—" : text! }
        var fields: [UEFIDetailField] = [
            .init(L("Serial number", in: language), shown(area.serialNumber)),
            .init(L("SKU", in: language), shown(area.sku)),
            .init(L("Product family", in: language), shown(area.productFamily)),
            .init(L("CT number", in: language), shown(area.ctNumber)),
            .init(L("Product name", in: language), shown(area.productName)),
            .init(L("UUID", in: language), area.uuidText),
            .init(L("Build ID", in: language), shown(area.buildID)),
            .init(L("Feature byte", in: language), shown(area.featureByte)),
            .init(L("Asset tracking number", in: language), shown(area.assetTag)),
        ]
        for finding in area.findings {
            fields.append(.init(L("Note", in: language), finding.text.text(in: language)))
        }
        return (fields, [])
    }

    /// `HP_MUD · 5CD4432P9B`: the variable's name and the serial number it
    /// holds — on a copy the store marks deleted too, which UEFITool would
    /// call Invalid; the rest is in the detail.
    static func row(for node: UEFINode, store: UEFINode?, image: UEFIImage?, reader: ImageReader?,
                    in language: AppLanguage) -> String? {
        guard node.kind == .vssEntry, node.guid == HPDMIArea.factoryGuid, let reader,
              let area = area(for: node, store: store ?? image.flatMap { self.store(of: node, in: $0) }, reader: reader)
        else { return nil }
        return L("%1$@ · %2$@", in: language, HPDMIArea.mudName, area.serialNumber)
    }
}
