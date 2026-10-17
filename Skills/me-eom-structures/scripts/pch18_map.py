"""Emit CSME 18's descriptor strap-section layout from MFIT 18's `SoC` block.

On Meteor Lake the descriptor's **PCH strap section** — the words `FLMAP1`
places and counts (130 of them on the dump at hand) — is the SoC soft-strap
block: MFIT 18's layout puts `PlatformSoftStraps name="SoC"` at offset 0x100,
and the harness documents carry its fields as `mfit_data id="SoC"`:

    <serialized_item name="SoC_Strap_PCIE0_LNREV" type="BitfieldItem"
                     value="?($rvp == … ? 0x0 : …)" offset="0x0"
                     bit_low="0" bit_high="0"/>
    <ui_item name="PCIeController3Config" config_type="fixed_options"
             label="PCIe Controller 3 (Port 9-12)" section="PciePortConfiguration"
             config_params="{'1x4': '0x0', '1x4 Lane Reversed': '0x1'}"/>
    <bind_action type="get_value" ui_controller="PCIeController3Config"
                 serialized_item="SoC_Strap_PCIE2_LNREV"/>

**The offset is a byte and the bits count from that byte's least significant
bit**, so a field's place in the section is the bit range
`offset*8 + bit_low … offset*8 + bit_high` — not the dword at `offset`. A field
that crosses a 32-bit word boundary (the byte-wide MPPHY PIPE configs and the
CSME SMT IDs) does not fit `DescriptorStrapMap`'s one-word field and is left
out, counted on stderr.

The three platform documents (`mtl_arl_p_a0`, `mtl_m`, `mtl_p`) place 1197
fields alike and add one or two of their own; the table keeps the shared ones,
as the processor tables do. Values are per reference platform, so no default
is emitted.

    python3 pch18_map.py <mfit-18.1.exe> > \\
        Packages/UEFIImage/Sources/UEFIImage/StrapMap+PCH18.swift

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import hashlib
import os
import re
import sys
import zlib

SECTION_WORDS = 130
TWO_KINDS = {
    "no_yes_options": {0: "No", 1: "Yes"},
    "yes_no_options": {0: "Yes", 1: "No"},
    "disabled_enabled_options": {0: "Disabled", 1: "Enabled"},
    "enabled_disabled_options": {0: "Enabled", 1: "Disabled"},
}

ITEM = re.compile(r'<serialized_item ([^>]*)/>')
UI = re.compile(r'<ui_item name="([^"]+)"([^>]*)>')
BIND = re.compile(r'<bind_action type="([^"]+)" ui_controller="([^"]+)" '
                  r'serialized_item="([^"]+)"')


def documents(blob):
    """Every document that carries an SoC block with fields, once each."""
    seen = set()
    for match in re.finditer(re.compile(rb"\x78[\x01\x5e\x9c\xda]"), blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 30_000_000])
        except Exception:
            continue
        if b'<mfit_data id="SoC">' not in out:
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        yield digest, out.decode("utf-8", "replace")


def unescaped(text):
    if not text:
        return text
    for entity, character in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'),
                              ("&apos;", "'"), ("&amp;", "&")):
        text = text.replace(entity, character)
    text = re.sub(r"&#(x?[0-9a-fA-F]+);",
                  lambda m: chr(int(m.group(1)[1:], 16) if m.group(1)[:1] in "xX"
                                else int(m.group(1))), text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    return re.sub(r"\r\n?", "\n", text).strip()


def attribute(attrs, name):
    found = re.search(r'\b%s="([^"]*)"' % name, attrs)
    return found.group(1) if found else None


def options_of(kind, params):
    if kind in TWO_KINDS:
        return TWO_KINDS[kind]
    if kind != "fixed_options" or not params:
        return None
    table = {}
    for label, number in re.findall(r"'([^']*)'\s*:\s*'([^']*)'", params):
        try:
            table[int(number, 0)] = label
        except ValueError:
            continue
    return table or None


def fields_of(text):
    """The SoC block's fields: name, word/bits in the section, panel words."""
    start = text.find('<mfit_data id="SoC">')
    end = text.find('</mfit_data>', start)
    block = text[start:end]
    words = {}
    for match in UI.finditer(block):
        name, attrs = match.group(1), match.group(2)
        words[name] = {
            "label": unescaped(attribute(attrs, "label")),
            "section": unescaped(attribute(attrs, "section")),
            "help": unescaped(attribute(attrs, "help_text")),
            "options": options_of(attribute(attrs, "config_type"),
                                  attribute(attrs, "config_params")),
        }
    binds = {item: controller for _, controller, item in BIND.findall(block)}
    fields, crossings = [], 0
    for attrs in ITEM.findall(block):
        if attribute(attrs, "type") != "BitfieldItem":
            continue
        name = attribute(attrs, "name")
        offset = attribute(attrs, "offset")
        low, high = attribute(attrs, "bit_low"), attribute(attrs, "bit_high")
        if not (name and offset and low is not None and high is not None):
            continue
        start_bit = int(offset, 0) * 8 + int(low)
        end_bit = int(offset, 0) * 8 + int(high)
        if end_bit // 32 != start_bit // 32:
            crossings += 1
            continue
        entries = words.get(binds.get(name), {})
        fields.append({
            "name": name,
            "start": start_bit,
            "end": end_bit,
            "word": start_bit // 32,
            "bits": (start_bit % 32, end_bit % 32),
            "label": entries.get("label"),
            "section": entries.get("section"),
            "help": entries.get("help"),
            "options": entries.get("options"),
        })
    return fields, crossings


def merged(documents_found):
    """The fields every document places alike; a disagreement is dropped."""
    counts = {}
    by_name = {}
    for _, fields in documents_found:
        for field in fields:
            key = (field["start"], field["end"])
            kept = by_name.get(field["name"])
            if kept is None:
                by_name[field["name"]] = field
                counts[field["name"]] = 1
                continue
            if (kept["start"], kept["end"]) != key:
                counts[field["name"]] = -1
                continue
            counts[field["name"]] += 1
            for name in ("label", "section", "help"):
                if len(field[name] or "") > len(kept[name] or ""):
                    kept[name] = field[name]
            if kept["options"] is None:
                kept["options"] = field["options"]
    total = len(documents_found)
    return [field for name, field in by_name.items() if counts[name] == total]


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(tool, fields):
    lines = [
        "// The %d-word descriptor strap section of CSME 18, field by field, as" % SECTION_WORDS,
        "// %s lays it out — emitted by" % tool,
        "// `Skills/me-eom-structures/scripts/pch18_map.py` from the tool's own",
        "// `SoC` harness block. Names, places, labels and option words are the",
        "// tool's; nothing here is read out of a dump.",
        "//",
        "// On Meteor Lake the section `FLMAP1` places at 0x100 and counts is the",
        "// SoC soft-strap block (`PlatformSoftStraps name=\"SoC\"`), whose fields",
        "// are byte-addressed: a field's place is the bit range",
        "// `offset*8 + bit_low … offset*8 + bit_high`, and the table states it as",
        "// the word and bits of the section. Values are per reference platform, so",
        "// no default is emitted. `StrapMap.swift` says what a table is.",
        "",
        "import Foundation",
        "",
        "extension DescriptorStrapMap {",
        "    /// The %d-word section, as the tool lays out its SoC straps." % SECTION_WORDS,
        "    public static let pch%d = DescriptorStrapMap(" % SECTION_WORDS,
        "        name: %s," % swift_literal(
            "%s, SoC straps, %d words" % (tool, SECTION_WORDS)),
        "        words: %d," % SECTION_WORDS,
        "        fields: [",
    ]
    for field in fields:
        bits = field["bits"]
        lower, upper = bits
        args = ["name: %s" % swift_literal(field["name"]),
                "word: %d" % field["word"],
                "bits: %d...%d" % (lower, upper)]
        if field["label"]:
            args.append("label: %s" % swift_literal(field["label"]))
        if field["options"]:
            pairs = ", ".join("%d: %s" % (number, swift_literal(word))
                              for number, word in sorted(field["options"].items()))
            args.append("options: [%s]" % pairs)
        lines.append("            Field(%s)," % ", ".join(args))
    lines += ["        ])", "}", ""]
    return "\n".join(lines)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    version = re.search(r"(\d+(?:\.\d+){1,3})", os.path.basename(path))
    tool = "Flash Image Tool %s" % (version.group(1) if version else os.path.basename(path))
    blob = open(path, "rb").read()
    documents_found = []
    crossings = 0
    for digest, text in documents(blob):
        fields, skipped = fields_of(text)
        if not fields:
            continue
        documents_found.append((digest, fields))
        crossings = max(crossings, skipped)
        print("document %s: %d fields, %d crossing a word boundary"
              % (digest[:8], len(fields), skipped), file=sys.stderr)
    if not documents_found:
        print("no SoC strap block found in this build", file=sys.stderr)
        return 1
    fields = merged(documents_found)
    fields.sort(key=lambda f: (f["word"], f["bits"][0], f["name"]))
    print("fields: %d of %d names, %d left out (a word-boundary crossing)"
          % (len(fields), len({f["name"] for _, s in documents_found for f in s}),
             crossings), file=sys.stderr)
    print(swift(tool, fields))
    return 0


if __name__ == "__main__":
    sys.exit(main())
