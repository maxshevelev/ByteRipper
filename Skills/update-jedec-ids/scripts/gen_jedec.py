#!/usr/bin/env python3
"""Regenerate the SPI flash chip name table from the UEFITool repository.

Fetches common/descriptor.cpp from github.com/LongSoft/UEFITool (branch
new_engine) and rewrites one file in the ByteRipper tree:

  Packages/UEFIImage/Sources/UEFIImage/JedecIDs.swift

That file is what turns a JEDEC id out of a flash descriptor's VSCC table into
the name of a chip — "EF4019" into "Winbond W25Q256" — which is what the
descriptor's detail panel lists. The table is UEFITool's `jedecIdToUString`,
a `switch` of `case 0xEF4019: return UString("Winbond W25Q256");` lines grouped
by vendor, and this turns it into one Swift dictionary literal.

Run it from anywhere; the repository root is resolved relative to this file
(the skill lives at <repo>/Skills/update-jedec-ids/scripts/), or pass --repo to
point it elsewhere. --source reads a local descriptor.cpp instead of fetching.

Two more sources widen it, in this order of precedence after UEFITool:

  the Linux kernel's SPI-NOR tables (drivers/mtd/spi-nor/<vendor>.c, the files
  its Makefile lists, entries with a three-byte SNOR_ID and a name), then
  flashrom's per-vendor chip files (flashchips/*.c on branch main, the ids
  resolved through include/flashchips.h, SPI chips probed by plain RDID).

Only facts are read from them — the id, the part name, the size. The first
source that knows an id names it; the size is the first one any source lists.
--linux and --flashrom read a local checkout instead.

Stdlib only, and the run is a diff to review rather than a blind rewrite: it
prints how many chips it read and which vendors they came from, and writes the
file only when something changed.
"""

import argparse
import os
import re
import sys
import urllib.request

SOURCE_URL = (
    "https://raw.githubusercontent.com/LongSoft/UEFITool/new_engine/"
    "common/descriptor.cpp"
)
LINUX_RAW = "https://raw.githubusercontent.com/torvalds/linux/master/drivers/mtd/spi-nor/"
LINUX_VENDORS = {
    "atmel": "Atmel", "eon": "EON", "esmt": "ESMT", "everspin": "Everspin",
    "gigadevice": "GigaDevice", "intel": "Intel", "issi": "ISSI",
    "macronix": "Macronix", "micron-st": "Micron", "spansion": "Spansion",
    "sst": "SST", "winbond": "Winbond", "xmc": "XMC",
}
FLASHROM_RAW = "https://raw.githubusercontent.com/flashrom/flashrom/main/"
OUTPUT = "Packages/UEFIImage/Sources/UEFIImage/JedecIDs.swift"

CASE = re.compile(r'case\s+0x([0-9A-Fa-f]{6})\s*:\s*return\s+UString\("([^"]+)"\)')
VENDOR_COMMENT = re.compile(r"^\s*//\s*(.+?)\s*$")


def fetch(url):
    with urllib.request.urlopen(url) as response:
        return response.read().decode("utf-8")


def parse(source):
    """The switch's cases in file order, with the vendor comment above each run.

    Returns [(jedec_id, chip_name, vendor_heading)].
    """
    entries = []
    vendor = ""
    inside = False
    for line in source.splitlines():
        if "jedecIdToUString" in line:
            inside = True
            continue
        if not inside:
            continue
        if line.strip() == "}":
            break
        match = CASE.search(line)
        if match:
            entries.append((int(match.group(1), 16), match.group(2), vendor))
            continue
        comment = VENDOR_COMMENT.match(line)
        if comment and "//" in line and "case" not in line:
            vendor = comment.group(1)
    return entries


def flashrom_files(read):
    """The per-vendor files flashchips.c includes, and the header that names ids."""
    index = read("flashchips.c")
    names = re.findall(r'#include\s+"(flashchips/[A-Za-z0-9_]+\.c)"', index)
    return read("include/flashchips.h"), [read(name) for name in names]


def size_kb(expression):
    """A total_size such as `128 * 1024` — integers and `*` only."""
    if expression is None or not re.fullmatch(r"\s*\d+(\s*\*\s*\d+)*\s*", expression):
        return None
    product = 1
    for factor in expression.split("*"):
        product *= int(factor)
    return product or None


def parse_flashrom(header, sources):
    """{jedec_id: (name, size_kb)} for SPI chips probed by RDID, first entry wins."""
    defines = dict(re.findall(r"#define\s+(\w+)\s+(0x[0-9A-Fa-f]+|\d+)\b", header))

    def value(token):
        token = (token or "").strip()
        token = defines.get(token, token)
        try:
            return int(token, 0)
        except ValueError:
            return None

    found = {}
    for text in sources:
        for entry in re.finditer(r'\{\s*\.vendor\s*=\s*"([^"]*)",(.*?)\n\t\},', text, re.S):
            vendor, body = entry.group(1), entry.group(2)

            def field(key):
                match = re.search(r"\." + key + r"\s*=\s*([^,/]+)", body)
                return match.group(1).strip() if match else None

            if field("probe") != "PROBE_SPI_RDID" or "BUS_SPI" not in (field("bustype") or ""):
                continue
            maker, device = value(field("manufacture_id")), value(field("model_id"))
            name = re.search(r'\.name\s*=\s*"([^"]*)"', body)
            if maker is None or device is None or not name or vendor == "Unknown":
                continue
            full = name.group(1)
            if not full.startswith(vendor):
                full = vendor + " " + full
            found.setdefault(maker << 16 | device, (full, size_kb(field("total_size"))))
    return found


def linux_files(read):
    """{vendor file stem: source} for the manufacturers the kernel's Makefile builds."""
    makefile = read("Makefile")
    stems = re.findall(r"spi-nor-objs\s*\+=\s*([A-Za-z0-9_-]+)\.o", makefile)
    return {stem: read(stem + ".c") for stem in stems}


def linux_size_kb(expression):
    """A kernel `.size`: SZ_8M, SZ_512K, or integers joined by `*`."""
    expression = expression.strip()
    unit = re.fullmatch(r"SZ_(\d+)([KM])", expression)
    if unit:
        return int(unit.group(1)) * (1 if unit.group(2) == "K" else 1024)
    bytes_ = size_kb(expression)  # product of the factors, here in bytes
    return bytes_ // 1024 if bytes_ and bytes_ % 1024 == 0 else None


def parse_linux(files):
    """{jedec_id: (name, size_kb)} for entries with a 3-byte id and a name."""
    found = {}
    for stem, text in files.items():
        vendor = LINUX_VENDORS.get(stem, stem.replace("-", " ").title())
        for entry in re.split(r"\n\t\}(?:, \{)?", text):
            ident = re.search(r"\.id\s*=\s*SNOR_ID\(([^)]*)\)", entry)
            name = re.search(r'\.name\s*=\s*"([^"]+)"', entry)
            if not ident or not name:
                continue
            octets = [part.strip() for part in ident.group(1).split(",")]
            if len(octets) != 3 or not all(re.fullmatch(r"0x[0-9A-Fa-f]{1,2}", o) for o in octets):
                continue
            size = re.search(r"\.size\s*=\s*([^,]+),", entry)
            id_value = int(octets[0], 16) << 16 | int(octets[1], 16) << 8 | int(octets[2], 16)
            found.setdefault(id_value, (vendor + " " + name.group(1).upper(),
                                        linux_size_kb(size.group(1)) if size else None))
    return found


def merge(uefitool, linux, flashrom):
    """[(id, name, size_kb, source, vendor_heading)].

    The name is the first source's that knows the id (UEFITool, Linux, flashrom);
    the size is the first any of them lists, in the same order.
    """
    sized = [linux, flashrom]

    def size_of(id_value):
        for table in sized:
            size = table.get(id_value, (None, None))[1]
            if size is not None:
                return size
        return None

    merged = []
    seen = set()
    for id_value, name, heading in uefitool:
        if id_value in seen:
            continue
        seen.add(id_value)
        merged.append((id_value, name, size_of(id_value), "uefiTool", heading))
    for source, table in (("linux", linux), ("flashrom", flashrom)):
        for id_value in sorted(table):
            if id_value not in seen:
                seen.add(id_value)
                merged.append((id_value, table[id_value][0], size_of(id_value), source, source))
    return merged


def swift(entries):
    lines = [
        "import Foundation",
        "",
        "// GENERATED by the `update-jedec-ids` skill. Do not edit by hand: the next",
        "// regeneration overwrites it.",
        "//",
        "// Sources, in order of precedence when both know an id:",
        "//   1. `common/descriptor.cpp` of github.com/LongSoft/UEFITool, branch",
        "//      `new_engine` — the `jedecIdToUString` table.",
        "//   2. `drivers/mtd/spi-nor/<vendor>.c` of the Linux kernel, master (GPL-2.0)",
        "//      — the SPI-NOR tables, entries with a three-byte id and a name.",
        "//   3. `flashchips/*.c` of github.com/flashrom/flashrom, branch `main` — the",
        "//      SPI chips probed by RDID.",
        "// Each entry keeps the source its name came from. A size is the first that",
        "// any source lists, in the same order, also for an entry named by UEFITool.",
        "//",
        "// Licence: the kernel's tables and flashrom are GPL-2.0. What is taken from",
        "// them is facts — a JEDEC id, a vendor and part name, a capacity — which",
        "// are not a copyrightable expression; no code, comment or structure of",
        "// theirs is copied, only those values, restated in this table's own form.",
        "// The names are the vendors' own part numbers.",
        "//",
        "// What this holds: the name of the SPI flash chip a JEDEC id stands for.",
        "// A flash descriptor's VSCC table lists the chips the board's firmware was",
        "// built to drive, by id alone, and an id is not something a bench can read.",
        "// The descriptor's detail panel shows the name beside it.",
        "enum JedecIDs {",
        "    /// Where an entry's name was read from.",
        "    enum Source: Sendable {",
        "        case uefiTool, linux, flashrom",
        "    }",
        "",
        "    struct Chip: Equatable, Sendable {",
        "        var name: String",
        "        /// Capacity in kilobytes, when a source lists it.",
        "        var sizeKB: Int?",
        "        var source: Source",
        "    }",
        "",
        "    /// The chip a 24-bit JEDEC id names — vendor byte, then the two device",
        "    /// bytes — or nil for one this table does not know.",
        "    static func chip(of id: UInt32) -> Chip? { table[id] }",
        "",
        "    static func name(of id: UInt32) -> String? { table[id]?.name }",
        "",
        "    /// How many chips the table knows, for the test that the generated",
        "    /// file is the whole of its sources rather than a truncated read.",
        "    static var count: Int { table.count }",
        "",
        "    /// How many of them each source named.",
        "    static func count(from source: Source) -> Int {",
        "        table.values.filter { $0.source == source }.count",
        "    }",
        "",
        "    private static func c(_ name: String, _ sizeKB: Int?, _ source: Source) -> Chip {",
        "        Chip(name: name, sizeKB: sizeKB, source: source)",
        "    }",
        "",
        "    private static let table: [UInt32: Chip] = [",
    ]
    vendor = None
    for id_value, name, size, source, heading in entries:
        if heading != vendor:
            vendor = heading
            lines.append("        // " + vendor)
        lines.append('        0x%06X: c("%s", %s, .%s),' % (
            id_value, name.replace("\\", "\\\\").replace('"', '\\"'),
            "nil" if size is None else str(size), source))
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.abspath(os.path.join(here, "..", "..", ".."))

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=default_repo, help="the ByteRipper tree")
    parser.add_argument("--source", help="a local descriptor.cpp instead of fetching")
    parser.add_argument("--linux", help="a local drivers/mtd/spi-nor directory instead of fetching")
    parser.add_argument("--flashrom", help="a local flashrom checkout instead of fetching")
    args = parser.parse_args()

    source = (
        open(args.source, encoding="utf-8").read() if args.source else fetch(SOURCE_URL)
    )
    uefitool = parse(source)
    if args.flashrom:
        def read(name):
            with open(os.path.join(args.flashrom, name), encoding="utf-8") as handle:
                return handle.read()
    else:
        def read(name):
            return fetch(FLASHROM_RAW + name)
    if args.linux:
        def read_linux(name):
            with open(os.path.join(args.linux, name), encoding="utf-8") as handle:
                return handle.read()
    else:
        def read_linux(name):
            return fetch(LINUX_RAW + name)
    linux = parse_linux(linux_files(read_linux))
    if len(linux) < 100:
        print("read only %d Linux chips — the layout changed" % len(linux), file=sys.stderr)
        return 1
    header, files = flashrom_files(read)
    flashrom = parse_flashrom(header, files)
    if len(flashrom) < 200:
        print("read only %d flashrom chips — the layout changed" % len(flashrom),
              file=sys.stderr)
        return 1
    entries = merge(uefitool, linux, flashrom)
    if len(uefitool) < 100:
        print("read only %d chips — the switch was not found as expected" % len(uefitool),
              file=sys.stderr)
        return 1

    vendors = []
    for _, _, _, _, heading in entries:
        if heading not in vendors:
            vendors.append(heading)
    named = {source: sum(1 for e in entries if e[3] == source)
             for source in ("uefiTool", "linux", "flashrom")}
    print("%d chips (%d UEFITool, %d Linux, %d flashrom) from %d vendors: %s" % (
        len(entries), named["uefiTool"], named["linux"], named["flashrom"], len(vendors),
        ", ".join(vendors)))

    path = os.path.join(args.repo, OUTPUT)
    rendered = swift(entries)
    if os.path.exists(path) and open(path, encoding="utf-8").read() == rendered:
        print("%s is already up to date" % OUTPUT)
        return 0
    with open(path, "w", encoding="utf-8") as out:
        out.write(rendered)
    print("wrote %s" % OUTPUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
