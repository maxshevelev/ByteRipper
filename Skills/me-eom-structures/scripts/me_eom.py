#!/usr/bin/env python3
"""Read the End-of-Manufacturing, Boot Guard and OEM-key facts out of an ME dump.

Research oracle for Skills/me-eom-structures. Stdlib only, read-only: it takes a
dump path and prints one fact per line, so a run over a folder is a diff to skim
and the same lines can be compared with MFIT's own build report.

Understood well enough to claim (see reference/structures.md):

  * the flash descriptor: signature at 0x10, FLMAP0 at 0x14, FLMAP1 at 0x18;
    region table at (FLMAP0>>16 & 0xFF)<<4, master section at (FLMAP1 & 0xFF)<<4;
    the BIOS master's word is v2 form: read = word>>8 & 0xFFF, write = word>>20 & 0xFFF;
  * the OEM Configuration (FITC): a u32 record count, then 12-byte records
    {fileID u32, offset u32, flags u32}; a record's value bytes sit at
    count-address + offset. File IDs known from the panel: eom 0x10020000,
    eom_config 0x1001EE00, manuf_lock 0x10020100. Located by shape, not by the
    partition table, whose IFWI layout this script does not parse. What it prints
    for those files is the *defaults* page — the one a clean image carries too;
    what is in force now is in the MFS file system, which the app's engine reads.
  * the UEP area opens with the ASCII "$UEP" (or "$UEPC"), then a 16-bit CRC and
    two reserved bytes, then the bit arrays FIT keeps its Boot Guard settings in.
  * a 48-byte value the UEP holds and the ME region repeats is key material — the
    OEM public key hash is a SHA-384 (48 bytes). Heuristic.
  * the Boot Guard profile is a JSON record in the CDMD partition, under the
    ASCII signature "FIT AS A FIDDLE": {"BtGuardProfileConfig": <index>}, where
    the index picks MFIT's list 0 - No_FVME, 1 -> 3 - VM, 2 -> 4 - FVE,
    3 -> 5 - FVME. Verified against the owner's ground truth on five dumps.
  * where there is no such record — every CSME 15 image — the profile is the
    four settings themselves, as bits of the UEP area's first bit array; the
    same four FIT 15's table names. Read on the owner's three builds of one
    image, whose FIT readings differ in this and nothing else.

Not understood yet (do not guess in a report): what the rest of the UEP entry
fields mean (the bits beside the four, the 0x4FE/0xFE word, the checksum's
range), and what the rest of the CDMD configuration's records are.
"""

import json
import struct
import sys

REGION_NAMES = {0: "Descriptor", 1: "BIOS", 2: "ME", 3: "GbE", 4: "PDR",
                5: "DevExp1", 6: "BIOS2", 7: "Microcode", 8: "EC", 9: "DevExp2",
                10: "IE", 11: "10GbE1", 12: "10GbE2", 13: "Rsvd1", 14: "Rsvd2",
                15: "PTT"}

EOM_FILES = {0x10020000: ("/home/mca/eom", 1),
             0x1001EE00: ("/home/mca/eom_config", 2),
             0x10020100: ("/home/mca/manuf_lock", 1)}

# MFIT's Boot Guard Profile list, as its own settings database spells it. The
# index is MFIT's own: the level it names is not the index.
BOOT_GUARD_PROFILES = {0: "0 - No_FVME", 1: "3 - VM", 2: "4 - FVE", 3: "5 - FVME"}

# The same four profiles the older FIT keeps as the four settings a profile is
# made of — FBG ACM, verified, measured, protect — keyed by them. This is the
# `BootGuardProfiles` table of FIT 15's own layout, and it is what an image
# without a CDMD record carries instead.
BOOT_GUARD_FLAGS = {(0, 0, 0, 0): "0 - No_FVME",
                    (0, 1, 1, 1): "3 - VM",
                    (1, 1, 0, 1): "4 - FVE",
                    (1, 1, 1, 1): "5 - FVME"}

# Where the four bits sit in the UEP area: the first `UepBitsArray`'s flags byte
# (FBG ACM bit 0, protect 3, measured 4, verified 5), measured off the "$UEP"
# signature on the images at hand. FIT's layout names those bits in the array
# (`GetBitArrayValue … offset="0x60" startBit="16"`, and 19/20/21 for the other
# three); that the array's bytes begin 0x0C into the container is the part the
# class does not say, so the offset is measured rather than derived.
UEP_FLAGS_OFFSET = 0x6E
# The word the same array keeps just ahead of the flags, written wherever this
# layout is and blank in a container of another structure.
UEP_WORD_OFFSET = 0x68


# Which record a generation keeps its OEM key hash in, and how long the hash
# is: CSME 12 to 14 write a 32-byte SHA-256 at +0x90 (with 16 bytes of
# assignment bits behind it), CSME 15 and later a 48-byte SHA-384 at +0xA0 and
# again at +0x10A0. Read on the boards at hand — five CSME 14 images, and every
# CSME 15/16 one.
OEM_KEY_RECORDS = {"earlier": (0x90, 32, (0,)), "later": (0xA0, 48, (0, 0x1000))}


def oem_key_field(me, uep_at, major):
    """The key hash field of the generation, or None where the area is too
    short. Which record is read follows the generation, not a guess: reading
    the wrong one lands half inside the other field."""
    if uep_at < 0:
        return None
    offset, length, copies = OEM_KEY_RECORDS["earlier" if 12 <= major <= 14 else "later"]
    for copy in copies:
        at = uep_at + copy + offset
        if at + length <= len(me):
            return me[at:at + length]
    return None


def uep_boot_guard_flags(me, uep_at):
    """The profile's four settings out of the UEP area, or None where the area
    carries no such bits: never written (all zeros, all 0xFF), too short, or
    their combination is no profile. The area's body, not its signature, is what
    says it was written."""
    if uep_at < 0 or uep_at + UEP_FLAGS_OFFSET + 1 > len(me):
        return None
    body = me[uep_at + 8:uep_at + 0x80]
    if not body or len(set(body)) == 1:
        return None
    # The word just ahead of the flags is another setting's bits and is written
    # wherever this layout is; zeroes there mean another structure behind the
    # same signature — a CSME 12 image's UEP partition — not four false flags.
    word = me[uep_at + UEP_WORD_OFFSET] | (me[uep_at + UEP_WORD_OFFSET + 1] << 8)
    if word in (0x0000, 0xFFFF):
        return None
    byte = me[uep_at + UEP_FLAGS_OFFSET]
    return (byte & 0x01 != 0, byte & 0x20 != 0, byte & 0x10 != 0, byte & 0x08 != 0)


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def descriptor(d):
    if len(d) < 0x1000 or u32(d, 0x10) != 0x0FF0A55A:
        return None
    flmap0, flmap1 = u32(d, 0x14), u32(d, 0x18)
    out = {"region_base": ((flmap0 >> 16) & 0xFF) << 4,
           "regions": {}, "bios_master": None}
    # The count byte (FLMAP0 >> 24) reads 0 on these descriptors, exactly as the
    # engine's parser found ("how many pairs the section holds is the
    # generation's"), so read the section's full 16 slots and keep the live ones.
    for i in range(1, 16):
        e = out["region_base"] + i * 4
        base, limit = u16(d, e) << 12, u16(d, e + 2)
        if limit and base < len(d):
            out["regions"][REGION_NAMES.get(i, str(i))] = (base, (limit << 12) + 0x1000)
    master_at = flmap1 & 0xFF
    if 0 < master_at <= 0xE0:
        w = u32(d, master_at << 4)
        read, write = (w >> 8) & 0xFFF, (w >> 20) & 0xFFF
        if read or write:
            out["bios_master"] = {"read": read, "write": write,
                                  "all_ones": read == 0xFFF and write == 0xFFF}
    return out


def config_table(me, start=0):
    """The OEM configuration's record table, found by its shape: a small count,
    then records {fileID, offset, flags} whose file IDs live in 0x10000000+ and
    whose offsets grow."""
    for p in range(start, len(me) - 32, 4):
        count = u32(me, p)
        if not 8 <= count <= 300:
            continue
        file_id, off = u32(me, p + 4), u32(me, p + 8)
        if not 0x10000000 <= file_id <= 0x2FFFFFFF or not count * 12 <= off <= 0x20000:
            continue
        if not 0x10000000 <= u32(me, p + 16) <= 0x2FFFFFFF:
            continue
        if u32(me, p + 20) < off:
            continue
        return p, count
    return None, 0


def config_tables(me, most=3):
    """Every table of that shape in the ME region — the OEM configuration is not
    the only one (an image may carry a second, ID-keyed set of records), so the
    reader picks rather than the script."""
    out, at = [], 0
    while len(out) < most:
        p, count = config_table(me, at)
        if p is None:
            break
        out.append((p, count))
        at = p + 4 + count * 12 + 0x400
    return out


def key_like(block):
    """High-entropy and not periodic: key material rather than a fill pattern."""
    if len(set(block)) < 16:
        return False
    if block[:16] == block[16:32] or block[16:32] == block[32:]:
        return False
    return True


def repeated_48(me, uep_at):
    """The 48-byte values the UEP area holds, and every copy of each in the ME
    region. The candidates come from the UEP — that is where the OEM key hash
    lives, and the report is about what repeats *there* — and each is counted over
    the whole region with bytes.count, which is C-speed; sliding a window over
    megabytes of Python is not."""
    out = {}
    for off in range(uep_at, min(uep_at + 0x2000, len(me)) - 48, 4):
        block = me[off:off + 48]
        if block in out or not key_like(block) or me.count(block) < 2:
            continue
        places, at = [], me.find(block)
        while at >= 0:
            places.append(at)
            at = me.find(block, at + 1)
        out[block] = places
    return out


def unshifted(values):
    """One value per piece of key material. The ME region pads key material with
    zeros, so a 48-byte window slid by 4 bytes matches the same copies — or a
    subset of them — and would be reported as a second value. Of the windows that
    overlap, keep the one with the most copies; it holds the whole key."""
    kept = {}
    cores = {block: block.strip(b"\x00") for block in values}
    # Most copies first; a tie goes to the window whose bytes hold the most of the
    # key, so the shorter shifts are then dropped as substrings of it.
    for block in sorted(values, key=lambda b: (-len(values[b]), -len(cores[b]))):
        core = cores[block]
        if not core or any(core in cores[other] for other in kept):
            continue
        kept[block] = values[block]
    return kept


def cdmd_records(me, window=None):
    """The JSON records of the CDMD configuration: one {"key": value} object per
    setting, short and printable. The block opens with the ASCII signature
    "FIT AS A FIDDLE"; the records are found by shape, so a dump whose block sits
    elsewhere is still read."""
    start, end = window if window else (0, len(me))
    out, at = [], start
    while at < end:
        open_at = me.find(b'{"', at, end)
        if open_at < 0:
            break
        at = open_at + 2
        close_at = me.find(b"}", open_at, min(open_at + 256, end))
        if close_at < 0:
            continue
        try:
            record = json.loads(me[open_at:close_at + 1].decode("ascii"))
        except (UnicodeDecodeError, ValueError):
            continue
        if not isinstance(record, dict) or not record:
            continue
        # The harness block in the same area is XML carrying a bare {"length": n};
        # it is metadata of the block, not a setting, and would drown the report.
        if set(record) <= {"length", "Length"}:
            continue
        out.append((open_at, record))
    return out


def report(path):
    with open(path, "rb") as handle:
        d = handle.read()
    print("== %s (%d bytes)" % (path, len(d)))
    desc = descriptor(d)
    if desc is None:
        print("descriptor: none")
        return
    master = desc["bios_master"]
    if master:
        print("descriptor: BIOS master read=0x%03X write=0x%03X (%s)"
              % (master["read"], master["write"],
                 "all ones — descriptor open" if master["all_ones"] else "locked"))
    else:
        print("descriptor: BIOS master not readable")
    me_range = desc["regions"].get("ME")
    if not me_range:
        print("ME region: none in the descriptor")
        return
    me_start, me_end = me_range
    me = d[me_start:me_end]
    print("ME region: 0x%X..0x%X" % (me_start, me_end))

    uep_at = -1
    for signature in (b"$UEPC", b"$UEP"):
        uep = me.find(signature)
        if uep < 0:
            print("UEP: no %s container in the ME region" % signature.decode())
            continue
        if signature == b"$UEP" and me[uep + 4:uep + 5] == b"C":
            continue          # the $UEPC container, already reported above
        # The four bytes behind the signature are the container's own header,
        # not a length: a 16-bit CRC of the data and two reserved bytes (the
        # `Uep` class of FIT's layout, reference/structures.md).
        head = me[uep + 4:uep + 8]
        span = me[uep:uep + 0x2000]
        print("UEP: %s at file 0x%X, header %s (CRC 0x%04X, reserved 0x%04X)"
              " — %.1f%% of the 8 KiB erased"
              % (signature.decode(), me_start + uep, head.hex(" ").upper(),
                 head[0] | (head[1] << 8) if len(head) >= 2 else 0,
                 head[2] | (head[3] << 8) if len(head) >= 4 else 0,
                 100.0 * span.count(0xFF) / 0x2000))
        uep_at = uep

    for payload, count in config_tables(me):
        print("OEM configuration table at file 0x%X: %d records"
              % (me_start + payload, count))
        ids = [u32(me, payload + 4 + i * 12) for i in range(count)]
        for file_id, (name, size) in sorted(EOM_FILES.items()):
            if file_id not in ids:
                print("  %-26s absent from the configuration" % name)
                continue
            i = ids.index(file_id)
            off = u32(me, payload + 4 + i * 12 + 4)
            flags = u32(me, payload + 4 + i * 12 + 8)
            value = me[payload + off: payload + off + size]
            print("  %-26s default %s  (offset 0x%X, flags 0x%08X)"
                  % (name, value.hex(" ").upper(), off, flags))

    keys = unshifted(repeated_48(me, uep_at)) if uep_at >= 0 else {}
    if not keys:
        print("48-byte values repeated in the ME region from the UEP: none")
    for block, offsets in sorted(keys.items(), key=lambda kv: -len(kv[1]))[:4]:
        where = "UEP" if 0 <= uep_at <= offsets[0] < uep_at + 0x2000 \
            else "ME region at 0x%X" % (me_start + offsets[0])
        print("48-byte value, %d copies (%s): %s"
              % (len(offsets), where, block.hex()))
        print("  at " + ", ".join("0x%X" % (me_start + o) for o in offsets[:12])
              + (" …" if len(offsets) > 12 else ""))

    # The key hash in the record the *generation* keeps. The script does not
    # identify the generation — the app does, and picks one record with it — so
    # both are printed: the 32-byte SHA-256 of CSME 12 to 14 at +0x90, the
    # 48-byte SHA-384 of 15 and later at +0xA0 (+0x10A0 for the second copy).
    for name, kind in (("CSME 12–14", "earlier"), ("CSME 15+", "later")):
        field = oem_key_field(me, uep_at, 14 if kind == "earlier" else 15)
        if field is None:
            print("OEM key hash (%s): no field — the area is shorter than it" % name)
            continue
        state = ("not set (all zeros)" if not any(field) else
                 "never written (all 0xFF)" if all(b == 0xFF for b in field) else
                 field.hex().upper())
        print("OEM key hash (%s, %d bytes): %s" % (name, len(field), state))

    signature_at = me.find(b"FIT AS A FIDDLE")
    window = (signature_at, signature_at + 0x8000) if signature_at >= 0 else None
    records = cdmd_records(me, window)
    if signature_at < 0:
        print("CDMD configuration: no \"FIT AS A FIDDLE\" signature in the ME region")
    else:
        print("CDMD configuration: signature at 0x%X, %d JSON records"
              % (me_start + signature_at, len(records)))
    for off, record in records:
        print("  at 0x%X: %s" % (me_start + off, json.dumps(record)))
    profile = None
    for off, record in records:
        if "BtGuardProfileConfig" in record:
            profile = record["BtGuardProfileConfig"]
    if profile is not None:
        print("Boot Guard profile: %s (index %s of the CDMD JSON)"
              % (BOOT_GUARD_PROFILES.get(profile, "unknown: %r" % profile), profile))
    else:
        print("Boot Guard profile: no BtGuardProfileConfig in the CDMD JSON"
              " — reading the UEP bits")
        flags = uep_boot_guard_flags(me, uep_at)
        if flags is None:
            print("  the UEP area carries no Boot Guard bit array here")
        else:
            print("  UEP Boot Guard bits: FBG ACM %d, verified %d, measured %d,"
                  " protect %d → %s"
                  % (flags + (BOOT_GUARD_FLAGS.get(flags,
                                                   "no profile names this combination"),)))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for argument in sys.argv[1:]:
        report(argument)
