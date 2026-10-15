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
// addresses, values and the five-way correlation behind the index mapping are
// in Skills/me-eom-structures/reference/structures.md. A skill of its own would
// be one enum and two scans: this is MEFirmware's, beside the layout readers it
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

    /// The OEM public key hash the UEP area carries, as uppercase hex — or nil
    /// when the area holds no such value: an image whose UEP was wiped, or a
    /// generation whose UEP is elsewhere.
    ///
    /// The hash is a SHA-384 the area repeats (six copies in the images this
    /// was established on, in two groups of three, each group an entry of the
    /// same record layout). It is found as the most repeated 48-byte value that
    /// looks like key material rather than a fill pattern or a pointer —
    /// `ManufacturingDecoder`'s sibling heuristic, and the one the research
    /// oracle uses, so the panel and the oracle answer the same dump alike.
    static func oemPublicKeyHash(in uep: Data) -> String? {
        guard uep.count >= 48 else { return nil }
        var best: (hash: Data, keyBytes: Int, count: Int)? = nil
        var seen = Set<Data>()
        var offset = 0
        while offset + 48 <= uep.count {
            let candidate = uep.subdata(in: (uep.startIndex + offset)..<(uep.startIndex + offset + 48))
            offset += 4
            guard !seen.contains(candidate), isKeyMaterial(candidate) else { continue }
            seen.insert(candidate)
            // How much of the window is not the area's own fill: the key is the
            // alignment that is *all* key, while a window slid into the padding
            // — the same bytes at the same places, as often — holds fill at one
            // end. Ranked before the copy count, because a shift matches every
            // copy the true alignment does.
            let keyBytes = candidate.filter { $0 != 0x00 && $0 != 0xFF }.count
            guard keyBytes >= 40 else { continue }
            let count = occurrences(of: candidate, in: uep)
            guard count > 1 else { continue }
            if best == nil || (keyBytes, count) > (best!.keyBytes, best!.count) {
                best = (candidate, keyBytes, count)
            }
        }
        return best.map { hex($0.hash) }
    }

    /// High-entropy and not periodic: key material rather than a fill pattern
    /// (an erased area is all `0xFF`) or a pointer padded with zeros.
    ///
    /// Neither end may be a run of one byte either. The area this reads is
    /// padded with `0x00` or `0xFF`, so a window that starts or ends inside
    /// such a run is a *shifted view* of the same key — it occurs at the same
    /// places, as often, and would be printed as padding with the key's head or
    /// tail on it. A real SHA-384 has eight equal bytes at one end with
    /// probability 2⁻⁵⁶.
    private static func isKeyMaterial(_ block: Data) -> Bool {
        guard Set(block).count >= 16 else { return false }
        let half = block.count / 2
        let first = block.prefix(half)
        let rest = block.suffix(from: block.startIndex + half)
        guard first != rest else { return false }
        return Set(block.prefix(8)).count > 1 && Set(block.suffix(8)).count > 1
    }

    /// How many times a value occurs in an area, overlaps included: the copies
    /// of a UEP hash sit in records of the same length, so they never overlap,
    /// and counting them by stepping one byte at a time is the cheap way to be
    /// sure none is missed.
    private static func occurrences(of block: Data, in area: Data) -> Int {
        var count = 0
        var from = area.startIndex
        while let found = area.range(of: block, options: [], in: from..<area.endIndex) {
            count += 1
            from = found.lowerBound + 1
        }
        return count
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
