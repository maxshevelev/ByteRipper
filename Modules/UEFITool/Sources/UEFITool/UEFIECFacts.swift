import ECImage
import Foundation
import HexText
import Localization

/// What the (i) on an EC image's row says of it (`ECImage.ECFirmware`): the
/// family, the version, where the image ends and how that was found, the
/// module's identity and the slice's own SHA-256, how much a BIOS update
/// writes, and the byte the EC rewrites in its own flash. Decided here so it
/// is tested without a window.
public enum UEFIECFacts {
    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
    }

    // help: panel.uefi.ec-image
    public static func rows(of firmware: ECFirmware, in language: AppLanguage) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(label: L("Family", in: language), value: firmware.family.title))
        rows.append(Row(label: L("ITE signature", in: language),
                        value: firmware.version ?? L("Not stated", in: language)))
        let source = firmware.extentSource == .crt0
            ? L("from the start-up code", in: language)
            : L("last written byte", in: language)
        rows.append(Row(label: L("Image end", in: language),
                        value: "\(firmware.extent.hexNumber) (\(source))"))
        rows.append(Row(label: L("Module SHA-256", in: language), value: firmware.sha256))
        rows.append(Row(label: L("Dump SHA-256", in: language), value: firmware.rawSHA256))
        rows.append(Row(label: L("BIOS update writes", in: language), value: firmware.family.hostUpdateSize.hexNumber))
        for byte in firmware.masked {
            rows.append(Row(label: L("Byte rewritten by the EC", in: language),
                            value: L("%1$@: %2$@ in the dump, %3$@ in the identity", in: language,
                                     byte.offset.hexNumber, String(format: "0x%02X", byte.actual),
                                     String(format: "0x%02X", byte.normalised))))
        }
        if firmware.chipRead {
            rows.append(Row(label: L("Source", in: language), value: L("Read of the EC chip", in: language)))
        }
        return rows
    }
}
