"""Emit the CPU strap message's layout from an MFIT build's own documents.

From Tiger Point on the descriptor no longer carries a processor strap
section: its third map word names the strap **message** in the descriptor's
MIP area instead — `FLMAP2` bits 2–11 are the offset from `0xC00`, bits 16–23
the length in words (`Design/UEFI/UEFI_IMAGE_FORMAT.md` §2.7) — and MFIT lays
that message out as the entries of its `CpuStrapsLayout` class:

    <LayoutEntry name="CPU_Strap_SMT_Disable" type="bitfield32" offset="0x00"
                 bitfield_high="0" bitfield_low="0">
      <UI source="$CpuStraps/HyperThreadingDisable" config_type="no_yes_options"
          label="Disable Hyperthreading" help_text="…" />
    </LayoutEntry>

The `<UI>` element gives the tool's own label and its option words; the
entry's `offset` is into the message, the bits counted in the word there.

**No defaults.** The values are stated per reference platform (`<Values>`,
one `rvp` each), not as a value the tool builds with, so a table emitted here
carries none and the panel emphasises no field of it.

Tables are keyed by the message's length, which is what a dump states
(`CSSL`). The documents are per harness project and do not all carry the same
fields, so a table keeps only the fields **every** document of that length
states alike — the same name at the same offset and bits — as
`strap_map.py --kind cpu` does for the older sections.

    python3 mip_strap_map.py <mfit.exe> > \\
        Packages/UEFIImage/Sources/UEFIImage/StrapMap+MIP.swift

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import hashlib
import os
import re
import sys
import zlib

TWO_KINDS = {
    "no_yes_options": {0: "No", 1: "Yes"},
    "yes_no_options": {0: "Yes", 1: "No"},
    "disabled_enabled_options": {0: "Disabled", 1: "Enabled"},
    "enabled_disabled_options": {0: "Enabled", 1: "Disabled"},
}

CLASS = re.compile(r'<Class name="CpuStrapsLayout".*?</Class>', re.S)
ENTRY = re.compile(
    r'<LayoutEntry name="([^"]+)" type="bitfield32" offset="([^"]+)" '
    r'bitfield_high="(\d+)" bitfield_low="(\d+)">(.*?)</LayoutEntry>', re.S)


def documents(blob):
    """Every document in the executable that holds the class, once each."""
    seen = set()
    for match in re.finditer(re.compile(rb"\x78[\x01\x5e\x9c\xda]"), blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 20_000_000])
        except Exception:
            continue
        if b"CpuStrapsLayout" not in out:
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        text = out.decode("utf-8", "replace")
        for block in CLASS.findall(text):
            yield digest, block


def options_of(ui):
    kind = re.search(r'config_type="([^"]*)"', ui)
    kind = kind.group(1) if kind else None
    if kind in TWO_KINDS:
        return TWO_KINDS[kind]
    if kind != "fixed_options":
        return None
    params = re.search(r"config_params=\"(\{.*?\})\"", ui, re.S)
    if not params:
        return None
    table = {}
    for label, number in re.findall(r"'([^']*)'\s*:\s*'([^']*)'", params.group(1)):
        try:
            table[int(number, 0)] = label
        except ValueError:
            continue
    return table or None


def fields_of(block):
    fields = []
    for name, offset, high, low, inner in ENTRY.findall(block):
        ui = re.search(r"<UI\b[^>]*>", inner)
        ui = ui.group(0) if ui else ""
        label = re.search(r'\blabel="([^"]*)"', ui)
        fields.append({
            "name": name,
            "offset": int(offset, 16) if offset.startswith("0x") else int(offset),
            "low": int(low), "high": int(high),
            "label": label.group(1) if label else None,
            "options": options_of(ui),
        })
    return fields


def tables(blob, tool):
    found = []
    for digest, block in documents(blob):
        fields = fields_of(block)
        if not fields:
            continue
        words = max(field["offset"] for field in fields) // 4 + 1
        found.append({"words": words, "fields": fields, "digest": digest, "tool": tool})
    return found


def agreed(matches):
    """The fields every document of one length states alike, with whatever a
    document says about them (label, option words) kept."""
    shared = None
    for table in matches:
        keys = {(f["name"], f["offset"], f["low"], f["high"]) for f in table["fields"]}
        shared = keys if shared is None else shared & keys
    by_key = {}
    for table in matches:
        for field in table["fields"]:
            key = (field["name"], field["offset"], field["low"], field["high"])
            if key not in (shared or set()):
                continue
            kept = by_key.setdefault(key, {**field, "label": None, "options": None})
            kept["label"] = kept["label"] or field["label"]
            kept["options"] = kept["options"] or field["options"]
    return sorted(by_key.values(), key=lambda f: (f["offset"], f["low"], f["name"]))


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def swift(tool, chosen):
    lines = [
        "// The CPU strap message's layout, as Intel's Flash Image Tool lays it out",
        "// — emitted by `Skills/me-eom-structures/scripts/mip_strap_map.py` from the",
        "// tool's own documents. Names, offsets, bits, labels and option words are the",
        "// tool's; nothing here is read out of a dump, and no default is stated: the",
        "// documents give values per reference platform, not a value the tool builds",
        "// with.",
        "//",
        "// From Tiger Point on this is where a descriptor's processor straps are — the",
        "// message in the MIP area at `0xC00 + FLMAP2[2:11]`, `FLMAP2[16:23]` words",
        "// long (`Design/UEFI/UEFI_IMAGE_FORMAT.md` §2.7). A table is picked by that",
        "// length. A field the documents of one length state differently is left out.",
        "",
        "import Foundation",
        "",
        "extension DescriptorStrapMap {",
    ]
    for words, table in chosen:
        lines.append("    /// The %d-word message, as %s lays it out." % (words, tool))
        lines.append("    public static let mipCpu%d = DescriptorStrapMap(" % words)
        lines.append("        name: %s," % swift_literal(
            "Flash Image Tool %s, MIP CPU straps, %d words" % (tool, words)))
        lines.append("        words: %d," % words)
        lines.append("        fields: [")
        for field in table:
            args = ["name: %s" % swift_literal(field["name"]),
                    "word: %d" % (field["offset"] // 4),
                    "bits: %d...%d" % (field["low"], field["high"])]
            if field["label"]:
                args.append("label: %s" % swift_literal(field["label"]))
            if field["options"]:
                pairs = ", ".join("%d: %s" % (number, swift_literal(word))
                                  for number, word in sorted(field["options"].items()))
                args.append("options: [%s]" % pairs)
            lines.append("            Field(%s)," % ", ".join(args))
        lines.append("        ])")
    lines.append("}")
    return "\n".join(lines)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__)
        return 2
    tool = "MFIT"
    version = re.search(r"(\d+(?:\.\d+){2,3})", os.path.basename(args[0]))
    if version:
        tool = version.group(1)
    blob = open(args[0], "rb").read()
    available = tables(blob, tool)
    by_length = {}
    for table in available:
        by_length.setdefault(table["words"], []).append(table)
    chosen = []
    for words in sorted(by_length):
        merged = agreed(by_length[words])
        chosen.append((words, merged))
        print("CPU strap message of %d words: %d fields from %d document(s) (%s)"
              % (words, len(merged), len(by_length[words]),
                 ", ".join(t["digest"][:8] for t in by_length[words])), file=sys.stderr)
    print(swift(tool, chosen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
