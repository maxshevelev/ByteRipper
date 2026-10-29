// Boot Guard, as much of it as a dump can carry: the profile the image is built
// for, and the OEM public key hash the ME region holds.
//
// Three different places, all read by shape rather than through a table,
// because none is described by any specification this project has:
//
//   * the **profile**, first source — a JSON record of the CDMD partition's
//     configuration, under that partition's `FIT AS A FIDDLE` signature: MFIT
//     writes the setting there as an index into its own list of four profiles;
//   * the **profile**, second source — the four flags FIT builds a profile from,
//     as bits of the UEP area: the first `UepBitsArray` of CSME 15 and 16, whose
//     images carry no CDMD record, and the area's own record on CSME 12 to 14,
//     which has the same four bits in a differently shaped container;
//   * the **OEM public key hash** is a 48-byte SHA-384 the UEP area holds
//     several copies of, beside the key manifest it belongs to (a 32-byte
//     SHA-256 on CSME 12 to 14).
//
// All were established on real dumps with known Boot Guard levels — for the
// second source, on builds of one image whose FIT `.xml` readings differ in this
// one field and nothing else (three CSME 15 builds at profiles 3, 4 and 5, four
// CSME 14 builds at 0, 3, 4 and 5), each moving the bits and leaving the rest of
// the image byte-identical; the structures are described in
// `Design/ME_STRUCTURES.md`, and the addresses, values and the five-way
// correlation behind the index mapping are in
// Skills/me-eom-structures/reference/structures.md. A skill of its own would be
// one enum and three scans: this is MEFirmware's, beside the layout readers it
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

    /// The profile the UEP area's Boot Guard bits name, or nil when the area is
    /// erased or its bits are no combination of the four settings.
    ///
    /// Where an image has no CDMD record — every CSME 15 image, and the older
    /// CSME 16 ones — this is where the profile lives: FIT keeps the four
    /// settings a profile is made of as **bits of the UEP area's first
    /// `UepBitsArray`**, and reads the combination back out of the image the
    /// same way. The tool's own layout document names each bit and where it
    /// goes (`GetBitArrayValue … source="$BootGuardProfileSettings/FBGAcmEn"
    /// target="UepBitsArray0" params="{'offset':'0x60','startBit':16…}"`, and
    /// the same for the other three at 19, 20 and 21), and its
    /// `BootGuardProfiles` class is the table from combination to profile.
    ///
    /// The bytes are measured rather than derived: the array's first byte is
    /// 0x0C into the container, so the four flags are the byte at **+0x6E** —
    /// bit 0 `FBGAcmEn`, 3 `ProtectBiosEnvironment`, 4 `MeasuredBoot`, 5
    /// `VerifiedBoot`. The neighbouring bits are the two debug switches and the
    /// key manifest id, and that the same byte answers MFIT's
    /// `BtGuardKeyManifestId` correctly is what says the reading is aligned
    /// rather than merely nearby.
    ///
    /// Read on images whose profile is known independently, and *written* there
    /// by the very tools that read it: three FIT 15 builds of one CSME 15 image
    /// at profiles 3, 4 and 5 (their `.xml` readings differ in this field and
    /// nothing else) and three MFIT builds of one CSME 16 image at profiles 0, 3
    /// and 5, each moving these bits and leaving the rest of the image
    /// byte-identical. It agrees with the CDMD record wherever an image carries
    /// both — and since both are the tool's own writing, a disagreement would be
    /// a finding about how the image was assembled rather than a coin toss.
    /// What it never does is turn a combination the table does not name into the
    /// nearest profile: four settings are one profile or they are a layout this
    /// does not read.
    static func profile(inUEPArea uep: Data) -> BootGuardProfile? {
        // The same container `UEPReader` reads the settings beside it from.
        guard let container = containerOffset(in: uep) else { return nil }
        let signature = uep.startIndex + container
        guard let flagsAt = uep.index(signature, offsetBy: flagsOffset,
                                      limitedBy: uep.endIndex),
              flagsAt < uep.endIndex else { return nil }
        // An area never written is not a profile: as bits, all zeros answer
        // No_FVME and all ones answer FVME, and neither was chosen for the
        // image. The signature alone does not say the area is written — a
        // CSME 12 image's UEP partition carries it over a blank body — so what
        // is looked at is the body behind it.
        let bodyStart = uep.index(signature, offsetBy: min(8, uep.distance(from: signature,
                                                                          to: uep.endIndex)))
        let bodyEnd = uep.index(signature, offsetBy: min(0x80, uep.distance(from: signature,
                                                                            to: uep.endIndex)))
        let body = uep[bodyStart..<bodyEnd]
        if body.isEmpty || body.allSatisfy({ $0 == 0x00 }) || body.allSatisfy({ $0 == 0xFF }) {
            return nil
        }
        // And an array that is blank is not an array whose four flags are all
        // false. The word just ahead of the flags is another setting's bits,
        // and every image this reads has it written; a container with zeroes
        // there is another structure behind the same signature — a CSME 12
        // image's UEP partition is one, whose own bytes sit elsewhere — and
        // answers nothing rather than No_FVME.
        guard let wordAt = uep.index(signature, offsetBy: wordOffset,
                                     limitedBy: uep.endIndex),
              uep.distance(from: wordAt, to: uep.endIndex) >= 2 else { return nil }
        let word = UInt16(uep[wordAt]) | UInt16(uep[uep.index(after: wordAt)]) << 8
        if word == 0 || word == 0xFFFF { return nil }
        let flags = uep[flagsAt]
        return profile(ofFlags: flags)
    }

    /// The profile a generation's UEP **record** names, or nil where this is not
    /// that generation's layout — the two shapes measured so far, chosen by
    /// `major` as the key record's offsets are.
    ///
    /// **CSME 12 and 14**: four FIT 14.0 builds of one CSME 14 image, one per
    /// profile, whose `.xml` readings differ in `BtGuardProfileConfig` and
    /// nothing else and whose bytes differ in five of sixteen million — the
    /// checksum behind `$UEP`, the mask at +0x34, and the flags byte at +0x4C,
    /// once in each of the record's three copies (+0xE8 and +0x178). The four
    /// settings sit in the same bits as the later generations' array — FBG ACM
    /// 0, `ProtectBiosEnvironment` 3, `MeasuredBoot` 4, `VerifiedBoot` 5 — and
    /// the same table names the profile: the image's own bits at 0x46 with 0x38
    /// on for 3, 0x29 for 4 and 0x39 for 5, which is 0x46, 0x7E, 0x6F and 0x7F.
    ///
    /// **CSME 13** is the same experiment run on the two Lenovo NM-C711 dumps
    /// (13.0.21.1319 and 13.0.32.1478, Ice Lake-U) with FIT 13.0: four builds
    /// whose readings differ in that one setting and whose bytes differ in six of
    /// sixteen million — the container's checksum, the mask at +0x40, and the
    /// flags byte of each of the record's three copies, which read 0x40, 0x78,
    /// 0x69 and 0x79 for profiles 0, 3, 4 and 5. XOR against the image's own 0x40
    /// is 0x38, 0x29 and 0x39 — the same three constants as every other
    /// generation — so Intel's table names the profile here too. Both factory
    /// dumps then read 0x40, profile 0, which matches the absence of any
    /// `__KEYM__` or `__BPM__` in their BIOS regions.
    ///
    /// The tool's own UEP document agrees on the *bits and their meaning* — it
    /// places the four settings at bits 16 to 21 of the first bit array
    /// (`$BootGuardProfileSettings/FBGAcmEn` … `VerifiedBoot` in
    /// `fit-13.0.exe`), the same four in the same order — but the byte the
    /// builds move is the record's, and no byte of any array moved on them: what
    /// the document describes is a placement this tool did not write, and what
    /// the reader reads is the byte that does move.
    ///
    /// **The mask is what says the container is this layout**, `0xCC` where the
    /// ACM is not forced and `0xFF` where it is — the low byte of a dword whose
    /// other bytes are the same on every image at hand, and are what makes the
    /// two shapes tell each other apart: a CSME 12–14 container read as 13, or
    /// the reverse, fails on the mask rather than answering. It is zero in the
    /// later generations' container, and a blank body leaves it zero too — which
    /// is what keeps an area never written from reading as profile 5 on the
    /// all-ones flags such a body carries. That the mask and the ACM bit agree is
    /// checked as well: a disagreement means these offsets are not this image's
    /// layout, and nothing is claimed.
    static func profile(inRecordUEPArea uep: Data, major: Int) -> BootGuardProfile? {
        let layout = major == 13 ? iceLakeRecordLayout : earlierRecordLayout
        guard let container = containerOffset(in: uep), container >= 0 else { return nil }
        func block(at offset: Int, length: Int) -> Data? {
            let start = container + offset
            guard start >= 0, start + length <= uep.count else { return nil }
            let from = uep.startIndex + start
            return uep[from..<(from + length)]
        }
        func word(at offset: Int) -> UInt32? {
            guard let bytes = block(at: offset, length: 4) else { return nil }
            return bytes.enumerated().reduce(UInt32(0)) { value, pair in
                value | UInt32(pair.element) << (8 * UInt32(pair.offset))
            }
        }
        // The container's word for the ACM: 0xCC without it, 0xFF with it.
        guard let mask = word(at: layout.maskOffset),
              mask == layout.maskWithoutACM || mask == layout.maskWithACM else { return nil }
        // A record never written points nowhere: a zero body and an erased one
        // both answer here, before the flags — whose all-ones an erased body
        // would otherwise read as profile 5.
        guard let source = word(at: layout.sourceOffset), source != 0,
              source != UInt32.max else { return nil }
        let copies = layout.flagOffsets.compactMap { block(at: $0, length: 1)?.first }
        guard copies.count == layout.flagOffsets.count,
              Set(copies).count == 1 else { return nil }
        let flags = copies[0]
        guard (mask == layout.maskWithACM) == (flags & 0x01 != 0) else { return nil }
        return profile(ofFlags: flags)
    }

    /// The four settings a profile is made of, as one byte, to the profile they
    /// name — the combination Intel's own `BootGuardProfiles` table holds. A
    /// combination the table does not name is a layout this does not read, and
    /// never the nearest profile.
    private static func profile(ofFlags flags: UInt8) -> BootGuardProfile? {
        switch (flags & 0x01 != 0, flags & 0x20 != 0,
                flags & 0x10 != 0, flags & 0x08 != 0) {
        case (false, false, false, false): return .noFVME   // FBG ACM off, nothing verified
        case (false, true, true, true): return .vm          // verified and measured
        case (true, true, false, true): return .fve         // firmware verified
        case (true, true, true, true): return .fvme         // verified and measured, ACM forced
        default: return nil
        }
    }

    /// Where a generation keeps the four settings in its UEP container's record:
    /// the mask that guards the layout, the record's source pointer, and the
    /// flags byte of each copy the record is kept in. Measured off the
    /// container's signature on the dumps and builds at hand.
    private struct RecordLayout {
        let maskOffset: Int
        let maskWithoutACM: UInt32
        let maskWithACM: UInt32
        let sourceOffset: Int
        let flagOffsets: [Int]
    }

    /// CSME 12 and 14: mask 0xCC/0xFF at +0x34 with zeroes above it, the
    /// record's source at +0x48, the flags byte at +0x4C, +0xE8 and +0x178.
    private static let earlierRecordLayout = RecordLayout(
        maskOffset: 0x34, maskWithoutACM: 0xCC, maskWithACM: 0xFF,
        sourceOffset: 0x48, flagOffsets: [0x4C, 0xE8, 0x178])

    /// CSME 13: the same facts 0x18 further in — the mask at +0x40, whose ACM
    /// byte keeps 0xC0 above it, the record's source at +0x60, and the flags
    /// byte at +0x64, +0x150 and +0x22C, a copy every 0xDC.
    private static let iceLakeRecordLayout = RecordLayout(
        maskOffset: 0x40, maskWithoutACM: 0xC0CC, maskWithACM: 0xC0FF,
        sourceOffset: 0x60, flagOffsets: [0x64, 0x150, 0x22C])

    /// How far into the `$UEP` container the first bit array's flags byte sits,
    /// and the word the same array keeps just ahead of it — both measured off
    /// the container's signature on the images at hand.
    private static let flagsOffset = 0x6E
    private static let wordOffset = 0x68

    /// Where a generation's key record sits in the area: how far into the
    /// container the field starts, how long the hash is, and where the area
    /// keeps the copies of it (relative to the container).
    ///
    /// The two are **told apart by the generation, not by trying both**: a read
    /// of the wrong length lands half inside the other's field. Measured on the
    /// dumps at hand — a 32-byte read of a CSME 15 key starts on the zeroes
    /// before it, and a 48-byte read of a CSME 14 key starts on the second half
    /// of the hash and runs into the bitmap that follows it — which is why the
    /// caller has to say which generation the image is.
    private struct KeyRecord {
        let offset: Int
        let length: Int
        let copies: [Int]
    }

    /// CSME 15 and later: a 48-byte SHA-384, 0xA0 bytes in and again 0x10A0 in.
    private static let laterKeyRecord = KeyRecord(offset: 0xA0, length: 48, copies: [0, 0x1000])
    /// CSME 12 to 14: a 32-byte SHA-256, 0x90 bytes in, followed by the 16
    /// bytes of assignment bits that are *not* part of the hash. Read once: the
    /// second half of those areas is erased on the images at hand.
    private static let earlierKeyRecord = KeyRecord(offset: 0x90, length: 32, copies: [0])

    /// The OEM public key hash the UEP area holds, and what its entry says
    /// where there is no key to read.
    ///
    /// `major` is the ME generation the image was identified as, and it decides
    /// which of the two records is read (`KeyRecord` above): the SHA-256 of
    /// CSME 12 to 14, or the SHA-384 of 15 and later. Both sit inside the
    /// area's entry at a fixed offset from the container that opens the area
    /// (`$UEPC`, or the `$UEP` this project's earlier note saw).
    ///
    /// Where the field holds no key, what it holds is the finding:
    ///
    ///   * all zeros — the setting MFIT calls "OEM signing is disabled";
    ///   * all `0xFF` — an area never written, so no key was ever put there;
    ///   * anything else, or no container to find the entry from, or two copies
    ///     that disagree — an area this reader does not know how to walk
    ///     (CSME 11 has no area at all).
    ///
    /// The row says which of those it is rather than "no key", because they are
    /// three different states of a boot chain. What it never does is print a
    /// neighbouring field as if it were the key: a key is per vendor, and two
    /// vendors' images cannot carry the same one.
    static func oemPublicKeyHash(in uep: Data, major: Int) -> OEMKeyHash {
        guard let container = containerOffset(in: uep) else { return .unrecognized }
        // The generations between 12 and 14 keep the shorter record; everything
        // else — including an image the engine could not name — is read as the
        // later one, which is what the layouts at hand do.
        let record = (12...14).contains(major) ? earlierKeyRecord : laterKeyRecord
        // The record in each copy the area has. The first decides; the others
        // corroborate, and a disagreement means the offsets are not this
        // image's layout.
        let fields = record.copies.compactMap { copy -> OEMKeyHash? in
            let at = container + copy + record.offset
            guard at >= 0, at + record.length <= uep.count else { return nil }
            let start = uep.startIndex + at
            let block = uep.subdata(in: start..<(start + record.length))
            if block.allSatisfy({ $0 == 0x00 }) { return .allZeros }
            if block.allSatisfy({ $0 == 0xFF }) { return .erased }
            return isKeyMaterial(block) ? .hash(hex(block)) : .unrecognized
        }
        guard let first = fields.first else { return .unrecognized }
        // A key wherever it is: an area whose second half alone was written
        // still holds one. Two copies that carry *different* keys mean the
        // offsets above are not this image's layout, and nothing is claimed.
        let keys = fields.compactMap { field -> String? in
            if case .hash(let hex) = field { return hex }
            return nil
        }
        if Set(keys).count > 1 { return .unrecognized }
        if let hex = keys.first { return .hash(hex) }
        return first
    }

    /// Where the ASCII container that opens the UEP area begins, counted from
    /// the area's first byte — not a `Data` index, so a slice reads the same as
    /// a copy. `$UEPC` preferred (it is `$UEP` plus its revision letter), and
    /// the bare `$UEP` the older dumps use. Nil when the image has no such area
    /// in the bytes it handed over. Shared with `UEPReader` and the profile and
    /// key readers here, so all of them read past the same signature.
    static func containerOffset(in uep: Data) -> Int? {
        if let at = uep.range(of: Data("$UEPC".utf8))?.lowerBound {
            return uep.distance(from: uep.startIndex, to: at)
        }
        var from = uep.startIndex
        while let at = uep.range(of: Data("$UEP".utf8), options: [], in: from..<uep.endIndex) {
            let after = at.upperBound
            if after >= uep.endIndex || uep[after] != UInt8(ascii: "C") {
                return uep.distance(from: uep.startIndex, to: at.lowerBound)
            }
            from = after
        }
        return nil
    }

    /// High-entropy and not periodic: a key rather than a fill pattern (an
    /// erased field is all `0xFF`), a pointer padded with zeros, or a record's
    /// own header. A real hash has almost as many distinct bytes as it is long
    /// — forty-eight for a SHA-384, thirty-two for the SHA-256 of the older
    /// generations — while a pointer or a length field is a handful and a lot
    /// of padding, and neither of those reaches sixteen.
    ///
    /// Neither end may be a run of one byte either: an entry's field is
    /// surrounded by the area's `0x00`/`0xFF` padding, so a field that begins
    /// or ends in such a run is not the key at that offset: a hash has eight
    /// equal bytes at one end with probability 2⁻⁵⁶.
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
