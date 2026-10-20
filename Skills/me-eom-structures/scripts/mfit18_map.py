"""Emit the CSME 18 configuration map from MFIT 18's rewritten database.

MFIT 18 no longer carries the 16-shaped `<Files project="…">` lists. Its
database is a set of `<Files>` documents — one with the settings, one with the
paths — of

    <File name="POLICY_CFG_RULES">
      <nvar name="MELanPowerWell">
        <physical offset="188" length="4" bit_low="0" bit_high="2"/>
      </nvar>
      …

and, in the platform documents beside them, the panel's own words as
`<ui_item name="MELanPowerWell" label="LAN Power Well" section="…"
config_type="…" config_params="…" help_text="…"/>`. A file is named by an
alias (`POLICY_CFG_RULES`); the second document maps aliases to MFS paths
(`<FileName value="…"/><FilePath value="/home/policy/cfgmgr/cfg_rules"/>`).

Two kinds of place a file cannot state by size:

- `length="dynamic"`: the plugin decides. Where the file holds **one** such
  setting of a numeric kind, the file is the setting — offset 0, the width its
  kind names (`HW_BINDING_ENABLED`'s `HwBindingEn`, `EC_OOB_SMBUS_ADDR`'s
  `ECOOBSmbusAddr`). A file with several such settings (the certificate
  stores) is left to its plugin and not read.
- no `<physical>` at all: a build input or a string — not a value in a dump.

A setting two platform documents state with different `config_type` or option
lists is dropped and named: its words would be another platform's.

    python3 mfit18_map.py <mfit-18.1.exe> > \\
        Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME18.swift

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import collections
import hashlib
import json
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

# The numeric kinds that read as hex, and the width a whole-file setting takes
# from its kind (the enumerated kinds are one byte, as in the 16 database).
HEX_KINDS = {"byte", "word", "dword", "qword", "zero_padded_word"}
WHOLE_WIDTH = {
    "no_yes_options": 1, "yes_no_options": 1,
    "disabled_enabled_options": 1, "enabled_disabled_options": 1,
    "fixed_options": 1, "byte": 1, "word": 2, "zero_padded_word": 2,
    "dword": 4, "qword": 8, "int": 4, "boolean": 1,
}

# The files a bench reads first, as in the 16 map.
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


def documents(blob):
    seen = set()
    for match in re.finditer(re.compile(rb"\x78[\x01\x5e\x9c\xda]"), blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 30_000_000])
        except Exception:
            continue
        if len(out) < 300:
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        text = out.decode("utf-8", "replace")
        if not text.lstrip().startswith("<"):
            continue
        yield digest, text


def paths(docs):
    """Alias → MFS path, from the document of `<FileName>`/`<FilePath>` pairs."""
    table = {}
    for _, text in docs:
        for name, path in re.findall(
                r'<FileName value="([^"]+)"/>\s*<FilePath value="([^"]+)"/>', text):
            table.setdefault(name, path)
    return table


def ui_items(docs):
    """The panel's words for a setting, by name — and the kinds two documents
    disagree about."""
    words = {}
    conflicts = set()
    for _, text in docs:
        for match in re.finditer(r'<ui_item name="([^"]+)"([^>]*)>', text):
            name, attrs = match.group(1), match.group(2)
            kind = re.search(r'config_type="([^"]*)"', attrs)
            kind = kind.group(1) if kind else None
            if not kind:
                continue
            label = re.search(r'\blabel="([^"]*)"', attrs)
            section = re.search(r'\bsection="([^"]*)"', attrs)
            help_text = re.search(r'\bhelp_text="([^"]*)"', attrs)
            params = re.search(r"config_params=\"(\{.*?\})\"", attrs, re.S)
            entry = {
                "kind": kind,
                "label": label.group(1) if label else None,
                "section": section.group(1) if section else None,
                "help": unescaped(help_text.group(1)) if help_text else None,
                "params": params.group(1) if params else None,
            }
            kept = words.get(name)
            if kept is None:
                words[name] = entry
                continue
            if kept["kind"] != entry["kind"] or kept["params"] != entry["params"]:
                conflicts.add(name)
                continue
            for key in ("label", "help"):
                if len(entry[key] or "") > len(kept[key] or ""):
                    kept[key] = entry[key]
    return words, conflicts


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


def options_of(entry):
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


def settings_files(docs):
    """The `<Files>` document that holds the settings: alias → its `<nvar>`s."""
    for _, text in docs:
        if "<nvar " not in text:
            continue
        files = []
        for match in re.finditer(r'<File name="([^"]+)"[^>]*>(.*?)</File>', text, re.S):
            alias, body = match.group(1), match.group(2)
            nvars = []
            for nvar in re.finditer(r'<nvar name="([^"]+)"[^>]*>(.*?)</nvar>', body, re.S):
                name, inner = nvar.group(1), nvar.group(2)
                place = re.search(r'<physical[^>]*offset="([^"]+)" length="([^"]+)"'
                                  r'(?:\s+bit_low="(\d+)"\s+bit_high="(\d+)")?', inner)
                nvars.append((name, place, inner))
            files.append((alias, nvars))
        return files
    return []


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


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


def json_document(name, files):
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "configuration",
        "tool": name,
        "maps": [{
            "id": "csme18",
            "name": "CSME 18 (Flash Image Tool %s)" % name,
            "files": [{
                "path": path,
                "alias": alias,
                "settings": [setting_json(setting) for setting in settings],
            } for path, alias, settings in files],
        }],
    })


def swift(name, files):
    out = [
        "// The CSME 18 map of the ME configuration — emitted by",
        "// `Skills/me-eom-structures/scripts/mfit18_map.py` from Flash Image Tool",
        "// %s's rewritten database: `<nvar>` places and `<ui_item>` words," % name,
        "// nothing here is read out of a dump. See `MEConfigurationMap.swift`",
        "// for what a map is and why each generation has its own.",
        "",
        "import Foundation",
        "",
        "extension MEConfigurationMap {",
        "    /// The ME 18 configuration, as MFIT 18 lays it out.",
        "    public static let csme18 = MEConfigurationMap(",
        '        name: "CSME 18 (Flash Image Tool %s)",' % name,
        "        files: [",
    ]
    for path, alias, settings in files:
        out.append('        File(path: %s, alias: %s, settings: [' %
                   (swift_literal(path), swift_literal(alias)))
        for s in settings:
            args = ["name: %s" % swift_literal(s["name"]),
                    "offset: %d" % s["offset"],
                    "length: %d" % s["length"]]
            if s.get("label") and s["label"] != s["name"]:
                args.append("label: %s" % swift_literal(s["label"]))
            if s.get("help"):
                args.append("help: %s" % swift_literal(s["help"]))
            if s["bits"]:
                args.append("bits: %d...%d" % s["bits"])
            if s["options"]:
                pairs = ", ".join("%d: %s" % (number, swift_literal(word))
                                  for number, word in sorted(s["options"].items()))
                args.append("options: [%s]" % pairs)
            if s["hex"]:
                args.append("hex: true")
            out.append("            Setting(%s)," % ", ".join(args))
        out.append("        ]),")
    out += ["        ])", "}", ""]
    return "\n".join(out)


def lookup(words, name):
    """The panel's words for an nvar. MFIT names a setting in a file with the
    file's own suffix where one name serves several files — `EomFirstBootEnabled_eom_config`,
    `TypeCPortRetimerMCTPSmbusAddr_ncsi` — and the `ui_item` carries the bare
    name; the suffixes are stripped from the right until one answers."""
    candidate = name
    while True:
        if candidate in words:
            return words[candidate]
        cut = candidate.rfind("_")
        if cut <= 0:
            return None
        candidate = candidate[:cut]


def main():
    argv = sys.argv[1:]
    output_format = "swift"
    if "--format" in argv:
        at = argv.index("--format")
        output_format = argv[at + 1]
        del argv[at:at + 2]
    if output_format not in ("swift", "json"):
        print("--format is swift or json", file=sys.stderr)
        return 2
    args = [a for a in argv if not a.startswith("-")]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    version = re.search(r"(\d+(?:\.\d+){1,3})", os.path.basename(path))
    name = version.group(1) if version else os.path.basename(path)
    docs = list(documents(open(path, "rb").read()))
    paths_of = paths(docs)
    words, conflicts = ui_items(docs)
    raw = settings_files(docs)
    if not raw or not paths_of:
        print("no settings database found in this build", file=sys.stderr)
        return 1

    files = []
    skipped = collections.Counter()
    for alias, nvars in raw:
        path_of = paths_of.get(alias)
        if not path_of:
            skipped["no path for alias " + alias] += len(nvars)
            continue
        settings = []
        for setting_name, place, inner in nvars:
            entry = lookup(words, setting_name)
            if entry is None:
                skipped["no ui_item (a path, a string, or a file MFIT names otherwise)"] += 1
                continue
            if setting_name in conflicts:
                skipped["the platform documents disagree about its kind"] += 1
                continue
            kind = entry["kind"]
            if kind in ("path", "string", "hash", "guid", "bitmap"):
                skipped["its kind is not a number (%s)" % kind] += 1
                continue
            if place is None:
                skipped["no place (%s)" % kind] += 1
                continue
            offset_text, length_text = place.group(1), place.group(2)
            bits = ((int(place.group(3)), int(place.group(4)))
                    if place.group(3) is not None else None)
            if length_text == "dynamic":
                if len(nvars) != 1 or kind not in WHOLE_WIDTH:
                    skipped["dynamic length the plugin places"] += 1
                    continue
                offset, length = 0, WHOLE_WIDTH[kind]
            else:
                offset, length = int(offset_text), int(length_text)
            if length <= 0 or offset < 0:
                skipped["no bytes to read"] += 1
                continue
            settings.append({
                "name": setting_name,
                "label": entry["label"],
                "help": entry["help"],
                "section": entry["section"],
                "offset": offset,
                "length": length,
                "bits": bits,
                "options": options_of(entry),
                "hex": kind in HEX_KINDS,
            })
        if settings:
            files.append((path_of, alias, settings))
    files.sort(key=lambda f: (FIRST.index(f[0]) if f[0] in FIRST else len(FIRST), f[0]))
    total = sum(len(f[2]) for f in files)
    print("files with readable settings: %d  settings: %d" % (len(files), total),
          file=sys.stderr)
    for reason, count in sorted(skipped.items(), key=lambda item: -item[1]):
        print("! left out %d: %s" % (count, reason), file=sys.stderr)
    print(json_document(name, files) if output_format == "json"
          else swift(name, files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
