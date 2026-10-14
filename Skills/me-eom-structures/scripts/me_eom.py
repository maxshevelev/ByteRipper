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
    partition table, whose IFWI layout this script does not parse.
  * the UEP area opens with the ASCII "$UEPC" and mirrors the OEM key hashes.
  * a 48-byte value that repeats across the ME region and is not periodic is key
    material — the OEM public key hash is a SHA-384 (48 bytes). Heuristic.

Not understood yet (do not guess in a report): which field carries the Boot
Guard level (MFIT prints "BG0 … BG5"), and what the UEP entry fields mean (a
window in the BIOS region, a 0x4FE/0xFE field, a 32-bit sum).
"""

import struct
import sys

REGION_NAMES = {0: "Descriptor", 1: "BIOS", 2: "ME", 3: "GbE", 4: "PDR",
                5: "DevExp1", 6: "BIOS2", 7: "Microcode", 8: "EC", 9: "DevExp2",
                10: "IE", 11: "10GbE1", 12: "10GbE2", 13: "Rsvd1", 14: "Rsvd2",
                15: "PTT"}

EOM_FILES = {0x10020000: ("/home/mca/eom", 1),
             0x1001EE00: ("/home/mca/eom_config", 2),
             0x10020100: ("/home/mca/manuf_lock", 1)}


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


def repeated_48(me):
    seen, hits = {}, {}
    for off in range(0, len(me) - 48, 4):
        block = bytes(me[off:off + 48])
        if not key_like(block):
            continue
        seen[block] = seen.get(block, 0) + 1
        hits.setdefault(block, []).append(off)
    return {b: a for b, a in hits.items() if seen[b] > 1}


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
        size = u32(me, uep + len(signature)) if uep + len(signature) + 4 <= len(me) else 0
        span = me[uep:uep + 0x2000]
        print("UEP: %s at file 0x%X, declared size 0x%X — %.1f%% of the 8 KiB erased"
              % (signature.decode(), me_start + uep, size,
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

    keys = repeated_48(me)
    # Only values with a copy inside the UEP: that area holds the OEM key hash and
    # its neighbours, and it is what keeps the compressed-data repeats out.
    keys = {b: o for b, o in keys.items()
            if uep_at >= 0 and any(uep_at <= x < uep_at + 0x2000 for x in o)}
    if not keys:
        print("repeated 48-byte values with a copy in the UEP: none")
    for block, offsets in sorted(keys.items(), key=lambda kv: -len(kv[1]))[:8]:
        where = "UEP" if 0 <= uep_at <= offsets[0] < uep_at + 0x2000 \
            else "ME region at 0x%X" % (me_start + offsets[0])
        print("repeated 48-byte value, %d copies (%s): %s"
              % (len(offsets), where, block.hex()))
        print("  at " + ", ".join("0x%X" % (me_start + o) for o in offsets[:12])
              + (" …" if len(offsets) > 12 else ""))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for argument in sys.argv[1:]:
        report(argument)
