"""Emit CSME 18's CPU strap layout from MFIT 18's strap documents.

The tool keeps the strap layouts in `DescriptorPluginsCommon/data/straps/`, and
MFIT 18.1 packages those documents in the executable as `mfit_data` blocks of
`serialized_item`s:

    <mfit_data id="CPU_smip">
      <serialized_item name="CPU_smip_Strap_CPU_SMT_Disable" type="BitfieldItem"
                       value="?($rvp == … ? 0x0 : …)" offset="0x0"
                       bit_low="0" bit_high="0"/>
      …
      <ui_item name="HyperThreadingDisable" config_type="no_yes_options"
               label="Disable Hyperthreading" section="CpuStraps" help_text="…"/>
      <bind_action type="get_value" ui_controller="HyperThreadingDisable"
                   serialized_item="CPU_smip_Strap_CPU_SMT_Disable"/>

A `serialized_item`'s `offset` is bytes into the **CPU message** (the MIP table
keeps it in the FITC partition's `smip` file, see `CPUStrapMap`), the bits are
counted in the little-endian dword there. Labels, sections, help and option
words are the tool's; a value is per reference platform (`$rvp`), so the map
states no default.

The three platform documents at hand (`mtl_arl_p_a0`, `mtl_m`, `mtl_p`) place
the fields alike; a name two of them place differently is dropped and named,
as `mip_strap_map.py` does for the descriptor's older message.

    python3 strap18_map.py <mfit-18.1.exe> > \\
        Packages/MEFirmware/Sources/MEFirmware/Configuration/CPUStrapMap+CSME18.swift

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import collections
import hashlib
import os
import re
import sys
import zlib

GENERATION = "18"

TWO_KINDS = {
    "no_yes_options": {0: "No", 1: "Yes"},
    "yes_no_options": {0: "Yes", 1: "No"},
    "disabled_enabled_options": {0: "Disabled", 1: "Enabled"},
    "enabled_disabled_options": {0: "Enabled", 1: "Disabled"},
}

ITEM = re.compile(r'<serialized_item name="([^"]+)" type="([^"]+)" value="([^"]*)" '
                  r'offset="([^"]+)" bit_low="(\d+)" bit_high="(\d+)"')
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
        if b'<mfit_data id="CPU_smip">' not in out:
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


def fields_of(text):
    """The CPU_smip block of one document: items with the panel's words."""
    block = mfit_block(text, "CPU_smip")
    if block is None:
        return []
    account_block(block, "CPU_smip")
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
    fields = []
    for name, kind, value, offset, low, high in ITEM.findall(block):
        if kind != "BitfieldItem":
            continue
        entry = words.get(binds.get(name), {})
        fields.append({
            "name": name,
            "offset": int(offset, 0),
            "bit": int(low),
            "count": int(high) - int(low) + 1,
            "label": entry.get("label"),
            "section": entry.get("section"),
            "help": entry.get("help"),
            "options": entry.get("options"),
        })
    return fields


def merged(documents_found):
    by_name = {}
    conflicts = set()
    for _, fields in documents_found:
        for field in fields:
            kept = by_name.get(field["name"])
            if kept is None:
                by_name[field["name"]] = field
                continue
            if (kept["offset"], kept["bit"], kept["count"]) != \
                    (field["offset"], field["bit"], field["count"]):
                conflicts.add(field["name"])
                continue
            for key in ("label", "section", "help"):
                if len(field[key] or "") > len(kept[key] or ""):
                    kept[key] = field[key]
            if kept["options"] is None:
                kept["options"] = field["options"]
    return [f for name, f in by_name.items() if name not in conflicts], conflicts


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(tool, fields):
    lines = [
        "// The CPU strap message's layout of CSME %s, as %s lays it out" % (GENERATION, tool),
        "// — emitted by `Skills/me-eom-structures/scripts/strap18_map.py` from the",
        "// tool's own `CPU_smip` documents. Names, offsets, bits, labels, sections,",
        "// help and option words are the tool's; nothing here is read out of a dump,",
        "// and no default is stated: the values are per reference platform.",
        "//",
        "// CSME 18 keeps this message in the FITC partition's MIP table, not in the",
        "// descriptor's MIP area (`CPUStrapMap`).",
        "",
        "import Foundation",
        "",
        "extension CPUStrapMap {",
        "    /// The CPU straps, as the tool lays them out.",
        "    public static let csme%s = CPUStrapMap(" % GENERATION,
        "        name: %s," % swift_literal("CSME %s (%s)" % (GENERATION, tool)),
        "        fields: [",
    ]
    for field in fields:
        args = ["name: %s" % swift_literal(field["name"]),
                "offset: 0x%X" % field["offset"],
                "bit: %d" % field["bit"],
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
    found_documents = []
    for digest, text in documents(blob):
        fields = fields_of(text)
        found_documents.append((digest, fields))
        print("document %s: %d CPU strap fields" % (digest[:8], len(fields)),
              file=sys.stderr)
    if not found_documents:
        print("no CPU_smip document found in this build", file=sys.stderr)
        return 1
    fields, conflicts = merged(found_documents)
    for name in sorted(conflicts):
        print("! left out %s: two documents place it differently" % name,
              file=sys.stderr)
    fields.sort(key=lambda f: (f["offset"], f["bit"], f["name"]))
    print("fields: %d" % len(fields), file=sys.stderr)
    print(swift(tool, fields))
    return 0


if __name__ == "__main__":
    sys.exit(main())
