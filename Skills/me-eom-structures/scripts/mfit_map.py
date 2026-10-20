#!/usr/bin/env python3
"""Emit a generation's ME configuration map from an MFIT build's own database.

MFIT carries its settings database as zlib-compressed XML inside `mfit.exe`: one
document per platform list (ADL-S, MTL-M, MTL-S, ELG in the 16.0.15 build), each
listing the MFS files, the settings that live in them, the byte offset and bits
of each, the values it may take, and who writes it (`process_type`).

Run it, read the diff and the notes it prints, and write the JSON (which the
compiler reads, `Design/MAP_DATA.md`) under `MapSources/configuration/`:

    python3 Skills/me-eom-structures/scripts/mfit_map.py \\
        <mfit-16.1.42.exe> <mfit-16.0.15.exe> \\
        --generation 16 --tool "16.1.42, 16.0.15.1817" --format json > \\
        Packages/MEFirmware/MapSources/configuration/csme16.json

Stdlib only, read-only, no network. The script decides nothing about what a
value *means*: it copies MFIT's own labels, offsets and option numbers, and says
on stderr what it left out.
"""

import json
import os
import re
import sys
import zlib

# The settings a build is given and the settings the tool works out are told
# apart by `process_type`; MFIT's own enum is exactly these two.
AUTO = "Auto"

# The field kinds that read as a number in hex. MFIT's own defaults for them are
# written that way (`value="0x02"` for a byte), and a firmware address or mask in
# decimal is a value nobody reads twice.
HEX_KINDS = {"byte", "word", "dword", "qword"}

# How many bytes a file setting takes when the tool gives it no place and the
# file *is* the setting — see `settings_of`. The enumerated kinds are one byte,
# as FIT's own value classes are; the integer kinds say their width.
WHOLE_WIDTH = {
    "no_yes_options": 1, "yes_no_options": 1,
    "disabled_enabled_options": 1, "enabled_disabled_options": 1,
    "fixed_options": 1, "byte": 1, "word": 2, "dword": 4, "qword": 8,
}

# The enumerated kinds, with the words MFIT gives their two values. **The kind's
# own name lists its members in value order** — `yes_no_options` is Yes at 0 and
# No at 1, `no_yes_options` the other way round — which is how FIT's value
# classes of the same names spell themselves (`<Class name="YesNoValues">`:
# `Yes` value 0, `No` value 1). Reading them as if the pairs were interchangeable
# put "No" on every 0 of four ME 16 settings, two of them readable in a dump.
# A `fixed_options` setting carries its own list in `config_params` instead.
TWO_KINDS = {
    "no_yes_options": {0: "No", 1: "Yes"},
    "yes_no_options": {0: "Yes", 1: "No"},
    "disabled_enabled_options": {0: "Disabled", 1: "Enabled"},
    "enabled_disabled_options": {0: "Enabled", 1: "Disabled"},
}

# The files a bench reads first: the End of Manufacturing record, then the
# policy and the settings an edit is usually about. The rest follow in MFIT's own
# order. Paths here are MFS paths with `/home` (`/mca/eom_config` in the
# database, which spells them without it).
FIRST = [
    "/home/mca/eom_config",
    "/home/mca/eom",
    "/home/mca/mca_oem_version",
    "/home/pavp/hdcp_ports",
    "/home/smbus/smlink_bus",
    "/home/iunit/iunit_oem_cfg",
    "/home/iunit/iunit_privacy_mode",
    "/home/policy/cfgmgr/cfg_rules",
]


def build_name(path):
    """What to call a build: the version its path states — `mfit-16.1.42.exe`,
    `FITool 16.0.15.1662/mfit.exe` — or the file's own name where there is
    none."""
    directory = os.path.dirname(path)
    for part in (os.path.basename(path),
                 os.path.basename(directory),
                 os.path.basename(os.path.dirname(directory))):
        version = re.search(r"\d+(?:\.\d+){2,3}", part)
        if version:
            return version.group(0)
    return os.path.basename(path)


def documents(blob):
    """Every platform list in `blob`: the zlib streams that hold one.

    The streams do not all start with the same second byte (`0x9C` is the usual
    one, `0x01` and `0xDA` are not), which is why the pattern takes all three.
    """
    for match in re.finditer(rb"\x78[\x01\x9c\xda]", blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 12_000_000])
        except Exception:
            continue
        if b"<Files project=" in out and len(out) > 50_000:
            yield out.decode("utf-8", "replace")


def options_of(attrs, body):
    """The values a setting may take, by number, in MFIT's words — or None."""
    kind = re.search(r'config_type="([^"]*)"', body)
    kind = kind.group(1) if kind else None
    if kind in TWO_KINDS:
        return TWO_KINDS[kind]
    if kind != "fixed_options":
        return None
    params = re.search(r'config_params="(\{.*?\})"', body, re.S)
    if not params:
        return None
    table = {}
    for label, number in re.findall(r"'([^']*)'\s*:\s*'([^']*)'", params.group(1)):
        try:
            table[int(number, 0)] = label
        except ValueError:
            continue
    return table or None


def settings_of(body):
    """The readable settings of one `<File>` block, in MFIT's order.

    `label` is the tool's own name for the setting — what its panel shows —
    taken from the `<UI>` element beside the place (`name` is the identifier:
    `MELanPowerWell`, `PttSupported`; the label is "LAN Power Well",
    "Intel(R) PTT Supported"). The `section` the same element names is the
    panel's group, which the map does not carry.

    A setting with no place in the file (`length="0"` — most of the database:
    values the tool computes, certificates, the ICC profiles) is left out: it
    cannot be read out of bytes, and a row that is always empty is not a fact
    about a dump. **The exception is a file that is one setting**: where the
    tool gives a file exactly one logical setting, of a numeric kind, and
    states no place for it, the value is the file's own first bytes —
    `bup_sku/hw_binding`'s `HwBindingEn`, `policy/hmrfpo_state`'s
    `HmrfpoEnable`, `amt/rtfd/amt.wol`'s two-byte `AmtIdleTimeout` — and the
    width is the kind's (`WHOLE_WIDTH`). A file with several such settings is
    not read: the tool leaves the plugin to place them, and a guess would put
    one setting's byte under another's name.
    """
    found = []
    logical_count = len(re.findall(r'<LogicalAccess ', body))
    for match in re.finditer(r'<LogicalAccess name="([^"]+)"([^>]*)>(.*?)</LogicalAccess\s*>',
                             body, re.S):
        name, attrs, inner = match.group(1), match.group(2), match.group(3)
        place = re.search(r'offset="(-?\d+)" length="(\d+)"(?: bit_low="(\d+)" bit_high="(\d+)")?',
                          inner)
        if not place:
            continue
        offset, length = int(place.group(1)), int(place.group(2))
        bits = (int(place.group(3)), int(place.group(4))) if place.group(3) is not None else None
        kind = re.search(r'config_type="([^"]*)"', inner)
        kind = kind.group(1) if kind else None
        physical = re.search(r'physical_type="([^"]*)"', inner)
        physical = physical.group(1) if physical else None
        if length == 0:
            guard_ok = (logical_count == 1 and physical == "Data"
                        and kind in WHOLE_WIDTH)
            if not guard_ok:
                continue
            length = WHOLE_WIDTH[kind]
            offset = 0
        if length < 0 or offset < 0:
            continue
        ui = re.search(r'<UI\b[^>]*>', inner)
        label = re.search(r'\blabel="([^"]*)"', ui.group(0)) if ui else None
        help_text = re.search(r'\bhelp="([^"]*)"', ui.group(0)) if ui else None
        found.append({
            "name": name,
            "label": label.group(1) if label else None,
            "help": unescaped(help_text.group(1)) if help_text else None,
            "offset": offset,
            "length": length,
            "bits": bits,
            "options": options_of(attrs, inner),
            "auto": 'process_type="%s"' % AUTO in attrs,
            "hex": kind in HEX_KINDS,
            "text": kind == "string" and physical == "String",
        })
    return found


# What makes two lists' entries the same setting for reading purposes: where
# it sits, how wide, which bits, its option words. The label and the help text
# are the tool's prose and differ between lists — a truncated sentence is not a
# different offset — so they are not compared here; `collect` keeps the fuller.
LAYOUT_KEYS = ("offset", "length", "bits", "options", "hex", "text")


def layout(setting):
    """What makes two entries the same place. A bitfield's value is its offset
    and bits: the lists state different windows around it (8 bytes in one,
    32 in another for `icpsSwSkuing`, bit 0 in both), and how much is read
    around a bit is not a different place. A plain value's width is its own.
    """
    keys = [key for key in LAYOUT_KEYS
            if not (setting.get("bits") and key == "length")]
    return {key: setting.get(key) for key in keys}


def collect(texts):
    """The union of the platform lists: `path` → file, and what disagreed.

    The lists differ between SKUs — a Corporate-only setting is absent from a
    Consumer list, and a file may be listed once per project — so what a list
    does not carry says nothing. A setting the lists lay out *differently* is
    the thing to report: one map cannot serve two offsets, and the file has to
    be split per project before either is used.
    """
    files, conflicts = {}, []
    for text in texts:
        for match in re.finditer(r'<File path="([^"]+)"[^>]*alias="([^"]*)"[^>]*>(.*?)</File\s*>',
                                 text, re.S):
            path, alias, body = match.group(1), match.group(2), match.group(3)
            path = "/home/" + path
            settings = settings_of(body)
            if not settings:
                continue
            if path not in files:
                files[path] = {"alias": alias, "settings": settings}
                continue
            known = {s["name"]: s for s in files[path]["settings"]}
            for setting in settings:
                if setting["name"] not in known:
                    files[path]["settings"].append(setting)
                    continue
                kept = known[setting["name"]]
                if layout(kept) != layout(setting):
                    conflicts.append((path, setting["name"], kept, setting))
                    continue
                # The same place, said with different words: the lists spell
                # a label or a help text differently (one truncates the
                # sentence). That is not a layout conflict — the value reads
                # the same under both — so the fuller wording is kept.
                # `auto` is not a place either: one list may mark a setting
                # the tool works out and another not, and the mark stays if
                # either says so — it is what the tool reports about itself.
                kept["auto"] = kept["auto"] or setting["auto"]
                for key in ("label", "help"):
                    if len(setting.get(key) or "") > len(kept.get(key) or ""):
                        kept[key] = setting[key]
    for path, name, _, _ in conflicts:
        files[path]["settings"] = [s for s in files[path]["settings"]
                                   if s["name"] != name]
    return files, conflicts


def unescaped(text):
    """An attribute as a reader reads it.

    The XML entities resolved, named and numeric both — MFIT writes its line
    breaks as `&#13;&#10;` and FIT its paragraph breaks as `&#60;br /&#62;` —
    and a break turned into the line break it stands for: the words are the
    tool's, and what the tool wrote as markup is a line, not text.
    """
    if not text:
        return text
    for entity, character in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'),
                              ("&apos;", "'"), ("&amp;", "&")):
        text = text.replace(entity, character)
    def number(match):
        digits = match.group(1)
        return chr(int(digits[1:], 16) if digits[:1] in "xX" else int(digits))
    text = re.sub(r"&#(x?[0-9a-fA-F]+);", number, text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    return re.sub(r"\r\n?", "\n", text)


def swift_literal(text):
    """A Swift string literal: the backslash, the quote, and the breaks a
    tool's own help text carries — a literal line break in a Swift string is a
    compile error, an escaped one is the line the reader sees."""
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(files):
    out = []
    head = FIRST + [p for p in files if p not in FIRST]
    for path in head:
        if path not in files:
            continue
        entry = files[path]
        out.append('        File(path: %s, alias: %s, settings: [' %
                   (swift_literal(path), swift_literal(entry["alias"])))
        for s in entry["settings"]:
            args = ["name: %s" % swift_literal(s["name"]),
                    "offset: %d" % s["offset"],
                    "length: %d" % s["length"]]
            # The tool's own name for the setting, where it differs from the
            # identifier: a map that repeats the identifier says the tool shows
            # nothing else.
            if s.get("label") and s["label"] != s["name"]:
                args.append("label: %s" % swift_literal(s["label"]))
            if s.get("help"):
                args.append("help: %s" % swift_literal(s["help"]))
            if s["bits"]:
                args.append("bits: %d...%d" % s["bits"])
            if s["options"]:
                pairs = ", ".join("%d: %s" % (n, swift_literal(s["options"][n]))
                                  for n in sorted(s["options"]))
                args.append("options: [%s]" % pairs)
            if s["auto"]:
                args.append("auto: true")
            if s["hex"]:
                args.append("hex: true")
            if s["text"]:
                args.append("text: true")
            out.append("            Setting(%s)," % ", ".join(args))
        out.append("        ]),")
    return "\n".join(out)


def setting_json(setting):
    entry = {"name": setting["name"],
             "offset": setting["offset"],
             "length": setting["length"]}
    if setting.get("label") and setting["label"] != setting["name"]:
        entry["label"] = setting["label"]
    if setting.get("help"):
        entry["help"] = setting["help"]
    if setting.get("bits"):
        entry["bits"] = [setting["bits"][0], setting["bits"][1]]
    if setting.get("options"):
        entry["options"] = [[number, setting["options"][number]]
                            for number in sorted(setting["options"])]
    if setting.get("auto"):
        entry["auto"] = True
    if setting.get("hex"):
        entry["hex"] = True
    if setting.get("text"):
        entry["text"] = True
    return entry


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
            for key in sorted(mapping) if key != "files")
        lines.append('  {%s, "files": [' % rest)
        for file_index, entry in enumerate(mapping["files"]):
            rest = ", ".join(
                "%s: %s" % (json.dumps(key),
                            json.dumps(entry[key], ensure_ascii=False, sort_keys=True))
                for key in sorted(entry) if key != "settings")
            lines.append('   {%s, "settings": [' % rest)
            for setting_index, setting in enumerate(entry["settings"]):
                lines.append("    %s%s" % (
                    json.dumps(setting, ensure_ascii=False, sort_keys=True,
                               separators=(", ", ": ")),
                    "," if setting_index + 1 < len(entry["settings"]) else ""))
            lines.append('   ]}%s' % ("," if file_index + 1 < len(mapping["files"]) else ""))
        lines.append('  ]}%s' % ("," if map_index + 1 < len(document["maps"]) else ""))
    lines.append(" ]")
    lines.append("}")
    return "\n".join(lines)


def json_document(files, generation, tool, variable):
    ordered = [path for path in FIRST + [p for p in files if p not in FIRST]
               if path in files]
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "configuration",
        "tool": tool,
        "maps": [{
            "id": variable,
            "name": "CSME %s (Flash Image Tool %s)" % (generation, tool),
            "files": [{
                "path": path,
                "alias": files[path]["alias"],
                "settings": [setting_json(setting)
                             for setting in files[path]["settings"]],
            } for path in ordered],
        }],
    })


def option(args, name, default):
    """A `--name value` option, taken out of the argument list."""
    if name not in args:
        return args, default
    at = args.index(name)
    value = args[at + 1]
    return [a for i, a in enumerate(args) if i not in (at, at + 1)], value


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    # More than one build may be given, and their databases are merged with the
    # same rules as one build's lists: a setting either states keeps its place,
    # and one they state differently is reported. That is how a map serves the
    # whole generation — a file the newest build's lists dropped (a platform
    # retired, a setting renamed) is still read out of the images the older
    # builds wrote, where it is at the same place.
    args, generation = option(args, "--generation", "16")
    args, output_format = option(args, "--format", "swift")
    if output_format not in ("swift", "json"):
        print("--format is swift or json", file=sys.stderr)
        return 2
    # Which builds the map was read from, for the map's name: the databases'
    # own versions, unless the caller states them (a file name may not carry
    # the build number the executable does).
    builds = ", ".join(build_name(path) for path in args)
    args, tool = option(args, "--tool", builds)
    args, variable = option(args, "--variable", "csme%s" % generation)
    paths = args
    texts = []
    for path in paths:
        texts.extend(documents(open(path, "rb").read()))
    if not texts:
        print("no platform list found in these builds", file=sys.stderr)
        return 1
    files, conflicts = collect(texts)
    readable = sum(len(f["settings"]) for f in files.values())
    print("builds: %d  platform lists: %d  files with readable settings: %d  settings: %d"
          % (len(paths), len(texts), len(files), readable), file=sys.stderr)
    for path, name, there, here in conflicts:
        print("! dropped %s %s: the lists lay it out differently (%s / %s)" %
              (path, name, there, here), file=sys.stderr)
    if output_format == "json":
        print(json_document(files, generation, tool, variable))
        return 0
    print("// The CSME 16 map of the ME configuration — emitted by")
    print("// `Skills/me-eom-structures/scripts/mfit_map.py` from the settings")
    print("// databases of Flash Image Tool %s," % tool)
    print("// merged as one: the offsets, bits, the tool's own name for")
    print("// each setting (`label`), its option labels and the")
    print("// `Auto` marks are Intel's, copied; nothing here is read out of a dump.")
    print("//")
    print("// A generation's map lives in a file of its own: see `MEConfigurationMap.swift`")
    print("// for what a map is and why each generation has its own.")
    print()
    print("import Foundation")
    print()
    print("extension MEConfigurationMap {")
    print('    /// The ME 16 configuration, as MFIT 16 lays it out. The files stand in the')
    print('    /// order a bench reads them — the ME configuration itself first, then the')
    print('    /// policy and the settings an edit is usually about — and the rest in')
    print('    /// MFIT\'s own order, which is the order to diff a new build against.')
    print('    public static let csme16 = MEConfigurationMap(')
    print('        name: "CSME 16 (Flash Image Tool %s)",' % tool)
    print('        files: [')
    print(swift(files))
    print('        ])')
    print('}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
