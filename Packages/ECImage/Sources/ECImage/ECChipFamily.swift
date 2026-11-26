import Foundation

/// What is known of one family of EC firmware images: how to recognise one,
/// which bytes the EC rewrites in its own flash, where its memory and
/// registers are, and what Ghidra reads it as.
///
/// One profile per family, so the rules a second family needs are a second
/// value and not a branch in the code that reads the image.
public struct ECChipFamily: Equatable, Sendable {
    /// The family's id, as a module records it: `ite-nds32`.
    public let id: String
    /// What a reader calls it.
    public let title: String
    /// Ghidra's language id.
    public let language: String
    /// Where the signature sits, and its bytes: nil is a byte the signature
    /// does not fix (a configuration byte, or one the EC rewrites).
    public let signatureOffset: Int
    public let signature: [UInt8?]
    /// The second form of the signature the BIOS's EC flash routine also
    /// accepts: this text at this offset (the version string then starts
    /// there).
    public let textSignatureOffset: Int
    public let textSignature: [UInt8]
    /// How many bytes the BIOS reflashes into the EC (from its own copy):
    /// what an update writes, not where the image ends.
    public let hostUpdateSize: Int
    /// Where the version string starts, and its longest length.
    public let versionOffset: Int
    public let versionLength: Int
    /// The bytes the EC rewrites in its own flash once it runs, by offset,
    /// with the value the identity hash takes for them.
    public let rewrittenBytes: [Int: UInt8]
    /// The address the flash executes at.
    public let flashBase: UInt64
    /// The data RAM and the register window.
    public let ram: Range<UInt64>
    public let registers: Range<UInt64>
    /// Where, in a read of the chip, the EC keeps what it writes at run time
    /// (settings, a log): a slice whose bytes past the image are only there
    /// is a chip read, and those bytes are not the image's.
    public let runtimeAreaStart: Int
    /// The first exception vector that is a hardware interrupt level.
    public let firstInterruptVector: Int
    /// The names of the vectors before it, by index (the Andes core's).
    public let exceptionVectors: [Int: String]
    /// The interrupt controller's vector register, and what its value
    /// stands for: interrupt number = value - `ivctBias`.
    public let ivctRegister: UInt64
    public let ivctBias: Int

    /// ITE IT83xx (IT8227E, the `ITE8380` firmware) on the Andes N801 core.
    public static let iteNDS32 = ECChipFamily(
        id: "ite-nds32",
        title: "ITE IT83xx (Andes NDS32 N801)",
        language: "NDS32:LE:32:default",
        signatureOffset: 0x80,
        signature: [0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, nil, nil, nil, 0x5A, 0x5A, 0xAA, nil, 0x55, 0x55],
        textSignatureOffset: 0x50,
        textSignature: Array("ITE EC-V".utf8),
        // The BIOS's EC flash routine writes 0x2C000 bytes from SPI 0x21000.
        hostUpdateSize: 0x2C000,
        versionOffset: 0x90,
        versionLength: 16,
        // The EC turns 0xAF into 0x00 here itself (the person's reading of a
        // chip read beside the BIOS copy).
        rewrittenBytes: [0x8D: 0x00],
        flashBase: 0,
        ram: 0x80000..<0x83000,
        registers: 0xF00000..<0xF10000,
        runtimeAreaStart: 0x2A000,
        firstInterruptVector: 9,
        exceptionVectors: [1: "TlbFill", 2: "PteNotPresent", 3: "TlbMisc", 4: "TlbVlptMiss",
                           5: "MachineError", 6: "Debug", 7: "General", 8: "Syscall"],
        ivctRegister: 0xF01110,
        ivctBias: 0x10)

    public static let all: [ECChipFamily] = [.iteNDS32]

    /// The family whose signature the bytes carry, and whose first word is
    /// the reset vector's `j`.
    public static func family(of data: Data) -> ECChipFamily? {
        all.first { $0.matches(data) }
    }

    public func matches(_ data: Data) -> Bool {
        let start = data.startIndex
        guard data.count > 0, data[start] == 0x48 else { return false }
        return signatureForm(of: data) != nil
    }

    /// Which form of the signature the bytes carry: the bytes at
    /// `signatureOffset`, else the text at `textSignatureOffset`.
    public func signatureForm(of data: Data) -> Int? {
        let start = data.startIndex
        if data.count >= signatureOffset + signature.count,
           signature.enumerated().allSatisfy({ $0.element == nil || data[start + signatureOffset + $0.offset] == $0.element }) {
            return 1
        }
        if data.count >= textSignatureOffset + textSignature.count,
           data[(start + textSignatureOffset)..<(start + textSignatureOffset + textSignature.count)].elementsEqual(textSignature) {
            return 2
        }
        return nil
    }

    /// The version string: printable ASCII from `versionOffset` to the first
    /// byte that is not.
    public func version(of data: Data) -> String? {
        let offset = signatureForm(of: data) == 2 ? textSignatureOffset : versionOffset
        let start = data.startIndex + offset
        guard data.count >= offset + 1 else { return nil }
        var text = ""
        for at in start..<min(data.endIndex, start + versionLength) {
            let byte = data[at]
            guard (0x20..<0x7F).contains(byte) else { break }
            text.append(Character(UnicodeScalar(byte)))
        }
        return text.isEmpty ? nil : text
    }
}
