import Foundation
import MEFirmware
import ToolModuleKit

/// What a row of the ME Full Tree wears besides its text (`Design/ROW_MARKS.md`
/// §5.3), decided here so it is tested without a window, in the icons of the one
/// catalogue every firmware panel draws from.
///
/// - the compressed badge on a `$CPD` module stored compressed — indigo where
///   this panel shows what came out of it (the `pm` / `rbe` metadata table),
///   grey everywhere else, and for a module that is encrypted as well;
/// - the rail on the RBE/PM Metadata rows when the module they were read out of
///   is stored compressed;
/// - the holds-checks badge on the manifest, which carries the hashes the
///   modules are checked against;
/// - a problem on a row whose own checksum or signature does not check out.
///
/// No background: the Boot Guard ranges lie in the BIOS region, and an ME row
/// never sits inside one.
public enum MEATreeMarks {
    /// Every mark this tree draws — what its legend lists.
    public static let legendMarks: [ToolRowMark] = [
        .decompressed, .error, .compressed, .compressedUndecoded, .holdsChecks
    ]

    /// How a module is stored, from its directory row and its `.met`
    /// companion's Module Attributes block.
    public struct Storage: Equatable, Sendable {
        /// "Huffman" or "LZMA"; nil for a module stored as it is.
        public var compression: String?
        public var isEncrypted: Bool
    }

    public static func storage(of module: CPDModule, in partition: CodePartition) -> Storage {
        let attributes = partition.modules
            .first { $0.name == module.name + ".met" }?
            .extensions?.compactMap(\.moduleAttributes).first
        let compression: String?
        switch attributes?.compression {
        case 1: compression = "Huffman"
        case 2: compression = "LZMA"
        default: compression = module.isHuffman ? "Huffman" : nil
        }
        return Storage(compression: compression, isEncrypted: (attributes?.encryption ?? 0) != 0)
    }

    /// The modules the RBE/PM Metadata table is read out of.
    static let metadataModules: Set<String> = ["pm", "rbe"]

    /// A `$CPD` module's row: the compressed badge when it is stored
    /// compressed. It opens here only when it is the module the panel's
    /// metadata table was read out of, and it is not encrypted.
    public static func module(_ module: CPDModule, in partition: CodePartition,
                              analysis: FirmwareAnalysis) -> ToolRowMarks {
        let stored = storage(of: module, in: partition)
        guard let compression = stored.compression else { return .none }
        let opens = !stored.isEncrypted && metadataModules.contains(module.name)
            && !(analysis.rbePmMetadata ?? []).isEmpty
        return ToolRowMarks(roles: [.compressed(
            algorithm: stored.isEncrypted ? "Encrypted \(compression)" : compression,
            decoded: opens
        )])
    }

    /// The code partition's row: its directory checksum.
    public static func codePartition(_ partition: CodePartition) -> ToolRowMarks {
        guard partition.checksumValid == false else { return .none }
        let kind = partition.headerVersion == 1 ? "Checksum-8" : "CRC-32"
        return ToolRowMarks(problem: .error(["Invalid $CPD \(kind) checksum"]))
    }

    /// The manifest's row: it holds the hashes the modules are checked
    /// against, and its own signature may not check out.
    public static func manifest(_ analysis: FirmwareAnalysis) -> ToolRowMarks {
        ToolRowMarks(
            problem: analysis.rsaSignatureValid == false
                ? .error(["The manifest's RSA signature does not check out"]) : nil,
            roles: [.holdsChecks("Holds the hashes the partition's modules are checked against")]
        )
    }

    /// A layout table's row: its CRC-32, where its version has one.
    public static func table(named name: String, checksumValid: Bool?) -> ToolRowMarks {
        guard checksumValid == false else { return .none }
        return ToolRowMarks(problem: .error(["Invalid \(name) CRC-32"]))
    }

    /// The RBE/PM Metadata rows: the rail when the module they were read out
    /// of is stored compressed, with its name in the words.
    public static func metadata(_ analysis: FirmwareAnalysis) -> ToolRowMarks {
        guard let partition = analysis.codePartition,
              let module = partition.modules.first(where: { metadataModules.contains($0.name) }),
              let compression = storage(of: module, in: partition).compression
        else { return .none }
        return ToolRowMarks(
            decompressedFrom: "Read out of the \(module.name) module, stored \(compression) compressed"
        )
    }
}
