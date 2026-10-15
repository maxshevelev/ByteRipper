// Boot Guard, as much of it as a dump can carry: the profile the image is built
// for, and the OEM public key hash the ME region holds.
//
// Two different places, both read by shape rather than through a table, because
// neither is described by any specification this project has:
//
//   * the **profile** is a JSON record of the CDMD partition's configuration,
//     under that partition's `FIT AS A FIDDLE` signature — MFIT writes the
//     setting there as an index into its own list of four profiles;
//   * the **OEM public key hash** is a 48-byte SHA-384 the UEP area holds
//     several copies of, beside the key manifest it belongs to.
//
// Both were established on real dumps with known Boot Guard levels; the
// structures are described in `Design/ME_STRUCTURES.md`, and the addresses,
// values and the five-way correlation behind the index mapping are in
// Skills/me-eom-structures/reference/structures.md. A skill of its own would be
// one enum and two scans: this is MEFirmware's, beside the layout readers it
// works over.

import Foundation

/// Reads the two Boot Guard facts an image carries.
enum BootGuardReader {

    /// The profile the CDMD configuration names, or nil when the image carries
    /// no such record — an older layout, or a vendor image whose Boot Guard was
    /// never configured from the ME side (those boards answer profile 0, but
    /// the dump does not say so and this does not guess it).
    ///
    /// The record is `{"BtGuardProfileConfig": <index>}`: the value is MFIT's
    /// index, not the level — `BootGuardProfile(index:)` holds the mapping. The
    /// key is looked for as text and the number read behind it, so a partition
    /// carrying other records around it reads the same.
    static func profile(in cdmd: Data) -> BootGuardProfile? {
        guard let needle = "BtGuardProfileConfig".data(using: .ascii) else { return nil }
        var from = cdmd.startIndex
        while let found = cdmd.range(of: needle, options: [], in: from..<cdmd.endIndex) {
            from = found.upperBound
            var i = found.upperBound
            // The value's colon: a `}` first means this was another key of the
            // same record (or of a later one), not the setting.
            while i < cdmd.endIndex, cdmd[i] != UInt8(ascii: ":"), cdmd[i] != UInt8(ascii: "}") {
                i += 1
            }
            guard i < cdmd.endIndex, cdmd[i] == UInt8(ascii: ":") else { continue }
            i += 1
            while i < cdmd.endIndex, cdmd[i] == UInt8(ascii: " ") { i += 1 }
            var value = 0, digits = 0
            while i < cdmd.endIndex,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(cdmd[i]) {
                value = value * 10 + Int(cdmd[i] - UInt8(ascii: "0"))
                digits += 1
                i += 1
            }
            if digits > 0, let profile = BootGuardProfile(index: value) { return profile }
        }
        return nil
    }

    /// The OEM public key hash the UEP area holds, and what its entry says
    /// where there is no key to read.
    ///
    /// The key is a 48-byte SHA-384 and it sits **inside the area's entry**, at
    /// a fixed offset from the container that opens the area (`$UEPC`, or the
    /// `$UEP` this project's earlier note saw): 0xA0 bytes in, and again 0x10A0
    /// in where the area carries its second half. That is the field, not a
    /// shape: reading it gives the same value the repeated-window search this
    /// replaced found on every image at hand — and it reads images that search
    /// could not, because the offsets are the entry's own rather than a count
    /// of how often a value happens to appear.
    ///
    /// Where the field holds no key, what it holds is the finding:
    ///
    ///   * all zeros — the setting MFIT calls "OEM signing is disabled";
    ///   * all `0xFF` — an area never written, so no key was ever put there;
    ///   * anything else, or no container to find the entry from, or two halves
    ///     that disagree — an area this reader does not know how to walk
    ///     (CSME 14's entry holds something else, CSME 11 has no area at all).
    ///
    /// The row says which of those it is rather than "no key", because they are
    /// three different states of a boot chain. What it never does is print a
    /// neighbouring field as if it were the key: a key is per vendor, and two
    /// vendors' images cannot carry the same one.
    static func oemPublicKeyHash(in uep: Data) -> OEMKeyHash {
        guard let container = uepContainerOffset(in: uep) else { return .unrecognized }
        // The entry's own key field, in each half the area has. The first
        // decides; the second corroborates, and a disagreement means the
        // offsets above are not this image's layout.
        let halves = [container + keyFieldOffset, container + 0x1000 + keyFieldOffset]
        let fields = halves.compactMap { at -> OEMKeyHash? in
            guard at >= 0, at + 48 <= uep.count else { return nil }
            let start = uep.startIndex + at
            let block = uep.subdata(in: start..<(start + 48))
            if block.allSatisfy({ $0 == 0x00 }) { return .allZeros }
            if block.allSatisfy({ $0 == 0xFF }) { return .erased }
            return isKeyMaterial(block) ? .hash(hex(block)) : .unrecognized
        }
        guard let first = fields.first else { return .unrecognized }
        // A key wherever it is: an area whose second half alone was written
        // still holds one. Two halves that carry *different* keys mean the
        // offsets above are not this image's layout, and nothing is claimed.
        let keys = fields.compactMap { field -> String? in
            if case .hash(let hex) = field { return hex }
            return nil
        }
        if Set(keys).count > 1 { return .unrecognized }
        if let hex = keys.first { return .hash(hex) }
        return first
    }

    /// How far into the UEP area's entry its key field sits — measured off the
    /// container, which is also where the entry starts.
    private static let keyFieldOffset = 0xA0

    /// The ASCII container that opens the UEP area: `$UEPC`, or the `$UEP`
    /// inside one of those (`$UEPC` is `$UEP` plus its revision letter). Nil
    /// when the image has no such area in the bytes it handed over.
    private static func uepContainerOffset(in uep: Data) -> Int? {
        if let at = uep.range(of: Data("$UEPC".utf8))?.lowerBound { return at }
        var from = uep.startIndex
        while let at = uep.range(of: Data("$UEP".utf8), options: [], in: from..<uep.endIndex) {
            let after = at.upperBound
            if after >= uep.endIndex || uep[after] != UInt8(ascii: "C") {
                return at.lowerBound
            }
            from = after
        }
        return nil
    }

    /// High-entropy and not periodic: a key rather than a fill pattern (an
    /// erased field is all `0xFF`), a pointer padded with zeros, or a record's
    /// own header. A real SHA-384 has forty-eight distinct-ish bytes; a pointer
    /// or a length field has a handful and a lot of padding.
    ///
    /// Neither end may be a run of one byte either: an entry's field is
    /// surrounded by the area's `0x00`/`0xFF` padding, so a field that begins
    /// or ends in such a run is not the key at that offset. A real SHA-384 has
    /// eight equal bytes at one end with probability 2⁻⁵⁶.
    private static func isKeyMaterial(_ block: Data) -> Bool {
        guard Set(block).count >= 16 else { return false }
        let half = block.count / 2
        let first = block.prefix(half)
        let rest = block.suffix(from: block.startIndex + half)
        guard first != rest else { return false }
        return Set(block.prefix(8)).count > 1 && Set(block.suffix(8)).count > 1
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
