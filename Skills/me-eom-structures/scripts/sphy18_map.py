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

    python3 sphy18_map.py <mfit-18.1.exe> > \\
        Packages/MEFirmware/Sources/MEFirmware/Configuration/SphyNvarMap+CSME18.swift

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import hashlib
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


def fields_of(text):
    start = text.find('<mfit_data id="SphyNvar">')
    end = text.find('</mfit_data>', start)
    fields = []
    for tag in ITEM.findall(text[start:end]):
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


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
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
    print(swift(tool, chosen[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
