"""Emit CSME 18's SPHY OEM configuration nvar layout from MFIT 18.

The SPHY nvar is the file `phy_oem_cfg` (`/home/bup/phy_oem_cfg`, FileID
0x1001F200) — a PHY OEM configuration block in the FITC partition. MFIT 18
carries its layout as `mfit_data id="SphyNvar"`, a serialized item per field:

    <serialized_item name="SPHY_OEM_NVAR_Common_Header_1" type="DataBitfield"
                     config_type="int" offset="0" bitfield_high="31"
                     bitfield_low="0" value="0x0003" />

A field's place is `offset*8 + bitfield_low … offset*8 + bitfield_high`; a
`ValidByte`/`EnableBit` takes the byte at `offset`.

**The package carries more than one SPHY layout** (522, 542 and 967 fields and
an API-table variant), and the nvar's header does not name which one an image
was built with. The one this script emits is the layout the CSME 18 dump
verifies — all 522 of its constant values read exactly in the image's nvar.
The other 522-shared fields are placed alike in the 542-field variant; the two
differ in value in exactly one field (`Sub_Section_Entry2_Header_8`, 0x5 here
and 0x19 there), so that field and the common header are emitted as **anchors**
and the reader refuses an nvar whose anchors do not hold — an image of the
other variant answers nothing rather than wrong names.

    python3 sphy18_map.py <mfit-18.1.exe> --format json > \\
        Packages/MEFirmware/MapSources/layout/sphy.json

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

ANCHOR_NAMES = [
    "SPHY_OEM_NVAR_Common_Header_1",
    "SPHY_OEM_NVAR_Common_Header_2",
    "SPHY_OEM_NVAR_Common_Header_3",
    "SPHY_OEM_NVAR_Common_Header_4",
    "SPHY_OEM_NVAR_Common_Header_5",
    "SPHY_OEM_NVAR_Common_Header_6",
    "Sub_Section_Entry2_Header_8",
]

ITEM = re.compile(r"<serialized_item\b[^>]*>", re.S)


def documents(blob):
    seen = set()
    for match in re.finditer(re.compile(rb"\x78[\x01\x5e\x9c\xda]"), blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 30_000_000])
        except Exception:
            continue
        if b'<mfit_data id="SphyNvar">' not in out:
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        yield digest, out.decode("utf-8", "replace")


def attribute(attrs, name):
    found = re.search(r'\b%s\s*=\s*"([^"]*)"' % name, attrs)
    return found.group(1) if found else None


def mfit_block(text, block_id):
    """A `<mfit_data id="…">` block's body, or None."""
    opening = re.search(r'<mfit_data\s+id="%s"[^>]*>' % re.escape(block_id), text)
    if not opening:
        return None
    closing = re.search(r'</mfit_data\s*>', text[opening.end():])
    if not closing:
        print("! %s: the block has no closing tag" % block_id, file=sys.stderr)
        return None
    return text[opening.end():opening.end() + closing.start()]


def fields_of(text):
    block = mfit_block(text, "SphyNvar")
    if block is None:
        return []
    stated = len(re.findall(r'<serialized_item\b[^>]*>', block))
    matched = len(ITEM.findall(block))
    if stated != matched:
        print("! SphyNvar: %d of %d <serialized_item> entries did not parse"
              % (stated - matched, stated), file=sys.stderr)
    fields = []
    for tag in ITEM.findall(block):
        name = attribute(tag, "name")
        offset = attribute(tag, "offset")
        value = attribute(tag, "value")
        if not (name and offset and value):
            continue
        low = attribute(tag, "bitfield_low")
        high = attribute(tag, "bitfield_high")
        try:
            start_bit = int(offset, 0) * 8 + (int(low) if low else 0)
            count = (int(high) - int(low) + 1) if low and high else 8
        except ValueError:
            continue
        constant = re.fullmatch(r"0x[0-9A-Fa-f]+", value.strip())
        fields.append({
            "name": name,
            "bitOffset": start_bit,
            "count": count,
            "constant": int(value, 16) if constant else None,
        })
    return fields


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def swift(tool, fields):
    lines = [
        "// The SPHY OEM configuration nvar (`phy_oem_cfg`) of CSME 18, as",
        "// %s lays it out — emitted by" % tool,
        "// `Skills/me-eom-structures/scripts/sphy18_map.py` from the tool's own",
        "// `SphyNvar` document. Names and places are the tool's; nothing here is",
        "// read out of a dump.",
        "//",
        "// The other SPHY variants the package carries place the shared fields",
        "// alike and differ in one anchor value (`Sub_Section_Entry2_Header_8`),",
        "// which is why the map states anchors: an nvar that does not hold them",
        "// is another variant and is not read.",
        "",
        "import Foundation",
        "",
        "extension SphyNvarMap {",
        "    /// The layout, as the tool states it.",
        "    public static let csme%s = SphyNvarMap(" % "18",
        "        name: %s," % swift_literal("CSME 18 (%s)" % tool),
        "        anchors: [",
    ]
    for field in fields:
        if field["name"] not in ANCHOR_NAMES or field["constant"] is None:
            continue
        lines.append("            Anchor(name: %s, bitOffset: %d, count: %d, value: 0x%X),"
                     % (swift_literal(field["name"]), field["bitOffset"],
                        field["count"], field["constant"]))
    lines.append("        ],")
    lines.append("        fields: [")
    for field in fields:
        lines.append("            Field(name: %s, bitOffset: %d, count: %d),"
                     % (swift_literal(field["name"]), field["bitOffset"],
                        field["count"]))
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
            for key in sorted(mapping) if key not in ("anchors", "fields"))
        lines.append('  {%s, "anchors": [' % rest)
        anchors = mapping["anchors"]
        for anchor_index, anchor in enumerate(anchors):
            lines.append("   %s%s" % (
                json.dumps(anchor, ensure_ascii=False, sort_keys=True,
                           separators=(", ", ": ")),
                "," if anchor_index + 1 < len(anchors) else ""))
        lines.append('  ], "fields": [')
        fields = mapping["fields"]
        for field_index, field in enumerate(fields):
            lines.append("   %s%s" % (
                json.dumps(field, ensure_ascii=False, sort_keys=True,
                           separators=(", ", ": ")),
                "," if field_index + 1 < len(fields) else ""))
        lines.append('  ]}%s' % ("," if map_index + 1 < len(document["maps"]) else ""))
    lines.append(" ]")
    lines.append("}")
    return "\n".join(lines)


def json_document(tool, digest, fields):
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "layout",
        "tool": tool,
        "maps": [{
            "id": "csme18-sphy",
            "name": "CSME 18 (%s)" % tool,
            "layout": "sphy",
            "anchors": [{
                "name": field["name"],
                "bitOffset": field["bitOffset"],
                "count": field["count"],
                "value": field["constant"],
            } for field in fields
               if field["name"] in ANCHOR_NAMES and field["constant"] is not None],
            "fields": [{
                "name": field["name"],
                "bitOffset": field["bitOffset"],
                "count": field["count"],
            } for field in fields],
            "source": {"tool": tool, "document": digest[:8]},
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
    candidates = []
    for digest, text in documents(blob):
        fields = fields_of(text)
        if not fields:
            continue
        anchors = {f["name"]: f["constant"] for f in fields
                   if f["name"] in ANCHOR_NAMES}
        candidates.append((digest, fields, anchors))
        print("document %s: %d fields, anchors %s"
              % (digest[:8], len(fields), anchors), file=sys.stderr)
    # The MTL layout the dump verifies: the common header and the 0x5 anchor.
    chosen = None
    for digest, fields, anchors in candidates:
        if (anchors.get("SPHY_OEM_NVAR_Common_Header_2") == 0x5
                and anchors.get("SPHY_OEM_NVAR_Common_Header_3") == 0x3
                and anchors.get("Sub_Section_Entry2_Header_8") == 0x5
                and len(fields) < 600):
            chosen = (digest, fields)
            break
    if chosen is None:
        print("no MTL SPHY layout found in this build", file=sys.stderr)
        return 1
    print("chosen %s: %d fields" % (chosen[0][:8], len(chosen[1])), file=sys.stderr)
    print(json_document(tool, chosen[0], chosen[1]) if output_format == "json"
          else swift(tool, chosen[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
