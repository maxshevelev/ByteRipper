"""Emit the FPF/UEP settings of a generation — the bits the tool writes into the
`$UEP` area's first bit array.

The area the image keeps at `$UEP` is described nowhere public, but both
tools' documents say what goes into it: a setting's declaration names it, and
a `GetBitArrayValue` action places it —

    <Action name="GetBitArrayValue" module="Bin" source="RpmcSupported"
            target="UepBitsArray0" params="{'offset':'0x74','startBit':4,'bitCount':1}"/>

— in one of several arrays the container keeps. **The engine reads the first
array** (`UepBitsArray0`, the one `BootGuardReader` reads the profile from);
a setting the tool places only in another array is not in this map, and the
script says how many were left out.

About three quarters of the settings read zero on every dump at hand, which is
the state the build wrote and not a gap: see `Design/ME_STRUCTURES.md`.

    python3 uep_map.py <mfit.exe> --generation 16 --tool "Modular Flash Image Tool 16.0.15.1662"
"""

import collections
import hashlib
import json
import os
import re
import sys
import zlib


def option(args, name, default=None):
    if name not in args:
        return args, default
    at = args.index(name)
    value = args[at + 1]
    return [a for i, a in enumerate(args) if i not in (at, at + 1)], value


def documents(blob):
    """Every zlib stream in the executable that holds a document."""
    seen = set()
    for match in re.finditer(re.compile(rb"\x78[\x01\x5e\x9c\xda]"), blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 20_000_000])
        except Exception:
            continue
        if len(out) < 200:
            continue
        text = out.decode("utf-8", "replace")
        if not text.lstrip().startswith("<"):
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        yield text


ACTION = re.compile(r"<Action name=\"GetBitArrayValue\"[^>]*>")
OPTION_ELEMENT = re.compile(r"<CfgOpt name=\"([^\"]+)\"([^>]*)>")


def unescaped(text):
    """An attribute as a reader reads it: entities resolved, breaks as lines."""
    if not text:
        return text
    for entity, character in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'),
                              ("&apos;", "'"), ("&amp;", "&")):
        text = text.replace(entity, character)
    text = re.sub(r"&#(x?[0-9a-fA-F]+);",
                  lambda m: chr(int(m.group(1)[1:], 16) if m.group(1)[:1] in "xX"
                                else int(m.group(1))), text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    return re.sub(r"\r\n?", "\n", text)


def settings(blob):
    """Every UEP setting the tool's documents name, with its first-array place.

    A setting can be placed in several arrays — the container keeps copies —
    and only the first array's place is kept: that is the array an image's
    reading takes. A setting without one is counted and left out.
    """
    found = {}
    placed = collections.defaultdict(list)
    for text in documents(blob):
        actions = ACTION.findall(text)
        if not actions:
            continue
        for match in OPTION_ELEMENT.finditer(text):
            attrs = dict(re.findall(r"([a-zA-Z_][\w]*)=\"([^\"]*)\"", match.group(2)))
            name = match.group(1)
            entry = found.setdefault(name, {"label": None, "help": None, "section": None})
            entry["label"] = entry["label"] or attrs.get("label")
            entry["help"] = entry["help"] or unescaped(attrs.get("help_text") or attrs.get("help"))
            entry["section"] = entry["section"] or attrs.get("section")
        for action in actions:
            source = re.search(r"source=\"([^\"]+)\"", action)
            array = re.search(r"target=\"UepBitsArray(\d+)\"", action)
            place = re.search(r"'offset':'([^']*)','startBit':(\d+),'bitCount':(\d+)", action)
            if not (source and array and place):
                continue
            placed[source.group(1)].append(
                (int(array.group(1)), int(place.group(1), 16),
                 int(place.group(2)), int(place.group(3))))
    out, left_out = [], 0
    for name, entry in found.items():
        places = [p for p in placed.get(name, []) if p[0] == 0]
        if not places:
            if placed.get(name):
                left_out += 1
            continue
        array, offset, bit, count = sorted(set(places))[0]
        out.append({"name": name, "label": entry["label"], "help": entry["help"],
                    "section": entry["section"],
                    "offset": offset, "bit": bit, "count": count})
    out.sort(key=lambda s: (s["section"] or "", s["offset"], s["bit"], s["name"]))
    return out, left_out


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(generation, tool, entries):
    lines = [
        "// The FPF/UEP settings of CSME %s, as %s names them — emitted by"
        % (generation, tool),
        "// `Skills/me-eom-structures/scripts/uep_map.py` from the tool's own",
        "// documents. Names, labels, sections and places are the tool's; nothing",
        "// here is read out of a dump.",
        "//",
        "// A setting's place is in the **first** bit array of the `$UEP` container",
        "// — the array an image's reading takes (the Boot Guard word's, see",
        "// `BootGuardReader`). The tool also places many settings in the container's",
        "// other arrays; those copies are not read, and such a setting is not here.",
        "//",
        "// What the arrays hold on a vendor dump is the state the build wrote, not",
        "// the fuses the platform will burn: see `Design/ME_STRUCTURES.md`.",
        "",
        "import Foundation",
        "",
        "extension UEPMap {",
        "    /// The FPF settings, as the tool lays them out.",
        "    public static let csme%s = UEPMap(" % generation,
        "        name: %s," % swift_literal("CSME %s (%s)" % (generation, tool)),
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
        lines.append("            Setting(%s)," % ", ".join(args))
    lines += ["        ])", "}", ""]
    return "\n".join(lines)


def setting_json(entry):
    value = {"name": entry["name"], "array": 0,
             "offset": entry["offset"], "bit": entry["bit"],
             "count": entry["count"]}
    if entry.get("label"):
        value["label"] = entry["label"]
    if entry.get("section"):
        value["section"] = entry["section"]
    if entry.get("help"):
        value["help"] = entry["help"]
    if entry.get("options"):
        value["options"] = [[number, entry["options"][number]]
                            for number in sorted(entry["options"])]
    return value


def pretty_json(document):
    """JSON with one setting per line: a diff reads a setting at a time."""
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
            for key in sorted(mapping) if key != "settings")
        lines.append('  {%s, "settings": [' % rest)
        settings = mapping["settings"]
        for setting_index, setting in enumerate(settings):
            lines.append("   %s%s" % (
                json.dumps(setting, ensure_ascii=False, sort_keys=True,
                           separators=(", ", ": ")),
                "," if setting_index + 1 < len(settings) else ""))
        lines.append('  ]}%s' % ("," if map_index + 1 < len(document["maps"]) else ""))
    lines.append(" ]")
    lines.append("}")
    return "\n".join(lines)


def json_document(generation, tool, entries):
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "uep",
        "tool": tool,
        "maps": [{
            "id": "csme%s" % generation,
            "name": "CSME %s (%s)" % (generation, tool),
            "arrayStart": 0x0C,
            "arraySize": 0,
            "settings": [setting_json(entry) for entry in entries],
        }],
    })


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    args, generation = option(args, "--generation", None)
    args, tool = option(args, "--tool", None)
    args, output_format = option(args, "--format", "swift")
    if output_format not in ("swift", "json"):
        print("--format is swift or json", file=sys.stderr)
        return 2
    if not generation or not tool or not args:
        print(__doc__)
        return 2
    blob = open(args[0], "rb").read()
    entries, left_out = settings(blob)
    print("FPF/UEP settings in the first bit array: %d (%d left out: placed only in "
          "another array)" % (len(entries), left_out), file=sys.stderr)
    print("  without a label (the tool names no UI text for them): %d"
          % sum(1 for e in entries if not e["label"]), file=sys.stderr)
    print(json_document(generation, tool, entries) if output_format == "json"
          else swift(generation, tool, entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
