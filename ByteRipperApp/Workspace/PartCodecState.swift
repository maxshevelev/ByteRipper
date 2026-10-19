import Foundation
import LenovoDMI
import Localization
import PartCodec
import UEFIContentSource
import UEFIImage

/// A part's codec as the workspace writes it down, and back
/// (`Design/WORKSPACE_PLAN.md`, "Parts").
///
/// The app's, not the package's: the codecs live in four packages, and only
/// the app links all of them. A codec this does not know is not written, and
/// its part does not come back.
enum PartCodecState: Codable, Equatable {
    case copy
    case readOnly(bytes: [UInt8], title: LocalizedText, reason: LocalizedText, transform: LocalizedText?)
    case uefi(target: UEFIRebuild.Target, compression: String?)
    case lenovoDMI(encodes: Bool, key: UInt8)

    init?(_ codec: any PartCodec) {
        switch codec {
        case is CopyPartCodec:
            self = .copy
        case let codec as ReadOnlyPartCodec:
            self = .readOnly(bytes: codec.bytes, title: codec.title, reason: codec.reason,
                             transform: codec.transform)
        case let codec as UEFIPartCodec:
            self = .uefi(target: codec.target, compression: codec.compression)
        case let codec as LenovoDMIBlockCodec:
            self = .lenovoDMI(encodes: codec.encodes, key: codec.key)
        default:
            return nil
        }
    }

    var codec: any PartCodec {
        switch self {
        case .copy:
            return CopyPartCodec()
        case let .readOnly(bytes, title, reason, transform):
            return ReadOnlyPartCodec(bytes, title: title, reason: reason, transform: transform)
        case let .uefi(target, compression):
            return UEFIPartCodec(target: target, compression: compression)
        case let .lenovoDMI(encodes, key):
            return LenovoDMIBlockCodec(encodes: encodes, key: key)
        }
    }

    // MARK: - As text in the workspace

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static func text<T: Encodable>(_ value: T) -> String? {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func value<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
        text.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
}
