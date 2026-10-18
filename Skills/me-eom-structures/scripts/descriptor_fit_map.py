"""Emit a descriptor generation's register layouts from FIT's platform documents.

The older FIT builds state the descriptor's registers as `<Class>` bodies of
bitfields, one per register:

    <Class name="FLMAP1">
      <LayoutEntry name="Flmap1_PCH_Strap_Length" type="bitfield32" value="0"
                   offset="0x00" bitfield_high="31" bitfield_low="24"/>
      …

The build carries one such set per platform, and a platform's documents are
the FtoolLayouts whose `Include` list names its straps; `--platform` is the
token to match (`tgp_lp` for Tiger Lake LP, `cnp_h` for Cannon Point H). The
register's own place in the descriptor is stated here, not by the class:
`FLMAP0/1/2/3` at 0x14, 0x18, 0x1C and 0x20, `FLVALSIG` at 0x10,
`FLCOMP`/`FLILL`/`FLILL1` at the flash component base, `FLMSTR1`…`FLMSTR6` at
the flash master base and `FLUMAP1` at 0xEFC.

**A field is kept only where every selected document states it identically** —
same bit offset and width. FIT's platform documents disagree about some bits
(a density field's width, a platform-only touch bit), and a generation-wide
map that guessed would name a reserved bit. Labels and option words come from
the configuration classes the class's `Action`s bind each field to
(`$HostCpuBiosMasterAccess/HostCpuReadAccess` → "BIOS Region Write Access"),
as they do for the UEP map.

    python3 descriptor_fit_map.py <fit-15.0.exe> [<fit-14.0.exe> …] \\
        --platform tgp_lp --generation tigerPoint --tool 15.0 > \\
        Packages/UEFIImage/Sources/UEFIImage/DescriptorRegisterMap+TigerPoint.swift

`--platform` takes a comma-separated list of strap tokens (a generation's two
halves are two documents), and several executables may be named: one
generation's documents are spread over its builds.

Stdlib only, read-only, no network.
"""

import collections
import hashlib
import os
import re
import sys
import zlib

# Register name → place, in the descriptor. `absolute` is a byte offset from
# the descriptor's start; `flashComponent`/`flashMaster` are offsets from the
# base the map words state.
REGISTERS = [
    ("FLVALSIG", "absolute", 0x010),
    ("FLMAP0", "absolute", 0x014),
    ("FLMAP1", "absolute", 0x018),
    ("FLMAP2", "absolute", 0x01C),
    ("FLMAP3", "absolute", 0x020),
    ("FLCOMP", "flashComponent", 0x000),
    ("FLILL", "flashComponent", 0x004),
    ("FLILL1", "flashComponent", 0x008),
    ("FLMSTR1", "flashMaster", 0x000),
    ("FLMSTR2", "flashMaster", 0x004),
    ("FLMSTR3", "flashMaster", 0x008),
    ("FLMSTR4", "flashMaster", 0x00C),
    ("FLMSTR5", "flashMaster", 0x010),
    ("FLMSTR6", "flashMaster", 0x014),
    ("FLUMAP1", "absolute", 0xEFC),
]

ENTRY = re.compile(r"<LayoutEntry ([^>]*)/?>")
ACTION = re.compile(r"<Action ([^>]*?)/?>")


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
            out = zlib.decompressobj().decompress(
                blob[match.start():match.start() + 40_000_000])
        except Exception:
            continue
        if len(out) < 200:
            continue
        try:
            text = out.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if not text.lstrip().startswith("<"):
            continue
        digest = hashlib.sha1(out).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        yield text


def attrs_of(text):
    return dict(re.findall(r'([A-Za-z_][\w:.-]*)="([^"]*)"', text))


def includes(text):
    return re.findall(r'<Include href=":/res/xml/([^"]+)"', text)


def layout_documents(texts, platforms):
    """The documents of the platform(s) named, by the strap includes they
    state. A comma-separated list takes several (`cnp_lp_rvp,cnp_h_rvp`):
    a generation's two halves are two layout documents, and its registers may
    be spread over them."""
    tokens = [token.strip() for token in platforms.split(",") if token.strip()]
    chosen = [t for t in texts if "<FtoolLayout" in t
              and any(token in " ".join(includes(t)) for token in tokens)]
    if not chosen:
        raise SystemExit("no layout document for platform(s) %r" % platforms)
    return chosen


def classes(text):
    for match in re.finditer(r'<Class name="([^"]+)"[^>]*>(.*?)</Class>',
                             text, re.S):
        yield match.group(1), match.group(2)


def fields_of(body):
    """The class's fields: name → (bitOffset, count), and the source bound."""
    fields = {}
    bindings = {}
    for match in ENTRY.finditer(body):
        attrs = attrs_of(match.group(1))
        name = attrs.get("name")
        offset = attrs.get("offset", "0")
        high = attrs.get("bitfield_high")
        low = attrs.get("bitfield_low")
        if not name or high is None or low is None:
            continue
        try:
            bit = int(offset, 0) * 8 + int(low)
            count = int(high) - int(low) + 1
        except ValueError:
            continue
        fields[name] = (bit, count)
    for match in ACTION.finditer(body):
        attrs = attrs_of(match.group(1))
        if attrs.get("module") != "Bin" or attrs.get("name") != "GetValue":
            continue
        source = attrs.get("source", "")
        target = attrs.get("target", "")
        if source.startswith("$") and "/" in source:
            bindings[target] = source[1:].split("/")
    return fields, bindings


def value_classes(texts):
    tables = collections.defaultdict(lambda: collections.defaultdict(list))
    for text in texts:
        for name, body in classes(text):
            numbers = {}
            ok = True
            for match in re.finditer(r'<CfgOpt ([^>]*)/?>', body):
                attrs = attrs_of(match.group(1))
                if attrs.get("label"):
                    ok = False
                    break
                try:
                    numbers[int(attrs.get("value", ""), 0)] = attrs["name"]
                except (ValueError, KeyError):
                    ok = False
                    break
            if ok and len(numbers) >= 2:
                for number, word in numbers.items():
                    tables[name][number].append(word)
    out = {}
    for name, by_number in tables.items():
        out[name] = {number: collections.Counter(words).most_common(1)[0][0]
                     for number, words in by_number.items()}
    return out


def setting_words(texts):
    """Label, help and value class of every `Class/Option` a document states."""
    found = collections.defaultdict(lambda: {"labels": [], "helps": [],
                                             "types": []})
    for text in texts:
        for name, body in classes(text):
            for match in re.finditer(r'<CfgOpt ([^>]*)/?>', body):
                attrs = attrs_of(match.group(1))
                option = attrs.get("name")
                if not option:
                    continue
                key = (name, option)
                if attrs.get("label"):
                    found[key]["labels"].append(attrs["label"])
                if attrs.get("help"):
                    found[key]["helps"].append(attrs["help"])
                if attrs.get("type", "").startswith("class:"):
                    found[key]["types"].append(attrs["type"][len("class:"):])
    words = {}
    for key, entry in found.items():
        words[key] = {
            "label": (collections.Counter(entry["labels"]).most_common(1)[0][0]
                      if entry["labels"] else None),
            "help": max(entry["helps"], key=len) if entry["helps"] else None,
            "class": (collections.Counter(entry["types"]).most_common(1)[0][0]
                      if entry["types"] else None),
        }
    return words


def unescaped(text):
    if not text:
        return text
    for entity, character in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'),
                              ("&apos;", "'"), ("&amp;", "&")):
        text = text.replace(entity, character)
    return re.sub(r"\r\n?", "\n", text).strip()


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    args, platform = option(args, "--platform", None)
    args, generation = option(args, "--generation", None)
    args, tool = option(args, "--tool", None)
    if not platform or not generation or not args:
        print(__doc__)
        return 2
    paths = [a for a in args if not a.startswith("-")]
    tool = tool or " + ".join(os.path.splitext(os.path.basename(p))[0]
                              for p in paths)
    # Several builds may be named: one platform's documents are spread over
    # them (the CNP build at hand states FLMAP1 and FLCOMP, FIT 13's CNP
    # documents FLMAP0, FIT 14's FLMAP2), and a field is kept only where every
    # document that states its register states it the same way.
    texts = []
    for path in paths:
        texts.extend(documents(open(path, "rb").read()))
    chosen = layout_documents(texts, platform)
    values = value_classes(texts)
    words = setting_words(texts)

    # Each register's fields across the platform's documents: a field survives
    # only where every document that states the register states it identically.
    registers = []
    for name, kind, offset in REGISTERS:
        stated = []
        for text in chosen:
            for class_name, body in classes(text):
                if class_name != name:
                    continue
                stated.append(fields_of(body))
        if not stated:
            continue
        shared = None
        definitions = collections.defaultdict(set)
        bindings = {}
        for fields, bound in stated:
            keys = set(fields)
            shared = keys if shared is None else shared & keys
            for key, definition in fields.items():
                definitions[key].add(definition)
            for target, source in bound.items():
                bindings.setdefault(target, source)
        dropped = [key for key in (shared or set())
                   if len(definitions[key]) > 1]
        kept = [key for key in (shared or set()) if len(definitions[key]) == 1]
        if not kept:
            continue
        entries = []
        for key in sorted(kept, key=lambda k: (list(
                next(iter(definitions[k])))[0], k)):
            bit, count = next(iter(definitions[key]))
            label = None
            options = None
            source = bindings.get(key)
            if source and len(source) >= 2:
                entry = words.get((source[0], source[1]), {})
                label = entry.get("label")
                options = values.get(entry.get("class") or "")
            entries.append((key, bit, count, label, options))
        registers.append((name, kind, offset, entries))
        if dropped:
            print("  %s: dropped %d field(s) the documents disagree on: %s"
                  % (name, len(dropped), ", ".join(sorted(dropped)[:6])),
                  file=sys.stderr)

    if not registers:
        print("no register classes for platform %r in this build" % platform,
              file=sys.stderr)
        return 1

    lines = [
        "// The flash descriptor's registers of %s, as %s lays them out —" % (
            generation, tool),
        "// emitted by `Skills/me-eom-structures/scripts/descriptor_fit_map.py`",
        "// from the tool's own platform documents (%s). Names, places, labels" % platform,
        "// and option words are the tool's; nothing here is read out of a dump.",
        "//",
        "// A field is kept only where every document of the platform states it",
        "// identically; a bit they disagree about is left out.",
        "",
        "import Foundation",
        "",
        "extension DescriptorRegisterMap {",
        "    public static let %s = DescriptorRegisterMap(registers: [" % generation,
    ]
    for name, kind, offset, entries in registers:
        place = {"absolute": ".absolute(0x%X)", "flashComponent":
                 ".flashComponent(offset: 0x%X)", "flashMaster":
                 ".flashMaster(offset: 0x%X)"}[kind] % offset
        lines.append('        Register(name: %s, place: %s, words: 1, fields: ['
                     % (swift_literal(name), place))
        for key, bit, count, label, options in entries:
            args_out = ["name: %s" % swift_literal(key),
                        "bitOffset: %d" % bit, "count: %d" % count]
            if label:
                args_out.append("label: %s" % swift_literal(unescaped(label)))
            if options:
                pairs = ", ".join("%d: %s" % (number, swift_literal(word))
                                  for number, word in sorted(options.items()))
                args_out.append("options: [%s]" % pairs)
            lines.append("            Field(%s)," % ", ".join(args_out))
        lines.append("        ]),")
    lines += ["    ])", "}", ""]
    print("\n".join(lines))
    print("registers: %d (%s)" % (len(registers),
                                 ", ".join(r[0] for r in registers)),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
