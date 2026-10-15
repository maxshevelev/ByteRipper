#!/usr/bin/env python3
"""Emit a generation's ME configuration map from an MFIT build's own database.

MFIT carries its settings database as zlib-compressed XML inside `mfit.exe`: one
document per platform list (ADL-S, MTL-M, MTL-S, ELG in the 16.0.15 build), each
listing the MFS files, the settings that live in them, the byte offset and bits
of each, the values it may take, and who writes it (`process_type`).

Run it, read the diff, and paste the file into
`Packages/MEFirmware/Sources/MEFirmware/Configuration/`:

    python3 Skills/me-eom-structures/scripts/mfit_map.py <mfit.exe> > \\
        Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME16.swift

Stdlib only, read-only, no network. The script decides nothing about what a
value *means*: it copies MFIT's own labels, offsets and option numbers, and says
on stderr what it left out.
"""

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

# The enumerated kinds, with the words MFIT gives their two values. A
# `fixed_options` setting carries its own list in `config_params` instead.
YES_NO = {0: "No", 1: "Yes"}
DISABLED_ENABLED = {0: "Disabled", 1: "Enabled"}
TWO_KINDS = {
    "no_yes_options": YES_NO,
    "yes_no_options": YES_NO,
    "disabled_enabled_options": DISABLED_ENABLED,
    "enabled_disabled_options": DISABLED_ENABLED,
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

PROJECT = "16.0.15.1662"


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

    A setting with no place in the file (`length="0"` — most of the database:
    values the tool computes, certificates, the ICC profiles) is left out: it
    cannot be read out of bytes, and a row that is always empty is not a fact
    about a dump.
    """
    found = []
    for match in re.finditer(r'<LogicalAccess name="([^"]+)"([^>]*)>(.*?)</LogicalAccess>',
                             body, re.S):
        name, attrs, inner = match.group(1), match.group(2), match.group(3)
        place = re.search(r'offset="(-?\d+)" length="(\d+)"(?: bit_low="(\d+)" bit_high="(\d+)")?',
                          inner)
        if not place:
            continue
        offset, length = int(place.group(1)), int(place.group(2))
        if length <= 0 or offset < 0:
            continue
        bits = (int(place.group(3)), int(place.group(4))) if place.group(3) is not None else None
        kind = re.search(r'config_type="([^"]*)"', inner)
        kind = kind.group(1) if kind else None
        physical = re.search(r'physical_type="([^"]*)"', inner)
        physical = physical.group(1) if physical else None
        found.append({
            "name": name,
            "offset": offset,
            "length": length,
            "bits": bits,
            "options": options_of(attrs, inner),
            "auto": 'process_type="%s"' % AUTO in attrs,
            "hex": kind in HEX_KINDS,
            "text": kind == "string" and physical == "String",
        })
    return found


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
        for match in re.finditer(r'<File path="([^"]+)"[^>]*alias="([^"]*)"[^>]*>(.*?)</File>',
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
                elif known[setting["name"]] != setting:
                    conflicts.append((path, setting["name"],
                                      known[setting["name"]], setting))
    for path, name, _, _ in conflicts:
        files[path]["settings"] = [s for s in files[path]["settings"]
                                   if s["name"] != name]
    return files, conflicts


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


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


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    blob = open(sys.argv[1], "rb").read()
    texts = list(documents(blob))
    if not texts:
        print("no platform list found in this build", file=sys.stderr)
        return 1
    files, conflicts = collect(texts)
    readable = sum(len(f["settings"]) for f in files.values())
    print("platform lists: %d  files with readable settings: %d  settings: %d"
          % (len(texts), len(files), readable), file=sys.stderr)
    for path, name, there, here in conflicts:
        print("! dropped %s %s: the lists lay it out differently (%s / %s)" %
              (path, name, there, here), file=sys.stderr)
    print("// The CSME 16 map of the ME configuration — emitted by")
    print("// `Skills/me-eom-structures/scripts/mfit_map.py` from Flash Image Tool")
    print("// %s's own settings database, which is the build that wrote the CSME 16" % PROJECT)
    print("// images this was verified against. Offsets, bits, option labels and the")
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
    print('        name: "CSME 16 (Flash Image Tool %s)",' % PROJECT)
    print('        files: [')
    print(swift(files))
    print('        ])')
    print('}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
