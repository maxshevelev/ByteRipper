#!/usr/bin/env python3
"""Emit a generation's ME configuration map from a FIT build's own resources.

The older FIT (15.0 and its neighbours) carries its layout per platform as zlib
resource streams inside the executable: the settings with their labels, types and
value dictionaries, the MFS files they live in, the straps and the FPF layout.
Where MFIT 16 says where a setting is with a `<LogicalAccess>` record, FIT 15
says it with an action of the `Nvar` module:

    <Action name="ProcessNvar" module="Nvar" target="ProcEmulation"
            params="{'filePath':'$FilePaths/ME_CONF_WRK','cellIndex':'40',
                     'cellOffset':'8','cellSize':'12','bitHi':'3','bitLo':'0',
                     'isBitfield':'true'}" />

so the offset is `cellIndex × cellSize + cellOffset` for a bitfield, or
`startOffset` with `varSize` for a plain field, and the file is reached through
an alias table (`$FilePaths/ME_CONF_WRK` → `policy/cfgmgr/cfg_rules`).

Run it, read the diff and the notes it prints, and paste the file into
`Packages/MEFirmware/Sources/MEFirmware/Configuration/`:

    python3 Skills/me-eom-structures/scripts/fit_map.py <fit-15.0.exe> --straps tgp_lp > \\
        Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME15.swift

Stdlib only, read-only, no network, and the binary is never run.
"""

import hashlib
import re
import sys
import zlib

# The zlib streams inside a FIT build do not all open with the same byte after
# the `0x78` — the usual `0x9C` misses more than half of them.
ZLIB = rb"\x78[\x01\x9c\xda]"

# The value-dictionary classes a tool-wide document carries, by the names they
# are referenced with. They are read from the document's own `<Class>`, not
# written down here, so a platform that adds one is followed.
PATH_CLASSES = {"FilePaths", "IUnitFilePaths"}

# Which layout documents belong to the platform asked for: the ones whose
# `Include` list names its straps (`straps/tgp_lp_a1_straps.xml` for Tiger Lake
# LP, which is ME 15's own platform). The UEP include is no good for this —
# ADL, FHF and others include the same `tgl_uep.xml`.
DEFAULT_STRAPS = "tgp_lp"

# The files a bench reads first, as MFS paths with `/home`. The rest follow the
# tool's own order.
FIRST = [
    "/home/mca/eom_config",
    "/home/mca/eom",
    "/home/mca/mca_oem_version",
    "/home/pavp/hdcp_ports",
    "/home/smbus/smlink_bus",
    "/home/iunit/iunit_oem_cfg",
    "/home/policy/cfgmgr/cfg_rules",
]

HEX_TYPES = {"byte", "word", "dword", "qword"}


def documents(blob):
    """Every zlib stream in the executable that holds a document."""
    seen = set()
    for match in re.finditer(ZLIB, blob):
        try:
            out = zlib.decompressobj().decompress(blob[match.start():match.start() + 20_000_000])
        except Exception:
            continue
        if len(out) < 200:
            continue
        text = out.decode("utf-8", "replace")
        if not text.lstrip().startswith("<"):
            continue
        # The whole document, not its head: every one of them opens with the
        # same Intel licence block, and a head-keyed set keeps exactly one.
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        yield text


def includes(text):
    return re.findall(r'<Include href=":/res/xml/([^"]+)"', text)


def layout_documents(texts, straps):
    """The documents of one platform's layout, as the tool itself names them."""
    chosen = [t for t in texts if "<FtoolLayout" in t and straps in " ".join(includes(t))]
    if not chosen:
        raise SystemExit("no layout document for straps %r in this build" % straps)
    return chosen


def class_members(text, name):
    """The `<CfgOpt>` children of a `<Class>`, as name → value."""
    match = re.search(r'<Class name="%s"[^>]*>(.*?)</Class>' % re.escape(name), text, re.S)
    if not match:
        return None
    return dict(re.findall(r'<CfgOpt name="([^"]+)"\s+value="([^"]*)"', match.group(1)))


def collect_members(texts, names):
    """A class's members over every document that defines it, and what differed."""
    members, conflicts = {}, []
    for text in texts:
        for name in names:
            here = class_members(text, name)
            if not here:
                continue
            for key, value in here.items():
                if name in members and key in members[name] and members[name][key] != value:
                    conflicts.append((name, key, members[name][key], value))
            members.setdefault(name, {}).update(here)
    return members, conflicts


def value_classes(texts):
    """Every class whose members are numbers — the tool's own value dictionaries.

    A class of `<LayoutEntry>` is a structure, not a dictionary: its members
    carry offsets rather than numbers. A class whose members are all numeric is
    one a setting's `type="class:…"` can be resolved against, whatever its name.
    """
    classes = {}
    for text in texts:
        for match in re.finditer(r'<Class name="([^"]+)"[^>]*>(.*?)</Class>', text, re.S):
            name, body = match.group(1), match.group(2)
            if name in PATH_CLASSES or "<LayoutEntry" in body:
                continue
            pairs = re.findall(r'<CfgOpt name="([^"]+)"[^>]*value="([^"]*)"', body)
            numbers = {}
            for label, value in pairs:
                try:
                    numbers[int(value, 0)] = label
                except ValueError:
                    numbers = {}
                    break
            if numbers:
                classes.setdefault(name, {}).update(numbers)
    return classes


def bindings(texts):
    """Every setting's place, as `target` → [(file, params), …], deduplicated.

    The same binding is written in each document of a platform family — three
    of them include the same `tgl_uep.xml` and repeat its settings — so a place
    counts once however many documents carry it. Two *different* places for one
    setting are kept: that is a platform difference, and the caller is told.
    """
    found = {}
    for text in texts:
        for action in re.findall(r"<Action[^>]*module=\"Nvar\"[^>]*>", text):
            target = re.search(r'target="([^"]+)"', action)
            params = re.search(r"params=\"(\{.*?\})\"", action)
            if not target or not params:
                continue
            fields = dict(re.findall(r"'([A-Za-z0-9_]+)':'([^']*)'", params.group(1)))
            file = fields.get("filePath", "")
            if not file.startswith("$"):
                continue          # a file-writing action, not a setting's place
            if not {"cellIndex", "startOffset", "varSize"} & set(fields):
                continue          # nor one that says nothing about where
            places = found.setdefault(target.group(1), [])
            if all(place != (file, fields) for place in places):
                places.append((file, fields))
    return found


def declarations(texts):
    """Each setting's declaration — its type, and the label MFIT gives it."""
    found = {}
    for text in texts:
        for match in re.finditer(r"<CfgOpt\b([^>]*?)/?>", text):
            attrs = dict(re.findall(r'([a-zA-Z_][\w:-]*)="([^"]*)"', match.group(1)))
            name = attrs.get("name")
            if name and name not in found:
                found[name] = attrs
    return found


def place(fields, warnings):
    """A binding's offset, length and bits, or None where it cannot be read.

    Two shapes are in use. A setting inside the config-rule file is a *cell*:
    `cellIndex × cellSize + cellOffset`, with the bits counted in that cell. A
    setting of its own file is a plain field: `startOffset` and `varSize`, with
    the bits counted in the field itself — which is how the EOM record is bound
    (bit 0 of a 2-byte `EOM_Config`).
    """
    if "buildConditional" in fields:
        warnings.append("conditional binding left out (it is one of several, "
                        "and which holds is a build condition): %s" % fields)
        return None
    try:
        if "cellIndex" in fields:
            offset = int(fields["cellIndex"]) * int(fields["cellSize"]) + int(fields["cellOffset"])
            length = int(fields["cellSize"])
        else:
            offset = int(fields.get("startOffset", "0"))
            length = int(fields.get("varSize", "1"))
    except (KeyError, ValueError):
        warnings.append("binding without a place: %s" % fields)
        return None
    bits = None
    if "isBitfield" in fields:
        try:
            low, high = int(fields["bitLo"]), int(fields["bitHi"])
        except (KeyError, ValueError):
            warnings.append("bitfield without its bits: %s" % fields)
            return None
        # Only the bytes the bits need: the neighbouring settings of a cell are
        # other fields, and reading the whole twelve would claim nothing about
        # them while looking like it.
        length = min(length, high // 8 + 1)
        if high >= length * 8:
            warnings.append("bits %d-%d do not fit %d bytes" % (low, high, length))
            return None
        bits = (low, high)
    if length <= 0 or length > 256:
        return None
    return offset, length, bits


def setting_of(name, fields, declarations_, classes, warnings):
    """One setting of one file, as the map lays it out.

    `label` is the tool's own name for the setting — what its panel shows —
    where the declaration states one, which is where the two differ: the
    identifier is `name` (`MELanPowerWell`, `PttSupported`), the interface text
    is `label` ("LAN Power Well", "Intel(R) PTT Supported").
    """
    where = place(fields, warnings)
    if where is None:
        return None
    offset, length, bits = where
    declaration = declarations_.get(name, {})
    kind = declaration.get("type", "")
    options = classes.get(kind.split(":", 1)[1]) if kind.startswith("class:") else None
    return {
        "name": name,
        "label": declaration.get("label"),
        "offset": offset,
        "length": length,
        "bits": bits,
        "options": options,
        "hex": kind in HEX_TYPES,
        "text": kind == "string" and "nullTerminate" in fields,
    }


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def swift(files):
    out = []
    for path in FIRST + [p for p in files if p not in FIRST]:
        if path not in files:
            continue
        entry = files[path]
        out.append("        File(path: %s, alias: %s, settings: [" %
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
            if s["bits"]:
                args.append("bits: %d...%d" % s["bits"])
            if s["options"]:
                pairs = ", ".join("%d: %s" % (n, swift_literal(s["options"][n]))
                                  for n in sorted(s["options"]))
                args.append("options: [%s]" % pairs)
            if s["hex"]:
                args.append("hex: true")
            if s["text"]:
                args.append("text: true")
            out.append("            Setting(%s)," % ", ".join(args))
        out.append("        ]),")
    return "\n".join(out)


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
    args, straps = option(args, "--straps", DEFAULT_STRAPS)
    # Which generation's map this is, and which tool it was read from: the
    # emitted file names both, and the paths inside it are the tool's own.
    args, generation = option(args, "--generation", "15")
    args, tool = option(args, "--tool", "15.0")
    blob = open(args[0], "rb").read()

    texts = list(documents(blob))
    chosen = layout_documents(texts, straps)
    warnings = []
    members, conflicts = collect_members(texts, PATH_CLASSES)
    classes = value_classes(texts)
    rules = bindings(chosen)
    declarations_ = declarations(texts)

    # The End of Manufacturing record is the one thing a layout of the newer
    # families does not bind: the tool writes it through its own `EomNvar`, and
    # only the older layouts carry the action. Filled in from those, and only
    # for the settings that are *of that record* — a document that binds
    # `EOM_Config` — because the older layouts also name the single byte of
    # `mca/eom` `EOM` and `EndOfManufacturing`, which are their words for one
    # field and not three.
    every = bindings(texts)
    record = {target for target, places in every.items()
              if any(file.endswith("EOM_Config") for file, _ in places)}
    for target in sorted(record):
        if target not in rules:
            rules[target] = every[target]

    files = {}
    for target, places in sorted(rules.items()):
        for reference, fields in places:
            table, _, alias = reference[1:].partition("/")
            path = members.get(table, {}).get(alias)
            if not path:
                warnings.append("no path for %s (%s)" % (reference, target))
                continue
            setting = setting_of(target, fields, declarations_, classes, warnings)
            if setting is None:
                continue
            path = "/home/" + path
            entry = files.setdefault(path, {"alias": alias, "settings": [], "seen": set()})
            if setting["name"] in entry["seen"]:
                warnings.append("%s is bound twice in %s" % (target, path))
                continue
            entry["seen"].add(setting["name"])
            entry["settings"].append(setting)

    for entry in files.values():
        del entry["seen"]
    readable = sum(len(f["settings"]) for f in files.values())
    print("layout documents: %d  files: %d  settings: %d"
          % (len(chosen), len(files), readable), file=sys.stderr)
    for warning in warnings:
        print("! %s" % warning, file=sys.stderr)

    print("// The CSME %s map of the ME configuration — emitted by" % generation)
    print("// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool %s's" % tool)
    print("// own layout documents (the %s platform of ME %s)." % (straps, generation))
    print("// Offsets, bits, the tool's own name for each setting (`label`), its option")
    print("// labels and the file paths are FIT's, copied out of its")
    print("// `ProcessNvar` bindings and value dictionaries; nothing here is read out of a")
    print("// dump. FIT %s marks no setting `Auto` — it has no such attribute — so no" % tool)
    print("// setting here carries that mark.")
    print("//")
    print("// A generation's map lives in a file of its own: see `MEConfigurationMap.swift`")
    print("// for what a map is and why each generation has its own.")
    print()
    print("import Foundation")
    print()
    print("extension MEConfigurationMap {")
    print("    /// The ME %s configuration, as FIT %s lays it out. The files stand in the" % (generation, tool))
    print("    /// order a bench reads them, and the rest in the tool's own order.")
    print("    public static let csme%s = MEConfigurationMap(" % generation)
    print('        name: "CSME %s (Flash Image Tool %s)",' % (generation, tool))
    print("        files: [")
    print(swift(files))
    print("        ])")
    print("}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
