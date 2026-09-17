import Foundation

/// The Unlock Token Flags an unlock-token partition ends with — upstream
/// `UTFL_Header` (MEA.py 2038), read at the two places `ext_anl` looks for it
/// (6637 and 6650).
///
/// A CSE image may carry a debug unlock token as an FPT partition named `UTOK`
/// or `STKN` (upstream's own pair, MEA.py 5558). The partition holds a signed
/// token — a manifest and its extensions, which the `$MN2`/`$CPD` decode
/// already reads — and *optionally* ends with a 0x20-byte flags structure whose
/// first four bytes are `UTFL`. Optional is upstream's word for it: a token
/// without one is not a defect, and the two read sites are exactly "token with
/// a manifest" and "flags without a token", neither of which errors when the
/// tag is absent.
///
/// The structure itself is four bytes of tag, one byte of Delayed
/// Authentication Mode and 27 reserved bytes. Byte-verified on two dumps:
/// `CSME 15.bin` (UTOK @0x460000, flags @0x461FE0) and `CSME 12.BIN`
/// (UTOK @0x6B000, flags @0x6CFE0) — both Delayed Authentication Mode 0 with
/// every reserved byte erased to 0xFF.
enum UnlockTokenParser {

    /// The names upstream treats as unlock-token partitions.
    static let partitionNames = ["UTOK", "STKN"]

    /// `UTFL_Header`'s length (the model states it too, for its readers), and
    /// the tag that identifies it.
    static let flagsSize = UnlockTokenFlags.size
    static let tag = Data("UTFL".utf8)

    /// The flags at the end of the partition occupying
    /// `region[offset ..< offset+size]`, or nil where the partition does not
    /// end with them.
    ///
    /// The structure is located by the partition's *end* and not by searching:
    /// upstream reads `buffer[len - 0x20 : len - 0x1C]` and compares the tag,
    /// so a `UTFL` appearing anywhere else in a token is not this structure.
    static func flags(in region: Data, offset: Int, size: Int,
                      absoluteOffset: Int, partition: String) -> UnlockTokenFlags? {
        guard offset >= 0, size >= flagsSize, offset + size <= region.count else { return nil }
        let start = offset + size - flagsSize
        guard region.subdata(in: start..<(start + 4)) == tag else { return nil }
        let reserved = region.subdata(in: (start + 0x05)..<(start + flagsSize))
        return UnlockTokenFlags(
            partition: partition,
            offset: absoluteOffset + size - flagsSize,
            delayedAuthMode: Int(region[start + 0x04]),
            reservedHex: reserved.map { String(format: "%02X", $0) }.joined())
    }
}
