#!/usr/bin/env python3
"""Build the IT83xx register and IRQ maps from Chromium EC's registers.h.

    python3 build_register_map.py <registers.h> <revision> <out-dir>

Reads `chip/it83xx/registers.h` (Chromium EC, BSD licence) as text and writes
two tables of our own: `it83xx-registers.tsv` (name, address, width, block,
description, source) and `it83xx-irqs.tsv` (irq, name, source). Only the
addresses and numbers are taken, never code. Where the header has a
family conditional, the IT8320 side is kept (the IT8227E/ITE8380 firmware
this map was first checked against is of that generation); any other
conditional keeps its first branch. A macro with parameters is skipped.
Stdlib only; a run is a diff to review.
"""
import re
import sys

# The INTC base comes from the chip's config, not registers.h.
EXTRA_BASES = {"CHIP_EC_INTC_BASE": 0x00F01100}


def main():
    header, revision, out = sys.argv[1], sys.argv[2], sys.argv[3]
    lines = open(header, encoding="utf-8").read().split("\n")
    bases = dict(EXTRA_BASES)
    keep = []          # stack of (taking, any_taken)
    registers, irqs = [], []
    seen_regs, seen_irqs = set(), set()
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if line.startswith("#if"):
            other = "IT8XXX" in line and "IT8320" not in line
            take = not other
            keep.append([take, take])
            continue
        if line.startswith("#elif"):
            top = keep[-1]
            take = (not top[1]) and ("IT8320" in line)
            top[0] = take
            top[1] = top[1] or take
            continue
        if line.startswith("#else"):
            top = keep[-1]
            top[0] = not top[1]
            top[1] = True
            continue
        if line.startswith("#endif"):
            if keep:
                keep.pop()
            continue
        if not all(k[0] for k in keep):
            continue
        m = re.match(r"#define\s+(\w+)\s+(\w+)\s*$", line)
        if m and m.group(2) in bases:
            bases[m.group(1)] = bases[m.group(2)]
            continue
        m = re.match(r"#define\s+(IT83XX_\w+_BASE)\s+(0x[0-9A-Fa-f]+)\b", line)
        if m:
            bases[m.group(1)] = int(m.group(2), 16)
            continue
        m = re.match(r"#define\s+IT83XX_IRQ_(\w+)\s+(\d+)\b", line)
        if m and m.group(1) != "COUNT":
            key = (int(m.group(2)), m.group(1))
            if key not in seen_irqs:
                seen_irqs.add(key)
                irqs.append((int(m.group(2)), m.group(1), "registers.h:%d" % number))
            continue
        m = re.match(r"#define\s+(IT83XX_\w+)\s+REG(8|16|32)\(\s*(\w+)\s*(?:\+\s*\(?\s*(0x[0-9A-Fa-f]+|\d+)\s*\)?)?\s*\)"
                     r"\s*(/\*(.*?)\*/)?\s*$", line)
        if m and m.group(3) in bases:
            address = bases[m.group(3)] + (int(m.group(4), 0) if m.group(4) else 0)
            block = m.group(3)[len("IT83XX_"):-len("_BASE")] if m.group(3).startswith("IT83XX_") else "INTC"
            name = m.group(1)[len("IT83XX_"):]
            if (name, address) in seen_regs:
                continue
            seen_regs.add((name, address))
            note = (m.group(6) or "").strip() or "-"
            registers.append((name, address, int(m.group(2)) // 8, block, note, "registers.h:%d" % number))
    head = ("# Our own table, built by Skills/ghidra-ec/scripts/build_register_map.py from\n"
            "# Chromium EC chip/it83xx/registers.h (BSD-style licence, The ChromiumOS Authors),\n"
            "# https://chromium.googlesource.com/chromiumos/platform/ec, mirror github.com/coreboot/chrome-ec,\n"
            "# revision %s.\n"
            "# Family conditionals: the IT8320 side. INTC base 0x00F01100 from the chip config\n"
            "# (CHIP_EC_INTC_BASE). `source` is the header's line.\n" % revision)
    registers.sort(key=lambda r: (r[1], r[0]))
    with open(out + "/it83xx-registers.tsv", "w", encoding="utf-8") as f:
        f.write(head + "# width is in bytes.\nname\taddress\twidth\tblock\tdescription\tsource\n")
        for name, address, width, block, note, source in registers:
            f.write("%s\t0x%08X\t%d\t%s\t%s\t%s\n" % (name, address, width, block, note.replace("\t", " "), source))
    irqs.sort()
    with open(out + "/it83xx-irqs.tsv", "w", encoding="utf-8") as f:
        f.write(head + "# The INTC interrupt numbers (IVCT - 0x10).\nirq\tname\tsource\n")
        for irq, name, source in irqs:
            f.write("%d\t%s\t%s\n" % (irq, name, source))
    print("registers %d, irqs %d" % (len(registers), len(irqs)))


if __name__ == "__main__":
    main()
