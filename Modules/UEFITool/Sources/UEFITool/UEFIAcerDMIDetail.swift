import Foundation
import Localization
import UEFIImage

/// What the details say of Acer's DMI area (`AcerDMIStore`): the identity
/// fields — the system serial, the service tag, the UUID, the model, the
/// product name — read off the 8 KiB block, then what the integrity checks
/// found in them.
///
/// A row keeps only its place, so the block is read again from the file on
/// each selection: 8 KiB, read in microseconds.
public enum UEFIAcerDMIDetail {
    /// The kinds this reads.
    static func reads(_ kind: UEFINodeKind) -> Bool {
        kind == .acerDMIStore
    }

    /// The block's identity fields, in the order the bench asks them, then
    /// what the integrity checks found in them — a problem where a factory
    /// block would not read that way, a note where only the copy went stale.
    static func build(for node: UEFINode, image: UEFIImage, reader: ImageReader)
        -> (fields: [UEFIDetailField], tables: [UEFIDetailTable]) {
        guard node.space == .file, reads(node.kind),
              let stored = reader.bytes(node.range),
              let area = AcerDMIArea.found(stored: stored, offset: node.range.lowerBound)
        else { return ([], []) }
        var fields: [UEFIDetailField] = [
            .init(L("System serial"), area.systemSerial),
            .init(L("Service tag"), area.serviceTag),
            .init(L("UUID"), area.uuidText),
            .init(L("Model"), area.model.isEmpty ? "—" : area.model),
        ]
        if let asset = area.assetTag {
            fields.append(.init(L("Asset tag"), asset))
        }
        fields.append(.init(L("Product name"), area.productName.isEmpty ? "—" : area.productName))
        if let code = area.manufacturingCode {
            fields.append(.init(L("Manufacturing code"), code))
        }
        for finding in area.findings {
            fields.append(.init(finding.isProblem ? L("Problem") : L("Note"), finding.text,
                                isProblem: finding.isProblem))
        }
        return (fields, [])
    }
}
