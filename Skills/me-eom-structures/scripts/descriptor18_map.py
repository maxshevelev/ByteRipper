"""Emit the flash descriptor's register layouts from MFIT 18's harness documents.

MFIT 18 carries the descriptor's registers as `mfit_data` blocks of bitfields:

    <mfit_data id="FLMAP0">
      <serialized_item name="Base_Descriptor_SOC_Strap_FLMAP0_Flash_Component_Base_Address"
                       type="BitfieldItem" value="0x3" offset="0x0"
                       bit_low="0" bit_high="7"/>
      …

The blocks at hand: FLVALSIG, FLMAP0/1/2, FLCOMP, FLIL, FLMSTR (six master
registers), FLDRPLCY and FLUMAP1. A field's place is `offset*8 + bit_low …
offset*8 + bit_high` within the register, and the register's own place in the
descriptor is fixed (FLMAP0/1/2 at 0x14, FLDRPLCY at 0x340, FLUMAP1 at 0xEFC)
or stated by the descriptor itself (FLCOMP and FLIL at `FCBA << 4`, FLMSTR at
`FMBA << 4`).

The generator keeps the tool's names (with the `Base_Descriptor_SOC_Strap_`
prefix stripped), labels and option words, and emits them into
`MapSources/register/csme18.json`. Where the three platform documents
disagree about a field, it is dropped and named.

    python3 descriptor18_map.py <mfit-18.1.exe> --format json > \\
        Packages/UEFIImage/MapSources/register/csme18.json

The JSON is compiled into `RegisterMaps.bin` by `map_bin.py`
(`Design/MAP_DATA.md`).

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import hashlib
import json
import os
import re
import sys
import zlib

PREFIX = "Base_Descriptor_SOC_Strap_"

TWO_KINDS = {
    "no_yes_options": {0: "No", 1: "Yes"},
    "yes_no_options": {0: "Yes", 1: "No"},
    "disabled_enabled_options": {0: "Disabled", 1: "Enabled"},
    "enabled_disabled_options": {0: "Enabled", 1: "Disabled"},
}

# name, place, byte offset in the register block, words
REGISTERS = [
    ("FLMAP0", "absolute", 0x14, 1),
    ("FLMAP1", "absolute", 0x18, 1),
    ("FLMAP2", "absolute", 0x1C, 1),
    ("FLCOMP", "flashComponent", 0x0, 1),
    ("FLIL", "flashComponent", 0x4, 2),
    ("FLMSTR", "flashMaster", 0x0, 6),
    ("FLDRPLCY", "absolute", 0x340, 1),
    ("FLUMAP1", "absolute", 0xEFC, 1),
]

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
        if b'<mfit_data id="FLMAP0">' not in out:
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


def fields_of(text, register):
    block = mfit_block(text, register)
    if block is None:
        return []
    account_block(block, register)
    words = {}
    for match in UI.finditer(block):
        name, attrs = match.group(1), match.group(2)
        words[name] = {
            "label": unescaped(attribute(attrs, "label")),
            "options": options_of(attribute(attrs, "config_type"),
                                  attribute(attrs, "config_params")),
        }
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
        start_bit = int(offset, 0) * 8 + int(low)
        entries = words.get(binds.get(name), {})
        short = name[len(PREFIX):] if name.startswith(PREFIX) else name
        fields.append({
            "name": short,
            "bitOffset": start_bit,
            "count": int(high) - int(low) + 1,
            "label": entries.get("label"),
            "options": entries.get("options"),
        })
    return fields


def merged(found):
    total = len(found)
    counts, by_name = {}, {}
    for fields in found:
        for field in fields:
            kept = by_name.get(field["name"])
            if kept is None:
                by_name[field["name"]] = field
                counts[field["name"]] = 1
                continue
            if kept["bitOffset"] != field["bitOffset"] or kept["count"] != field["count"]:
                counts[field["name"]] = -1
                continue
            counts[field["name"]] += 1
            if not kept["label"]:
                kept["label"] = field["label"]
            if kept["options"] is None:
                kept["options"] = field["options"]
    return [by_name[name] for name, n in counts.items() if n == total]


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(tool, registers):
    lines = [
        "// The flash descriptor's registers, as %s lays them out —" % tool,
        "// emitted by `Skills/me-eom-structures/scripts/descriptor18_map.py` from",
        "// the tool's own harness documents. Names, places, labels and option",
        "// words are the tool's; nothing here is read out of a dump.",
        "//",
        "// A register is placed absolutely in the descriptor (FLMAP0/1/2,",
        "// FLDRPLCY, FLUMAP1) or at a base the descriptor states (FLCOMP/FLIL at",
        "// `FCBA << 4`, FLMSTR at `FMBA << 4`). A field's place is a bit range of",
        "// the register.",
        "",
        "import Foundation",
        "",
        "extension DescriptorRegisterMap {",
        "    /// The registers, as the tool lays them out.",
        "    public static let csme%s = DescriptorRegisterMap(" % "18",
        "        registers: [",
    ]
    for name, place, offset, words, fields in registers:
        place_code = {
            "absolute": "Place.absolute(0x%X)" % offset,
            "flashComponent": "Place.flashComponent(offset: 0x%X)" % offset,
            "flashMaster": "Place.flashMaster(offset: 0x%X)" % offset,
        }[place]
        lines.append("            Register(name: %s, place: %s, words: %d, fields: ["
                     % (swift_literal(name), place_code, words))
        for field in fields:
            args = ["name: %s" % swift_literal(field["name"]),
                    "bitOffset: %d" % field["bitOffset"],
                    "count: %d" % field["count"]]
            if field["label"]:
                args.append("label: %s" % swift_literal(field["label"]))
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
            for key in sorted(mapping) if key != "registers")
        lines.append('  {%s, "registers": [' % rest)
        registers = mapping["registers"]
        for register_index, register in enumerate(registers):
            rest = ", ".join(
                "%s: %s" % (json.dumps(key),
                            json.dumps(register[key], ensure_ascii=False, sort_keys=True))
                for key in sorted(register) if key != "fields")
            lines.append('   {%s, "fields": [' % rest)
            fields = register["fields"]
            for field_index, field in enumerate(fields):
                lines.append("    %s%s" % (
                    json.dumps(field, ensure_ascii=False, sort_keys=True,
                               separators=(", ", ": ")),
                    "," if field_index + 1 < len(fields) else ""))
            lines.append('   ]}%s' % ("," if register_index + 1 < len(registers) else ""))
        lines.append('  ]}%s' % ("," if map_index + 1 < len(document["maps"]) else ""))
    lines.append(" ]")
    lines.append("}")
    return "\n".join(lines)


def json_document(tool, registers):
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "register",
        "tool": tool,
        "maps": [{
            "id": "csme18",
            "name": "csme18",
            "registers": [{
                "name": name,
                "place": {"kind": place, "offset": offset},
                "words": words,
                "fields": [
                    {"name": field["name"],
                     "bitOffset": field["bitOffset"],
                     "count": field["count"],
                     **({"label": field["label"]} if field["label"] else {}),
                     **({"options": [[number, word]
                                     for number, word in sorted(field["options"].items())]}
                        if field["options"] else {})}
                    for field in fields
                ],
            } for name, place, offset, words, fields in registers],
            "source": {"tool": tool},
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
        print("no descriptor register documents found in this build", file=sys.stderr)
        return 1
    registers = []
    for name, place, offset, words in REGISTERS:
        found = [fields for fields in (fields_of(text, name) for _, text in docs) if fields]
        if not found:
            print("! %s: no fields in any document" % name, file=sys.stderr)
            continue
        fields = merged(found)
        fields.sort(key=lambda f: (f["bitOffset"], f["name"]))
        registers.append((name, place, offset, words, fields))
        print("%s: %d fields from %d document(s)" % (name, len(fields), len(found)),
              file=sys.stderr)
    print(json_document(tool, registers) if output_format == "json"
          else swift(tool, registers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
