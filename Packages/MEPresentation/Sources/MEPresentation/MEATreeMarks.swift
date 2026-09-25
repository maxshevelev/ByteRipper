import Foundation
import Localization
import MEFirmware
import ToolModuleKit

/// What a row of the ME Full Info tree wears besides its text (`Design/ROW_MARKS.md`
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
        .decompressed, .error, .caution, .compressed, .compressedUndecoded, .holdsChecks
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
    /// compressed — it opens here only when it is the module the panel's
    /// metadata table was read out of, and it is not encrypted — and what the
    /// engine's module checks said about it (`Issue.module`): an error for an
    /// error, a caution for the rest. They stay in the Issues group too.
    public static func module(_ module: CPDModule, in partition: CodePartition,
                              analysis: FirmwareAnalysis) -> ToolRowMarks {
        var errors: [String] = []
        var cautions: [String] = []
        for issue in analysis.issues where issue.module == module.name {
            if issue.severity == .error {
                errors.append(issue.message)
            } else {
                cautions.append(issue.message)
            }
        }
        var roles: [ToolRowMarks.Role] = []
        let stored = storage(of: module, in: partition)
        if let compression = stored.compression {
            let opens = !stored.isEncrypted && metadataModules.contains(module.name)
                && !(analysis.rbePmMetadata ?? []).isEmpty
            roles.append(.compressed(
                algorithm: stored.isEncrypted ? "Encrypted \(compression)" : compression,
                decoded: opens
            ))
        }
        return ToolRowMarks(problem: .worst(errors: errors, cautions: cautions), roles: roles)
    }

    /// The code partition's row: its directory checksum.
    public static func codePartition(_ partition: CodePartition) -> ToolRowMarks {
        guard partition.checksumValid == false else { return .none }
        let kind = partition.headerVersion == 1 ? "Checksum-8" : "CRC-32"
        return ToolRowMarks(problem: .error([L("Invalid $CPD %1$@ checksum", kind)]))
    }

    /// The manifest's row: it holds the hashes the modules are checked
    /// against, and its own signature may not check out.
    public static func manifest(_ analysis: FirmwareAnalysis) -> ToolRowMarks {
        ToolRowMarks(
            problem: analysis.rsaSignatureValid == false
                ? .error([L("The manifest's RSA signature does not check out")]) : nil,
            roles: [.holdsChecks(L("Holds the hashes the partition's modules are checked against"))]
        )
    }

    /// A layout table's row: its CRC-32, where its version has one.
    public static func table(named name: String, checksumValid: Bool?) -> ToolRowMarks {
        guard checksumValid == false else { return .none }
        return ToolRowMarks(problem: .error([L("Invalid %1$@ CRC-32", name)]))
    }

    /// The RBE/PM Metadata rows: the rail when the module they were read out
    /// of is stored compressed, with its name in the words.
    public static func metadata(_ analysis: FirmwareAnalysis) -> ToolRowMarks {
        guard let partition = analysis.codePartition,
              let module = partition.modules.first(where: { metadataModules.contains($0.name) }),
              let compression = storage(of: module, in: partition).compression
        else { return .none }
        return ToolRowMarks(
            decompressedFrom: L("Read out of the %1$@ module, stored %2$@ compressed",
                                module.name, compression)
        )
    }
}
