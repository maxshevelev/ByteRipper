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

The bindings are read from the platform layout and every document it includes,
transitively: the platform document carries that build's straps, while the
settings the family shares are bound in its `*_common.xml` — Boot Guard's
policy files, the EOM record and the FPF hardware binding among them.

Run it, read the diff and the notes it prints, and write the JSON (which the
compiler reads, `Design/MAP_DATA.md`) under `MapSources/configuration/`:

    python3 Skills/me-eom-structures/scripts/fit_map.py <fit-15.0.exe> \\
        --straps tgp_lp --generation 15 --tool 15.0 --format json > \\
        Packages/MEFirmware/MapSources/configuration/csme15.json

Stdlib only, read-only, no network, and the binary is never run.
"""

import hashlib
import json
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

# How wide a setting is where the tool names its place by a file alone. A value
# class is an enumerated number (`DisabledEnabledValues`: 0 Disabled, 1
# Enabled), one byte in every such file at hand; the numeric types state their
# own width. `path`, `string` and `bitmap` say nothing this can read as a
# number, and `target="this"` is the file itself, not a setting.
WHOLE_WIDTH = {"byte": 1, "word": 2, "dword": 4, "qword": 8}


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


# A document's own file name is in the licence comment at its head, where the
# tool's build left it. Most documents carry a copy-paste name that is not
# theirs (`cnp_fit_layout_lp_1_6.xml` is written in 26 of FIT 12's documents),
# so a name never identifies a document on its own; it is used to resolve an
# include, and a name several documents share is settled by
# `included_layout_documents` from what the including layout refers to.
DECLARED_NAME = re.compile(r"File Name:\s*\n+\s*([^\s<]+)")


def declared_name(text):
    """The file name a document gives itself, lower-cased, or None."""
    match = DECLARED_NAME.search(text[:8000])
    return match.group(1).lower() if match else None


def class_names(text):
    return set(re.findall(r'<Class name="([^"]+)"', text))


def class_references(text):
    """The classes a document names as types or parents — what its includes
    are for. A layout defines some of its classes itself and depends on the
    files it includes for the rest, so the references say which include
    document the layout was written against."""
    found = set(re.findall(r'type="class:([A-Za-z0-9_]+)"', text))
    found |= set(re.findall(r'<ParentCandidate value="([^"]+)"', text))
    return found


def included_layout_documents(texts, chosen):
    """The chosen layouts and everything they include, transitively.

    A layout is one document only at the top: the platform document carries
    the strap differences of one build, while the settings every platform of
    the family has — the FPF hardware binding, the ICC profile keys, Boot
    Guard's policy files — are bound in the `*_common.xml` it includes.
    Reading the bindings of the chosen document alone leaves those settings
    out of the map, so the closure is what the bindings are read from.

    An include names a file, and the packed documents do not always carry
    unique names: FIT 15 holds two documents called
    `lkf_fit_layout_1_7_common.xml`, a Braswell-era one and the real 1.7
    common. Where a name is shared, the document that defines the most
    classes the including layout refers to is the one it was written against
    (114 of 191 against 55); a tie keeps the tool's own order.
    """
    by_name = {}
    for text in texts:
        name = declared_name(text)
        if name:
            by_name.setdefault(name, []).append(text)
    closure, seen = [], set()
    queue = list(chosen)
    while queue:
        text = queue.pop(0)
        if id(text) in seen:
            continue
        seen.add(id(text))
        closure.append(text)
        references = class_references(text)
        for href in includes(text):
            candidates = [c for c in by_name.get(href.split("/")[-1].lower(), [])
                          if id(c) not in seen]
            if not candidates:
                continue    # a strap or UEP document, or one whose name is not its own
            candidates.sort(key=lambda c: len(references & class_names(c)),
                            reverse=True)
            queue.append(candidates[0])
    return closure


CLASS = re.compile(r'<Class name="([^"]+)"[^>]*>(.*?)</Class\s*>', re.S)


def class_blocks(text):
    """Every `<Class>` the document closes before its next opening.

    The tools leave a class or two unclosed, and the block regex reads such a
    class through to the next `</Class>` — which is the following class's. That
    is not a loss the count below can see; this pairing is what the count of
    well-formed blocks is compared with.
    """
    out = []
    for match in re.finditer(r'<Class\b([^>]*)>', text):
        if match.group(0).rstrip().endswith("/>"):
            continue
        following = text.find("<Class", match.end())
        close = re.search(r'</Class\s*>', text[match.end():
                                                following if following >= 0 else len(text)])
        if close is None:
            continue
        name = re.search(r'name="([^"]*)"', match.group(1))
        out.append((name.group(1) if name else "",
                    text[match.end():match.end() + close.start()]))
    return out


def class_members(text, name):
    """The `<CfgOpt>` children of a `<Class>`, as name → value."""
    match = re.search(r'<Class name="%s"[^>]*>(.*?)</Class\s*>' % re.escape(name),
                      text, re.S)
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
        for match in CLASS.finditer(text):
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
            # The action's own attributes, not its params: what a conditional
            # place holds under (`source`, e.g. `eSpiEnabled`) is an attribute.
            source = re.search(r'source="([^"]*)"', action)
            fields["__source"] = source.group(1) if source else "null"
            file = fields.get("filePath", "")
            if not file.startswith("$"):
                continue          # a file-writing action, not a setting's place
            if not {"cellIndex", "startOffset", "varSize"} & set(fields):
                # Nor one that names only its file: those are settings the file
                # *is* (`/home/bup/bup_sku/hw_binding`), and the whole-file
                # writes the tool does for certificates — `setting_of` sorts
                # them out by the declaration's type, and names what it cannot
                # read as a number.
                fields["__whole"] = "true"
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
    if "buildConditional" in fields and not fields.get("conditionalVal"):
        warnings.append("conditional binding without the value it holds under: %s" % fields)
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


def setting_of(name, fields, declarations_, classes, warnings, skipped=None):
    """One setting of one file, as the map lays it out.

    `label` is the tool's own name for the setting — what its panel shows —
    where the declaration states one, which is where the two differ: the
    identifier is `name` (`MELanPowerWell`, `PttSupported`), the interface text
    is `label` ("LAN Power Well", "Intel(R) PTT Supported").

    A place the tool names by its file alone is the file itself: its width comes
    from the declaration's type, and a type this cannot read as a number is put
    in `skipped`, for the caller to list.
    """
    declaration = declarations_.get(name, {})
    kind = declaration.get("type", "")
    if fields.get("__whole"):
        width = WHOLE_WIDTH.get(kind) or (1 if kind.startswith("class:") else None)
        if width is None:
            if name != "this" and skipped is not None:
                skipped[name] = kind or "no declaration"
            return None
        offset, length, bits = 0, width, None
    else:
        where = place(fields, warnings)
        if where is None:
            return None
        offset, length, bits = where
    condition = None
    if fields.get("buildConditional") == "true":
        condition = condition_of(fields, name, declarations_, classes, warnings)
        if condition is None:
            return None
    options = classes.get(kind.split(":", 1)[1]) if kind.startswith("class:") else None
    return {
        "name": name,
        "label": declaration.get("label"),
        "help": unescaped(declaration.get("help")),
        "condition": condition,
        "offset": offset,
        "length": length,
        "bits": bits,
        "options": options,
        "hex": kind in HEX_TYPES,
        "text": kind == "string" and "nullTerminate" in fields,
    }


def condition_value(source, word, declarations_, classes, warnings, target):
    """The number a condition's word stands for, off the condition setting's own
    value class — `eSpiEnabled = No` is `NoYesValues`' 0, and `= Yes` is 1."""
    declaration = declarations_.get(source, {})
    kind = declaration.get("type", "")
    options = classes.get(kind.split(":", 1)[1]) if kind.startswith("class:") else None
    if options:
        for number, label in options.items():
            if label == word:
                return number
    warnings.append("condition %s = %r of %s has no number in its class %r"
                    % (source, word, target, options))
    return None


def condition_of(fields, name, declarations_, classes, warnings):
    """The condition a place holds under: the other setting, and the number its
    word stands for. None where either cannot be stated — a place the map
    cannot name the condition of is not a place it claims."""
    source = fields.get("__source", "null")
    word = fields.get("conditionalVal", "")
    if not source or source == "null" or not word:
        warnings.append("conditional place of %s without a condition: %s" % (name, fields))
        return None
    number = condition_value(source, word, declarations_, classes, warnings, name)
    return (source, number) if number is not None else None


def switched_off(texts, declarations_, classes, warnings):
    """The settings the tool switches off under a condition — its `DisableIf`
    actions, which are the `Fit` module's rather than `Nvar`'s: `SmlinkBusSelection`
    does not apply where eSPI is on. Returns `target` → (source, number)."""
    found = {}
    for text in texts:
        for action in re.findall(r"<Action[^>]*name=\"DisableIf\"[^>]*>", text):
            source = re.search(r'source="([^"]*)"', action)
            target = re.search(r'target="([^"]*)"', action)
            word = re.search(r"'sourceVal':'([^']*)'", action)
            if not (source and target and word):
                continue
            number = condition_value(source.group(1), word.group(1), declarations_,
                                     classes, warnings, target.group(1))
            if number is not None:
                found.setdefault(target.group(1), (source.group(1), number))
    return found


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
            if s.get("help"):
                args.append("help: %s" % swift_literal(s["help"]))
            # Where the place holds only under another setting's value, and
            # where the tool switches the setting off.
            if s.get("condition"):
                args.append("condition: Condition(name: %s, value: %d)" % (
                    swift_literal(s["condition"][0]), s["condition"][1]))
            if s.get("disabledBy"):
                args.append("disabledBy: Condition(name: %s, value: %d)" % (
                    swift_literal(s["disabledBy"][0]), s["disabledBy"][1]))
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


def setting_json(setting):
    entry = {"name": setting["name"],
             "offset": setting["offset"],
             "length": setting["length"]}
    if setting.get("label") and setting["label"] != setting["name"]:
        entry["label"] = setting["label"]
    if setting.get("help"):
        entry["help"] = setting["help"]
    if setting.get("condition"):
        entry["condition"] = {"name": setting["condition"][0],
                              "value": setting["condition"][1]}
    if setting.get("disabledBy"):
        entry["disabledBy"] = {"name": setting["disabledBy"][0],
                               "value": setting["disabledBy"][1]}
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


def json_document(files, generation, tool, straps, variable):
    ordered = [path for path in FIRST + [p for p in files if p not in FIRST]
               if path in files]
    return pretty_json({
        "schema": "byteripper.map/1",
        "kind": "configuration",
        "tool": tool,
        "maps": [{
            "id": variable,
            "name": "CSME %s (Flash Image Tool %s, %s)"
                    % (generation, tool, straps),
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
    args, straps = option(args, "--straps", DEFAULT_STRAPS)
    # Which generation's map this is, and which tool it was read from: the
    # emitted file names both, and the paths inside it are the tool's own.
    args, generation = option(args, "--generation", "15")
    args, tool = option(args, "--tool", "15.0")
    # The Swift name the map is published under, where a generation has more
    # than one: the mobile family keeps `csme15`, the desktop one is
    # `csme15Desktop`.
    args, variable = option(args, "--variable", "csme%s" % generation)
    args, output_format = option(args, "--format", "swift")
    if output_format not in ("swift", "json"):
        print("--format is swift or json", file=sys.stderr)
        return 2
    blob = open(args[0], "rb").read()

    texts = list(documents(blob))
    # A well-formed class the block regex did not read is a class whose
    # settings or value words are now missing; a class the tool left unclosed
    # is not counted here (see `class_blocks`).
    for text in texts:
        stated = len(class_blocks(text))
        matched = len(CLASS.findall(text))
        if stated != matched:
            print("! %d of %d well-formed <Class> blocks did not parse"
                  % (stated - matched, stated), file=sys.stderr)
    chosen = layout_documents(texts, straps)
    # The chosen layout and the common documents it includes: the bindings of
    # both, or every setting the family shares is missing from the map.
    layout = included_layout_documents(texts, chosen)
    warnings = []
    members, conflicts = collect_members(texts, PATH_CLASSES)
    classes = value_classes(texts)
    rules = bindings(layout)
    declarations_ = declarations(texts)

    # The End of Manufacturing record is the one thing a layout of the newer
    # families does not bind: the tool writes it through its own `EomNvar`, and
    # only the older layouts carry the action. Filled in from those, and only
    # for the settings that are *of that record* — a document that binds
    # `EOM_Config` — because the older layouts also name the single byte of
    # `mca/eom` `EOM` and `EndOfManufacturing`, which are their words for one
    # field and not three.
    off = switched_off(layout, declarations_, classes, warnings)
    skipped = {}
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
            setting = setting_of(target, fields, declarations_, classes, warnings, skipped)
            if setting is None:
                continue
            if target in off:
                setting["disabledBy"] = off[target]
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
    print("layout documents: %d (+%d included)  files: %d  settings: %d"
          % (len(chosen), len(layout) - len(chosen), len(files), readable),
          file=sys.stderr)
    for warning in warnings:
        print("! %s" % warning, file=sys.stderr)
    if skipped:
        print("not read — places the tool names by a file alone, of a type this does not "
              "read as a number: %s"
              % ", ".join("%s (%s)" % (name, kind) for name, kind in sorted(skipped.items())),
              file=sys.stderr)

    if output_format == "json":
        print(json_document(files, generation, tool, straps, variable))
        return 0

    print("// The CSME %s map of the ME configuration — emitted by" % generation)
    print("// `Skills/me-eom-structures/scripts/fit_map.py` from Flash Image Tool %s's" % tool)
    print("// own layout documents (the %s platform of ME %s)." % (straps, generation))
    print("//")
    print("// The family is the tool's own name for the platform half: `_lp`/`_p` is")
    print("// the mobile one and `_h`/`_s` the desktop one, and a dump is read with")
    print("// the one its descriptor's strap section length names")
    print("// (`MEConfigurationMap.forME(major:family:)`).")
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
    print("    public static let %s = MEConfigurationMap(" % variable)
    print('        name: "CSME %s (Flash Image Tool %s, %s)",' % (generation, tool, straps))
    print("        files: [")
    print(swift(files))
    print("        ])")
    print("}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
