"""Emit CSME 18's FPF/UEP layout from MFIT 18's rewritten database.

MFIT 18 keeps the UEP material as `UEPs_Data` documents of

    <serialized_item name="BTG_PROFILE" type="BitfieldItem" value="0x0"
                     offset="0x48" bit_low="30" bit_high="32"/>
    <ui_item name="BtGuardProfileConfig" config_type="fixed_options"
             label="Boot Guard Profile" section="BootGuardConfiguration"
             config_params="{'Boot Guard Disabled': '0x0', …}"
             help_text="…"/>
    <bind_action type="get_value" ui_controller="BtGuardProfileConfig"
                 serialized_item="BTG_PROFILE"/>

plus `ui_item name="arrays_count"`, which says how many bit arrays the
container keeps.

**The place.** The tool builds the area as `UepHeader` — 8 bytes: signature
`$UEP`, a CRC-16, a reserved word — followed by `arrays_count × 0x80` bytes of
arrays (`FitByteArray(arrays_count * 0x80)` in its own code), and a
`serialized_item`'s `offset` counts from the start of the arrays. `UEPMap`
reads the **first** array, offsets 0x00–0x7F, so an item at 0x80 or beyond is
in a later array and is left out — as the older tool's settings placed only in
another array are.

The 8-byte header is confirmed on the CSME 18 dump at hand: its CRC-16 (poly
0x1021, init 0xFFFF, no reflection) over bytes +6…+0x208 — reserved through
four 0x80-byte arrays — reproduces the stored word, and reading the MTL
document's items at +8 gives a coherent set (`OEM_ID` 0x103C, HP's PCI vendor
ID; `KM_ID` 1; `FW_TYPE` 3; `BTG_PROFILE` 5; the validity bits set), while
reading them at the CSME 15/16 array start of 0x0C gives nonsense (KM_ID 15,
FW_TYPE 0).

Settings are merged across the documents that hold them; a name two documents
place differently is dropped and named. Wording is the fuller one, as in the
configuration map. The ESE document (`ESE_CFG_DONE`, `ESE_TRC_EN`,
`ESE_ROM_SVN_EN`) is part of the same merge: its first two are in the first
array, the third is not.

    python3 uep18_map.py <mfit-18.1.exe> > \\
        Packages/MEFirmware/Sources/MEFirmware/Configuration/UEPMap+CSME18.swift

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import collections
import hashlib
import os
import re
import sys
import zlib

GENERATION = "18"
FIRST_ARRAY = 0x80

TWO_KINDS = {
    "no_yes_options": {0: "No", 1: "Yes"},
    "yes_no_options": {0: "Yes", 1: "No"},
    "disabled_enabled_options": {0: "Disabled", 1: "Enabled"},
    "enabled_disabled_options": {0: "Enabled", 1: "Disabled"},
}

ITEM = re.compile(
    r'<serialized_item name="([^"]+)" type="([^"]+)" value="([^"]*)" '
    r'offset="([^"]+)" bit_low="(\d+)" bit_high="(\d+)"/>')
UI = re.compile(r'<ui_item name="([^"]+)"([^>]*)>')
BIND = re.compile(r'<bind_action type="([^"]+)" ui_controller="([^"]+)" '
                  r'serialized_item="([^"]+)"/>')


def documents(blob):
    """Every UEPs_Data document in the executable, once each."""
    seen = set()
    for match in re.finditer(re.compile(rb"\x78[\x01\x5e\x9c\xda]"), blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 30_000_000])
        except Exception:
            continue
        if b'id="UEPs_Data"' not in out:
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        text = out.decode("utf-8", "replace")
        if "<serialized_item " not in text:
            continue
        yield digest, text


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


def ui_words(text):
    """The panel's words for a setting, by its controller name."""
    words = {}
    for match in UI.finditer(text):
        name, attrs = match.group(1), match.group(2)
        kind = attribute(attrs, "config_type")
        words[name] = {
            "kind": kind,
            "label": unescaped(attribute(attrs, "label")),
            "section": unescaped(attribute(attrs, "section")),
            "help": unescaped(attribute(attrs, "help_text")),
            "params": attribute(attrs, "config_params"),
        }
    return words


def options_of(entry):
    if not entry:
        return None
    kind = entry["kind"]
    if kind in TWO_KINDS:
        return TWO_KINDS[kind]
    if kind != "fixed_options" or not entry["params"]:
        return None
    table = {}
    for label, number in re.findall(r"'([^']*)'\s*:\s*'([^']*)'", entry["params"]):
        try:
            table[int(number, 0)] = label
        except ValueError:
            continue
    return table or None


def settings_of(text):
    """The first-array settings of one document: name, place, words."""
    binds = {item: controller for _, controller, item in BIND.findall(text)}
    words = ui_words(text)
    arrays = re.search(r'<ui_item name="arrays_count"[^>]*value="([^"]+)"', text)
    count = int(arrays.group(1)) if arrays else None
    found, left_out = [], 0
    for name, kind, value, offset, low, high in ITEM.findall(text):
        if kind != "BitfieldItem":
            continue
        at = int(offset, 0)
        if at + (int(high) // 8) >= FIRST_ARRAY:
            left_out += 1
            continue
        entry = words.get(binds.get(name))
        found.append({
            "name": name,
            "offset": at,
            "bit": int(low),
            "count": int(high) - int(low) + 1,
            "label": entry["label"] if entry else None,
            "section": entry["section"] if entry else None,
            "help": entry["help"] if entry else None,
            "options": options_of(entry),
        })
    return found, left_out, count


def merged(documents_found):
    """One setting per name, and the names two documents place differently."""
    by_name = {}
    conflicts = set()
    for _, found in documents_found:
        for entry in found:
            kept = by_name.get(entry["name"])
            if kept is None:
                by_name[entry["name"]] = entry
                continue
            place = ("offset", "bit", "count")
            if any(kept[key] != entry[key] for key in place):
                conflicts.add(entry["name"])
                continue
            for key in ("label", "section", "help"):
                if len(entry[key] or "") > len(kept[key] or ""):
                    kept[key] = entry[key]
            if kept["options"] is None:
                kept["options"] = entry["options"]
    return [entry for name, entry in by_name.items() if name not in conflicts], conflicts


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(tool, entries):
    lines = [
        "// The FPF/UEP settings of CSME %s, as %s lays them out — emitted by"
        % (GENERATION, tool),
        "// `Skills/me-eom-structures/scripts/uep18_map.py` from the tool's own",
        "// `UEPs_Data` documents. Names, labels, sections, option words and places",
        "// are the tool's; nothing here is read out of a dump.",
        "//",
        "// A setting's place is in the **first** bit array, offsets 0x00–0x7F of",
        "// the arrays that follow the container's 8-byte `$UEP` header (signature,",
        "// CRC-16, reserved). An item the tool places in a later array is not here.",
        "//",
        "// What the arrays hold on a vendor dump is the state the build wrote, not",
        "// the fuses the platform will burn: see `Design/ME_STRUCTURES.md`.",
        "",
        "import Foundation",
        "",
        "extension UEPMap {",
        "    /// The FPF settings, as the tool lays them out.",
        "    public static let csme%s = UEPMap(" % GENERATION,
        "        name: %s," % swift_literal("CSME %s (%s)" % (GENERATION, tool)),
        "        settings: [",
    ]
    for entry in entries:
        args = ["name: %s" % swift_literal(entry["name"]),
                "placement: Placement(array: 0, offset: 0x%X, bit: %d, count: %d)"
                % (entry["offset"], entry["bit"], entry["count"])]
        if entry["label"]:
            args.append("label: %s" % swift_literal(entry["label"]))
        if entry["section"]:
            args.append("section: %s" % swift_literal(entry["section"]))
        if entry["help"]:
            args.append("help: %s" % swift_literal(entry["help"]))
        if entry["options"]:
            pairs = ", ".join("%d: %s" % (number, swift_literal(word))
                              for number, word in sorted(entry["options"].items()))
            args.append("options: [%s]" % pairs)
        lines.append("            Setting(%s)," % ", ".join(args))
    lines += ["        ],",
              "        arrayStart: 8)",
              "}", ""]
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
    for digest, text in documents(blob):
        found, left_out, arrays = settings_of(text)
        documents_found.append((digest, found))
        print("document %s: %d settings in the first array, %d in a later one, "
              "arrays_count %s" % (digest[:8], len(found), left_out,
                                   arrays if arrays is not None else "?"),
              file=sys.stderr)
    if not documents_found:
        print("no UEPs_Data document found in this build", file=sys.stderr)
        return 1
    entries, conflicts = merged(documents_found)
    for name in sorted(conflicts):
        print("! left out %s: two documents place it differently" % name,
              file=sys.stderr)
    entries.sort(key=lambda s: (s["section"] or "", s["offset"], s["bit"], s["name"]))
    print("settings: %d (of %d names)" % (len(entries),
                                          sum(len(f) for _, f in documents_found)),
          file=sys.stderr)
    print(swift(tool, entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
