"""Emit CSME 18's MIP strap containers — CSME, IOE and PMC IOE — from MFIT 18.

The MIP table a CSME 18 image keeps in the FITC partition (`smip` nvar) is a
MIP descriptor of contiguous blocks, one per `MipDescNvar` child container. On
the dump at hand the block types are the tool's:

    type 1  PmcAndCpu    PMC_SoC straps, then the CPU message header and message
    type 2  PMC_IOE      PMC_IOE_smip
    type 4  IOE          IOE_smip
    type 0  CSME / DBC   CSME_smip

and a five-block MTL-P table adds a type 3 for `PmcAndCpu_2` (PMC_SOC_2 and
CPU_2). This script emits the layout of the three containers that are not the
CPU message — the harness documents' `mfit_data` blocks of

    <serialized_item name="IOE_smip_Strap_IOEP_PCIED_LNREV" type="BitfieldItem"
                     value="?($rvp == … ? 0x0 : …)" offset="0x0"
                     bit_low="0" bit_high="0"/>

with the panel's words in `ui_item`s and `bind_action`s. **The place is a bit
range of the block**: `offset*8 + bit_low … offset*8 + bit_high` — the
documents are byte-addressed (IOE's offsets are byte-granular; CSME's and
PMC IOE's happen to be dword-aligned), so the same conversion serves all.

The three platform documents place the fields alike; a name they place
differently is dropped and named. Values are per reference platform, so no
default is emitted.

Checked on the CSME 18 dump: the block lengths match the documents' extents
(PMC_IOE 0x40, IOE 0xD0, CSME 0x8), and every field whose document states one
value for every reference platform (`?($rvp == … ? 0x1 : … : 0x1)`) reads that
value — 249/249 in PMC_IOE, 5/5 in CSME, 443/448 in IOE (the five are board
values the reference list does not carry; the placement itself is the 63
fields whose value is a plain constant, all of them matching).

    python3 mip18_map.py <mfit-18.1.exe> --format json > \\
        Packages/MEFirmware/MapSources/layout/mip.json

The JSON is compiled into `LayoutMaps.bin` by `map_bin.py`
(`Design/MAP_DATA.md`).

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import hashlib
import json
import os
import re
import sys
import zlib

GENERATION = "18"

# name, document block, block type, field-name prefix, block length in bytes
# (nil = the fields' own extent), the container's offset in the block and its
# own length (nil = the block length). `PMC_SoC_smip` holds the CPU message
# header and the CPU fields too; the prefix keeps the PMC ones.
#
# The `PmcAndCpu_2` block (type 3, MTL-P / ARL-P only) is the same shape one
# size up: PMC_SOC_2's 0x48 bytes, then CPU_2's 0x18. No image at hand has a
# five-block table, so its type and length are the tool's struct defaults
# (`MipDescriptorHeader5Blocks`: 1, 2, 4, 3, 0) and the two documents'
# extents, not a dump reading.
CONTAINERS = [
    dict(name="PMC SoC", block="PMC_SoC_smip", type=1,
         prefix="PMC_SoC_smip_Strap_", block_length=0x58, length=0x48),
    dict(name="CSME", block="CSME_smip", type=0),
    dict(name="PMC IOE", block="PMC_IOE_smip", type=2),
    dict(name="IOE", block="IOE_smip", type=4),
    dict(name="PMC SOC 2", block="PMC_SOC_2_smip", type=3,
         prefix="PMC_SOC_2_smip_Strap_", block_length=0x60, length=0x48,
         ui_from="PMC_SoC_smip"),
    dict(name="CPU 2", block="CPU_2_smip", type=3, prefix="CPU_2_smip_Strap_",
         block_length=0x60, offset=0x48, length=0x18, ui_from="CPU_smip"),
]

# The IOE container has two layouts at hand — MTL-M's 0x3C bytes and MTL-P /
# ARL-P's 0xD0, which place the shared names at different offsets. A layout is
# chosen by the block's own length, which the MIP descriptor states.

TWO_KINDS = {
    "no_yes_options": {0: "No", 1: "Yes"},
    "yes_no_options": {0: "Yes", 1: "No"},
    "disabled_enabled_options": {0: "Disabled", 1: "Enabled"},
    "enabled_disabled_options": {0: "Enabled", 1: "Disabled"},
}

ITEM = re.compile(r'<serialized_item ([^>]*)/>')
UI = re.compile(r'<ui_item\s+name="([^"]+)"([^>]*)>')
BIND = re.compile(r'<bind_action\s+type="([^"]+)"\s+ui_controller="([^"]+)"\s+'
                  r'serialized_item="([^"]+)"')


def documents(blob):
    seen = set()
    for match in re.finditer(re.compile(rb"\x78[\x01\x5e\x9c\xda]"), blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 30_000_000])
        except Exception:
            continue
        if b'<mfit_data id="CSME_smip">' not in out:
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


def block_words(block):
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
    return words


def mfit_block(text, block_id):
    """A `<mfit_data id="…">` block's body, or None.

    Both tags are matched with tolerated spacing: the tools' writer does not
    always put the bracket straight after the name.
    """
    opening = re.search(r'<mfit_data\s+id="%s"[^>]*>' % re.escape(block_id), text)
    if not opening:
        return None
    closing = re.search(r'</mfit_data\s*>', text[opening.end():])
    if not closing:
        print("! %s: the block has no closing tag" % block_id, file=sys.stderr)
        return None
    return text[opening.end():opening.end() + closing.start()]


def account_block(block, where):
    """A tag the regexes did not read is a field nobody looked at."""
    stated = sum(1 for match in re.finditer(r'<serialized_item\b[^>]*>', block)
                 if 'type="BitfieldItem"' in match.group(0))
    matched = sum(1 for match in ITEM.finditer(block)
                  if 'type="BitfieldItem"' in match.group(0))
    if stated != matched:
        print("! %s: %d of %d <serialized_item> bitfields did not parse"
              % (where, stated - matched, stated), file=sys.stderr)
    for pattern, tag in ((UI, "ui_item"), (BIND, "bind_action")):
        if tag == "bind_action":
            # A master-access bind names a custom controller, and a
            # mapping bind names several items; neither is the plain
            # one-item form these scripts read.
            stated_tag = sum(1 for match in re.finditer(r'<bind_action\b[^>]*>', block)
                             if 'custom_ui_controller' not in match.group(0)
                             and 'type="mapping"' not in match.group(0))
        else:
            stated_tag = len(re.findall(r'<%s\b' % tag, block))
        matched_tag = sum(1 for _ in pattern.finditer(block))
        if stated_tag != matched_tag:
            print("! %s: %d of %d <%s> entries did not parse"
                  % (where, stated_tag - matched_tag, stated_tag, tag),
                  file=sys.stderr)


def fields_of(text, block_id, prefix=None, ui_from=None):
    block = mfit_block(text, block_id)
    if block is None:
        return []
    account_block(block, block_id)
    words = block_words(block)
    # A container may bind its fields to another container's interface text —
    # `ui_controller="$(ui_ref_container):HyperThreadingDisable"` — since the
    # layout gives it that container's UI (`ui_ref_container`).
    fallback = {}
    if ui_from:
        other = mfit_block(text, ui_from)
        if other is not None:
            fallback = block_words(other)
    binds = {item: controller for _, controller, item in BIND.findall(block)}
    fields = []
    for attrs in ITEM.findall(block):
        if attribute(attrs, "type") != "BitfieldItem":
            continue
        name = attribute(attrs, "name")
        offset = attribute(attrs, "offset")
        low, high = attribute(attrs, "bit_low"), attribute(attrs, "bit_high")
        if not (name and offset and low is not None and high is not None):
            continue
        if prefix and not name.startswith(prefix):
            continue
        start_bit = int(offset, 0) * 8 + int(low)
        count = int(high) - int(low) + 1
        controller = binds.get(name)
        if controller and controller.startswith("$(") and ":" in controller:
            controller = controller.split(":", 1)[1]
        entries = words.get(controller) or fallback.get(controller) or {}
        fields.append({
            "name": name,
            "start": start_bit,
            "count": count,
            "label": entries.get("label"),
            "section": entries.get("section"),
            "help": entries.get("help"),
            "options": entries.get("options"),
        })
    return fields


def merged(found):
    """The fields every document places alike."""
    total = len(found)
    counts, by_name = {}, {}
    for fields in found:
        for field in fields:
            kept = by_name.get(field["name"])
            if kept is None:
                by_name[field["name"]] = field
                counts[field["name"]] = 1
                continue
            if (kept["start"], kept["count"]) != (field["start"], field["count"]):
                counts[field["name"]] = -1
                continue
            counts[field["name"]] += 1
            for key in ("label", "section", "help"):
                if len(field[key] or "") > len(kept[key] or ""):
                    kept[key] = field[key]
            if kept["options"] is None:
                kept["options"] = field["options"]
    return [by_name[name] for name, n in counts.items() if n == total]


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(tool, containers):
    lines = [
        "// The CSME, PMC IOE and IOE strap containers of CSME %s's MIP table, as" % GENERATION,
        "// %s lays them out — emitted by" % tool,
        "// `Skills/me-eom-structures/scripts/mip18_map.py` from the tool's own",
        "// harness documents. Names, places, labels and option words are the",
        "// tool's; nothing here is read out of a dump, and no default is stated:",
        "// the values are per reference platform.",
        "//",
        "// A field's place is a bit range of its block (`offset*8 + bit_low …",
        "// + bit_high`), and the block's type is the one the MIP descriptor",
        "// states. The CPU message is a container of its own (`CPUStrapMap`).",
        "",
        "import Foundation",
        "",
        "extension MIPStrapMap {",
        "    /// The containers, as the tool lays them out.",
        "    public static let csme%s = MIPStrapMap(" % GENERATION,
        "        name: %s," % swift_literal("CSME %s (%s)" % (GENERATION, tool)),
        "        containers: [",
    ]
    for name, block_id, block_type, block_length, offset, length, fields in containers:
        lines.append("            Container(name: %s, blockType: %d, blockLength: 0x%X, "
                     "offset: 0x%X, length: 0x%X, fields: ["
                     % (swift_literal(name), block_type, block_length, offset, length))
        for field in fields:
            args = ["name: %s" % swift_literal(field["name"]),
                    "bitOffset: %d" % field["start"],
                    "count: %d" % field["count"]]
            if field["label"]:
                args.append("label: %s" % swift_literal(field["label"]))
            if field["section"]:
                args.append("section: %s" % swift_literal(field["section"]))
            if field["help"]:
                args.append("help: %s" % swift_literal(field["help"]))
            if field["options"]:
                pairs = ", ".join("%d: %s" % (number, swift_literal(word))
                                  for number, word in sorted(field["options"].items()))
                args.append("options: [%s]" % pairs)
            lines.append("                Field(%s)," % ", ".join(args))
        lines.append("            ]),")
    lines += ["        ])", "}", ""]
    return "\n".join(lines)


def pretty_json(document):
    """JSON with one field per line: a diff reads a field at a time."""
    lines = ["{"]
    for key in sorted(document):
        if key == "maps":
            continue
        lines.append(" %s: %s," % (
            json.dumps(key),
            json.dumps(document[key], ensure_ascii=False, sort_keys=True)))
    lines.append(' "maps": [')
    for map_index, mapping in enumerate(document["maps"]):
        rest = ", ".join(
            "%s: %s" % (json.dumps(key),
                        json.dumps(mapping[key], ensure_ascii=False, sort_keys=True))
            for key in sorted(mapping) if key != "containers")
        lines.append('  {%s, "containers": [' % rest)
        containers = mapping["containers"]
        for container_index, container in enumerate(containers):
            rest = ", ".join(
                "%s: %s" % (json.dumps(key),
                            json.dumps(container[key], ensure_ascii=False, sort_keys=True))
                for key in sorted(container) if key != "fields")
            lines.append('   {%s, "fields": [' % rest)
            fields = container["fields"]
            for field_index, field in enumerate(fields):
                lines.append("    %s%s" % (
                    json.dumps(field, ensure_ascii=False, sort_keys=True,
                               separators=(", ", ": ")),
                    "," if field_index + 1 < len(fields) else ""))
            lines.append('   ]}%s' % ("," if container_index + 1 < len(containers) else ""))
        lines.append('  ]}%s' % ("," if map_index + 1 < len(document["maps"]) else ""))
    lines.append(" ]")
    lines.append("}")
    return "\n".join(lines)


def json_document(tool, containers):
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "layout",
        "tool": tool,
        "maps": [{
            "id": "csme18-mip",
            "name": "CSME 18 (%s)" % tool,
            "layout": "mip",
            "containers": [{
                "name": name,
                "blockType": block_type,
                "blockLength": block_length,
                "offset": offset,
                "length": length,
                "fields": [{
                    "name": field["name"],
                    "bitOffset": field["start"],
                    "count": field["count"],
                    **({"label": field["label"]} if field["label"] else {}),
                    **({"section": field["section"]} if field["section"] else {}),
                    **({"help": field["help"]} if field["help"] else {}),
                    **({"options": [[number, word]
                                    for number, word in sorted(field["options"].items())]}
                       if field["options"] else {}),
                } for field in fields],
                "source": {"block": block_id, "tool": tool},
            } for name, block_id, block_type, block_length, offset, length, fields
               in containers],
        }],
    })


def main():
    args = sys.argv[1:]
    output_format = "swift"
    if "--format" in args:
        at = args.index("--format")
        output_format = args[at + 1]
        del args[at:at + 2]
    if output_format not in ("swift", "json"):
        print("--format is swift or json", file=sys.stderr)
        return 2
    args = [a for a in args if not a.startswith("-")]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    version = re.search(r"(\d+(?:\.\d+){1,3})", os.path.basename(path))
    tool = "Flash Image Tool %s" % (version.group(1) if version else os.path.basename(path))
    blob = open(path, "rb").read()
    docs = list(documents(blob))
    if not docs:
        print("no MIP strap documents found in this build", file=sys.stderr)
        return 1
    containers = []
    for spec in CONTAINERS:
        name = spec["name"]
        block_id = spec["block"]
        block_type = spec["type"]
        offset = spec.get("offset", 0)
        per_document = [fields for fields in
                        (fields_of(text, block_id, spec.get("prefix"),
                                   spec.get("ui_from")) for _, text in docs)
                        if fields]
        if not per_document:
            print("! %s: no fields in any document" % block_id, file=sys.stderr)
            continue
        # Layouts that place the fields identically are one table; IOE's
        # MTL-M and MTL-P documents place them differently and become one
        # table per block length.
        variants = {}
        for fields in per_document:
            extent = spec.get("block_length") or \
                max((f["start"] + f["count"] + 7) // 8 for f in fields)
            variants.setdefault(extent, []).append(fields)
        for extent in sorted(variants):
            found = variants[extent]
            fields = merged(found)
            fields.sort(key=lambda f: (f["start"], f["name"]))
            size = spec.get("length") or extent
            containers.append((name, block_id, block_type, extent, offset, size, fields))
            print("%s (%s, block type %d, block %d bytes, at 0x%X, %d bytes): "
                  "%d fields from %d document(s)"
                  % (name, block_id, block_type, extent, offset, size,
                     len(fields), len(found)), file=sys.stderr)
    print(json_document(tool, containers) if output_format == "json"
          else swift(tool, containers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
