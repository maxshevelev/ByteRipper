#!/usr/bin/env python3
"""Build the IT83xx register and IRQ maps from Chromium EC's registers.h.

    python3 build_register_map.py <registers.h> <revision> <out-dir>
    python3 build_register_map.py --overlay <reference-dir>

Reads `chip/it83xx/registers.h` (Chromium EC, BSD licence) as text and writes
two tables of our own: `it83xx-registers.tsv` (name, address, width, block,
description, source) and `it83xx-irqs.tsv` (irq, name, source). Only the
addresses and numbers are taken, never code. Where the header has a
family conditional, the IT8320 side is kept (the IT8227E/ITE8380 firmware
this map was first checked against is of that generation); any other
conditional keeps its first branch. A macro with parameters is skipped.

Every published entry is marked `unverified` (an IT8320 name nobody has
checked for IT8227E). Then the overlay `it8227e-overrides.tsv` beside the
output is applied: a `firmware` entry (derived from the IT8227E firmware's
code) removes every published entry at its address and takes its place; a
`published` entry with the same name and address only flips that entry's
status. Each removed entry is kept as a `# replaced:` comment line in the
output, so the history stays in the table.

The IRQ list is built the same way (`it83xx-irqs.tsv`: irq, name,
description, source, status) with its own overlay `it8227e-irq-overrides.tsv`
(irq, name, description, source, status, replaces): every published IRQ is
`unverified`; an overlay entry that is not `published` removes the published
entries at its number (`replaces` lists them; an entry may replace one of the
same name, to give it a description) and is kept as a `# replaced:` line.

`--overlay <reference-dir>` re-applies both overlays without registers.h: it
rebuilds the published part of each table from the existing file (its
published rows plus its `# replaced:` lines, statuses reset to
`unverified`) and keeps the table's header. Both modes give the same file.
Stdlib only; a run is a diff to review.
"""
import os
import re
import sys

# The INTC base comes from the chip's config, not registers.h.
EXTRA_BASES = {"CHIP_EC_INTC_BASE": 0x00F01100}


COLUMNS = "name\taddress\twidth\tblock\tdescription\tsource\tstatus\n"
STATUS_NOTE = ("# status: published = registers.h, confirmed for IT8227E; firmware = derived from the\n"
               "# IT8227E firmware's code (it8227e-overrides.tsv); unverified = an IT8320 name not checked\n"
               "# for IT8227E. `# replaced:` lines are published entries a firmware entry removed.\n")


def row_text(name, address, width, block, note, source, status):
    return "%s\t0x%08X\t%d\t%s\t%s\t%s\t%s" % (name, address, width, block, note.replace("\t", " "), source, status)


def read_overrides(path):
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or line.startswith("name\t"):
            continue
        r = line.split("\t")
        rows.append((r[0], int(r[1], 16), int(r[2]), r[3], r[4], r[5], r[6], r[7] if len(r) > 7 else "-"))
    return rows


def write_registers(out, head, published):
    """published: (name, address, width, block, note, source) rows."""
    overrides = read_overrides(os.path.join(out, "it8227e-overrides.tsv"))
    rows = [list(r) + ["unverified"] for r in published]
    replaced = []
    for name, address, width, block, note, source, status, replaces in overrides:
        if status == "published":
            hits = [r for r in rows if r[0] == name and r[1] == address]
            if not hits:
                sys.exit("override %s at 0x%X: no such published entry" % (name, address))
            for r in hits:
                r[6] = "published"
            continue
        gone = [r for r in rows if r[1] == address]
        listed = set(x for x in replaces.split(",") if x and x != "-")
        if listed != set(r[0] for r in gone):
            sys.exit("override %s at 0x%X: replaces %s, the map has %s"
                     % (name, address, sorted(listed), sorted(r[0] for r in gone)))
        for r in gone:
            rows.remove(r)
            replaced.append((r, name))
        rows.append([name, address, width, block, note, source, status])
    rows.sort(key=lambda r: (r[1], r[0]))
    replaced.sort(key=lambda x: (x[0][1], x[0][0]))
    with open(os.path.join(out, "it83xx-registers.tsv"), "w", encoding="utf-8") as f:
        f.write(head + STATUS_NOTE)
        for r, by in replaced:
            f.write("# replaced: %s\t(by %s)\n" % (row_text(*r[:6], "unverified"), by))
        f.write(COLUMNS)
        for r in rows:
            f.write(row_text(*r) + "\n")
    for r, by in replaced:
        print("replaced %s at 0x%08X by %s" % (r[0], r[1], by))
    counts = {}
    for r in rows:
        counts[r[6]] = counts.get(r[6], 0) + 1
    print("registers %d (%s)" % (len(rows), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))


IRQ_COLUMNS = "irq\tname\tdescription\tsource\tstatus\n"
IRQ_STATUS_NOTE = ("# status: published = registers.h, confirmed for IT8227E; firmware = derived from the\n"
                   "# IT8227E firmware's code (it8227e-irq-overrides.tsv); unverified = an IT8320 name not checked\n"
                   "# for IT8227E (its description may still be a fact from the firmware: its source says so).\n"
                   "# `# replaced:` lines are published entries an overlay entry removed.\n")


def irq_text(irq, name, note, source, status):
    return "%d\t%s\t%s\t%s\t%s" % (irq, name, note.replace("\t", " "), source, status)


def write_irqs(out, head, published):
    """published: (irq, name, note, source) rows."""
    overrides = []
    for line in open(os.path.join(out, "it8227e-irq-overrides.tsv"), encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or line.startswith("irq\t"):
            continue
        r = line.split("\t")
        overrides.append((int(r[0]), r[1], r[2], r[3], r[4], r[5] if len(r) > 5 else "-"))
    rows = [list(r) + ["unverified"] for r in published]
    replaced, added = [], []
    for irq, name, note, source, status, replaces in overrides:
        if status == "published":
            hits = [r for r in rows if r[0] == irq and r[1] == name]
            if not hits:
                sys.exit("irq override %s at %d: no such published entry" % (name, irq))
            for r in hits:
                r[4] = "published"
            continue
        gone = [r for r in rows if r[0] == irq]
        listed = set(x for x in replaces.split(",") if x and x != "-")
        if listed != set(r[1] for r in gone):
            sys.exit("irq override %s at %d: replaces %s, the list has %s"
                     % (name, irq, sorted(listed), sorted(r[1] for r in gone)))
        for r in gone:
            rows.remove(r)
            replaced.append((r, name))
        added.append([irq, name, note, source, status])
    rows += added
    rows.sort(key=lambda r: (r[0], r[1]))
    replaced.sort(key=lambda x: (x[0][0], x[0][1]))
    with open(os.path.join(out, "it83xx-irqs.tsv"), "w", encoding="utf-8") as f:
        f.write(head + IRQ_STATUS_NOTE)
        for r, by in replaced:
            f.write("# replaced: %s\t(by %s)\n" % (irq_text(*r[:4], "unverified"), by))
        f.write(IRQ_COLUMNS)
        for r in rows:
            f.write(irq_text(*r) + "\n")
    for r, by in replaced:
        print("replaced irq %d %s by %s" % (r[0], r[1], by))
    counts = {}
    for r in rows:
        counts[r[4]] = counts.get(r[4], 0) + 1
    print("irqs %d (%s)" % (len(rows), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))


def overlay_irqs(out):
    head, published = "", []
    for line in open(os.path.join(out, "it83xx-irqs.tsv"), encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("# replaced: "):
            r = line[len("# replaced: "):].split("\t")
            published.append((int(r[0]), r[1], r[2], r[3]))
        elif line.startswith("#"):
            head += line + "\n"
        elif line and not line.startswith("irq\t"):
            r = line.split("\t")
            if len(r) == 3:
                # A list from before the status column: irq, name, source.
                published.append((int(r[0]), r[1], "-", r[2]))
            elif r[3].startswith("registers.h:"):
                published.append((int(r[0]), r[1], r[2], r[3]))
    head = "".join(l + "\n" for l in head.split("\n") if l and l not in IRQ_STATUS_NOTE.split("\n"))
    published.sort(key=lambda r: (r[0], r[1]))
    write_irqs(out, head, published)


def overlay(out):
    head, published = "", []
    for line in open(os.path.join(out, "it83xx-registers.tsv"), encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("# replaced: "):
            r = line[len("# replaced: "):].split("\t")
            published.append((r[0], int(r[1], 16), int(r[2]), r[3], r[4], r[5]))
        elif line.startswith("#"):
            head += line + "\n"
        elif line and not line.startswith("name\t"):
            r = line.split("\t")
            if len(r) < 7 or r[6] != "firmware":
                published.append((r[0], int(r[1], 16), int(r[2]), r[3], r[4], r[5]))
    # The status note is written again by write_registers.
    head = "".join(l + "\n" for l in head.split("\n") if l and l not in STATUS_NOTE.split("\n"))
    published.sort(key=lambda r: (r[1], r[0]))
    write_registers(out, head, published)


def main():
    if sys.argv[1] == "--overlay":
        overlay(sys.argv[2])
        overlay_irqs(sys.argv[2])
        return
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
    write_registers(out, head + "# width is in bytes.\n", registers)
    irqs.sort()
    write_irqs(out, head + "# The INTC interrupt numbers (IVCT - 0x10).\n",
               [(irq, name, "-", source) for irq, name, source in irqs])


if __name__ == "__main__":
    main()
