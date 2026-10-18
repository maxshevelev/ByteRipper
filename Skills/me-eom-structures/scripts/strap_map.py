"""Emit the strap fields of a descriptor section for the engine and the panel.

The Flash Image Tool executables carry the chipset's strap layout as their own
resources — `<LayoutEntry name="PCH_Strap_SPI_ec_max_freq" type="bitfield32"
value="0x4" offset="0x50" bitfield_high="5" bitfield_low="3"/>` — a name, the
byte offset of the word the field sits in, the bits it takes, and the value the
tool builds the strap with. The older FIT 11 build writes the same straps with
no underscore after the prefix more often (`PchStrapGlobalProtectedRangeDefault`),
and both spellings are read. That is the specification the panel has been
missing: the descriptor's strap section is a list of words, and until now only
two of its fields could be named.

A table is picked by the length of the section it describes — the words the
descriptor's own FLMAP1 states — because that is what an image states about
itself and what the panel can ask by. The length is a good key: the 69-word and
74-word sections are the same field for field in every tool that carries them,
and the two 70-word tables differ only in their defaults and in two spellings.

Where one length has several documents, the one that names itself in its own
header wins — `File Name: cnp_h_rvp.xml`, which is how the 90-word section is
told from a nameless document of the same length whose fields sit elsewhere
entirely. Otherwise the newest tool's table is taken.

    python3 strap_map.py fit-15.0.exe fit-14.0.exe --words 69,70,74,90,101

Prints a Swift file for `Packages/UEFIImage/Sources/UEFIImage/StrapMap+PCH.swift`
and says on stderr what it found, including where the two fields the engine
reads by name — the tool's own `SPI_ec_max_freq` and
`SPI_GLOBAL_PROTECTED_RNG_DEF` — sit in each table. A table that carries
neither names a generation whose straps say nothing about them.

`--kind cpu` reads the processor strap section's table instead, whose entries
are `CPU_Strap_*` and whose offsets are relative to that section's own base;
its length is the one the descriptor's `FLMAP2` states, not `FLMAP1`.

The processor layout is the weaker key: unlike the PCH section, two documents
of one length can disagree — a field's width, or which bits are reserved — and
a dump states nothing else about which of them it was built from. So a
processor table keeps only the fields **every** document of that length states
identically (same name, offset and bits), with the newest self-named document's
default; a field the documents disagree about is left out rather than guessed.
"""

import collections
import hashlib
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
    """Every zlib stream in the executable that holds a document, and the name
    the document gives itself where it gives one."""
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
        head = text[:text.find("<LayoutEntry")] if "<LayoutEntry" in text else text[:2000]
        named = re.search(r"File Name:\s*(\S+)", head)
        yield text, (named.group(1) if named else None)


STRAP_NAME = re.compile(
    r"^(?:(?:CPU|PCH|PMC|SA)_Strap_|(?:Pch|Cpu|Pmc|Sa)Strap)")
ATTR = re.compile(r'([A-Za-z_][\w:.-]*)="([^"]*)"')


def entries_of(body):
    """The class's bitfields, whatever order it writes the attributes in —
    FIT 11's SPT documents put `bitfield_low` before `bitfield_high` where the
    newer ones do the reverse. The last item says whether the name is a strap
    name: a reserved field of the same class is part of the section too, and
    the caller gives it the class's own kind."""
    out = []
    for tag in ENTRY_TAG.finditer(body):
        attributes = dict(ATTR.findall(tag.group(1)))
        name = attributes.get("name", "")
        try:
            if "bitfield_high" in attributes:
                high = int(attributes["bitfield_high"])
                low = int(attributes["bitfield_low"])
            elif attributes.get("type") == "dword" and "offset" in attributes:
                # A whole strap word: the SPT documents keep a few — the CPM
                # soft straps and the protected range — as one dword each.
                high, low = 31, 0
            else:
                continue
            offset = attributes.get("offset", "0")
            offset = int(offset, 0) if offset.startswith("0x") else int(offset)
            value = attributes.get("value", "0")
            default = int(value, 16) if value.startswith("0x") else int(value or 0)
        except (KeyError, ValueError):
            continue
        out.append((name, attributes.get("type", ""), attributes.get("value", ""),
                    attributes.get("offset", "0"), high, low,
                    bool(STRAP_NAME.match(name))))
    return out


def kind_of(name):
    """The section a field belongs to, from either naming the tools use.

    The newer builds write `PCH_Strap_…`, `CPU_Strap_…`; FIT 11's SPT
    documents write `PchStrap…`, `CpuStrap…` with no underscore.
    """
    for kind in ("CPU", "PCH", "PMC", "SA"):
        if name.startswith(kind + "_Strap_") or name.startswith(kind.title() + "Strap"):
            return kind
    return name.split("_")[0]


CLASS = re.compile(r'<Class name="([^"]+)"[^>]*>(.*?)</Class>', re.S)
ENTRY_TAG = re.compile(r"<LayoutEntry ([^>]*)/?>")


def tables(blob, tool):
    """Every strap table in the executable: its entries and the section it spans.

    A class holds one section's table — `FPSBA` the PCH section,
    `CpuStrapsLayout` the processor one — and the entries are split by their
    name prefix in any case. **A section's length is the class's own extent**,
    from every bitfield it lays out and the word groups it comments
    (`<!-- Group offset: 0x218 size: 0x4 -->`), not from the named strap fields
    alone: FIT 11's SPT desktop class ends with five words no `PchStrap…` field
    reaches, and the descriptor still states the section's full length.
    """
    found = []
    for text, name in documents(blob):
        for match in CLASS.finditer(text):
            body = match.group(2)
            entries = entries_of(body)
            named = [entry for entry in entries if entry[6]]
            # A section's own class is taken however few of its fields are
            # named straps — FIT 11's 139-word table has 44, the rest reserved
            # words its group comments cover. Any other class has to look like
            # a table to be one.
            named_section = match.group(1) in ("FPSBA", "CpuStrapsLayout")
            if len(named) < (10 if named_section else 50):
                continue
            offsets = []
            for tag in ENTRY_TAG.finditer(body):
                attributes = dict(re.findall(
                    r'([A-Za-z_][\w:.-]*)="([^"]*)"', tag.group(1)))
                if "offset" in attributes and "bitfield_low" in attributes:
                    try:
                        offsets.append(int(attributes["offset"], 0))
                    except ValueError:
                        pass
            groups = re.findall(
                r"Group offset:\s*(0x[0-9a-fA-F]+)\s*size:\s*(0x[0-9a-fA-F]+)",
                body)
            extent = max((int(o, 0) + int(s, 0) for o, s in groups), default=0)
            if offsets:
                extent = max(extent, max(offsets) + 4)
            extent_words = (extent + 3) // 4
            # A class that names straps of one kind holds that section; its
            # other bitfields — `reserved_0x0_…`, `csme_…`, `GBE…` — are words
            # of the same section and are read with it.
            kinds = {kind_of(entry[0]) for entry in named}
            primary = kinds.pop() if len(kinds) == 1 else None
            by_kind = collections.defaultdict(list)
            for entry_name, kind, default, offset, high, low, is_named in entries:
                section = kind_of(entry_name) if is_named else primary
                if section is None:
                    continue
                by_kind[section].append({
                    "name": entry_name,
                    "type": kind,
                    "default": int(default, 16) if default.startswith("0x") else int(default or 0),
                    "offset": int(offset, 16) if offset.startswith("0x") else int(offset),
                    "high": int(high),
                    "low": int(low),
                })
            for kind, fields in by_kind.items():
                # A document may state one name twice at different offsets (a
                # twin the tables do not distinguish); the first place is kept,
                # as the table's names are its identity.
                seen_names, unique = set(), []
                for field in fields:
                    if field["name"] in seen_names:
                        continue
                    seen_names.add(field["name"])
                    unique.append(field)
                words = max(max(field["offset"] for field in fields) // 4 + 1,
                            extent_words)
                found.append({"kind": kind, "words": words, "fields": unique,
                              "document": name, "tool": tool})
    return found


def agreed(matches):
    """The fields every table states alike, with the preferred table's defaults.

    The processor section's length is a weaker key than the PCH one's: two
    documents of one length can lay a field out differently or name the same
    bits another way. What survives here is what all of them agree on —
    identical name, offset and bit range — and a field they disagree about is
    dropped rather than taken from one of them. `matches` is newest first, and
    the first — the newest tool's, self-named where there is one — gives the
    defaults.
    """
    preferred = matches[0][1]
    defaults = {(f["name"], f["offset"], f["low"], f["high"]): f["default"]
                for f in preferred["fields"]}
    shared = None
    for _, table in matches:
        keys = {(f["name"], f["offset"], f["low"], f["high"]) for f in table["fields"]}
        shared = keys if shared is None else shared & keys
    fields = [{**field, "default": defaults.get(
        (field["name"], field["offset"], field["low"], field["high"]), 0)}
        for field in preferred["fields"]
        if (field["name"], field["offset"], field["low"], field["high"]) in (shared or set())]
    # The first table's order, deduplicated: the same field can be stated by
    # two entries of one document.
    seen, unique = set(), []
    for field in fields:
        key = (field["name"], field["offset"], field["low"], field["high"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(field)
    return {"kind": preferred["kind"], "words": preferred["words"],
            "fields": unique, "document": preferred["document"],
            "tool": preferred["tool"]}


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def swift(kind, chosen):
    """One file for the tools at hand: a table per length asked for."""
    lines = []
    label = {"PCH": "PCH", "CPU": "processor"}.get(kind, kind)
    lines.append("// The %s strap section, field by field, as Intel's Flash Image Tool"
                 % label)
    lines.append("// lays it out — emitted by `Skills/me-eom-structures/scripts/strap_map.py`")
    lines.append("// from the tool's own resources. Names, offsets, bits and defaults are the")
    lines.append("// tool's, copied; nothing here is read out of a dump.")
    lines.append("//")
    if kind == "PMC":
        lines.append("// A table is picked by the number of words the MIP area's PMC and CPU")
        lines.append("// block holds less the CPU strap message FLMAP2 states — because that is")
        lines.append("// what an image states about")
    else:
        lines.append("// A table is picked by the length of the section it describes — the words the")
        lines.append("// descriptor's own %s states — because that is what an image states about"
                     % ("FLMAP1" if kind == "PCH" else "FLMAP2"))
    lines.append("// itself. `StrapMap.swift` says what a table is and what the lookup does;")
    lines.append("// another length is added by running the script with it.")
    if kind == "CPU":
        lines.append("//")
        lines.append("// A processor table keeps only the fields **every** document of that")
        lines.append("// length states alike — the same name at the same offset and bits. Two")
        lines.append("// documents of one length can differ (a field's width, which bits are")
        lines.append("// reserved), and a field they disagree about is left out rather than")
        lines.append("// taken from one of them.")
    lines.append("")
    lines.append("import Foundation")
    lines.append("")
    lines.append("extension DescriptorStrapMap {")
    for words, table in chosen:
        source = table["tool"] if not table["document"] else "%s (%s)" % (
            table["tool"], table["document"])
        lines.append("    /// The %d-word section, as Flash Image Tool %s lays it out."
                     % (words, source))
        lines.append("    public static let %s%d = DescriptorStrapMap(" % (kind.lower(), words))
        lines.append("        name: %s," % swift_literal(
            table["document"] or "Flash Image Tool %s, %d words" % (table["tool"], words)))
        lines.append("        words: %d," % words)
        lines.append("        fields: [")
        for field in sorted(table["fields"], key=lambda f: (f["offset"], f["low"])):
            lines.append("            Field(name: %s, word: %d, bits: %d...%d, defaultValue: 0x%X),"
                         % (swift_literal(field["name"]), field["offset"] // 4,
                            field["low"], field["high"], field["default"]))
        lines.append("        ])")
    lines.append("}")
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    args, words = option(args, "--words")
    args, kind = option(args, "--kind", "PCH")
    kind = kind.upper()
    paths = [a for a in args if not a.startswith("-")]
    if not words or not paths:
        print(__doc__)
        return 2

    # The newest tool first: its table is the one taken where a length appears
    # in several, and its own documents are the better named.
    tools = []
    for path in paths:
        version = re.search(r"fit-(\d+(?:\.\d+)*)", os.path.basename(path))
        tools.append((version.group(1) if version else os.path.basename(path),
                      open(path, "rb").read()))
    tools.sort(reverse=True)
    available = [(tool, table) for tool, blob in tools for table in tables(blob, tool)]

    chosen = []
    for wanted in [int(w) for w in words.split(",")]:
        matches = [(tool, table) for tool, table in available
                   if table["kind"] == kind and table["words"] == wanted]
        if not matches:
            print("no %s table of %d words in %s; they have %s"
                  % (kind, wanted, ", ".join(t for t, _ in tools),
                     ", ".join("%s:%d" % (t["kind"], t["words"]) for _, t in available)),
                  file=sys.stderr)
            return 1
        # A document that names itself beats a nameless one of the same length;
        # among equals the newest tool wins, and among its own documents the
        # first is taken (a platform's two steppings agree on their fields).
        named = [t for t in matches if t[1]["document"]]
        ordered = named + [t for t in matches if not t[1]["document"]]
        table = ordered[0][1]
        if kind == "CPU" and len(ordered) > 1:
            stated = len(table["fields"])
            table = agreed(ordered)
            print("   %d documents of this length; %d fields they agree on "
                  "(%d dropped)" % (len(ordered), len(table["fields"]),
                                    stated - len(table["fields"])), file=sys.stderr)
            if not table["fields"]:
                print("the documents of %d words agree on no field at all" % wanted,
                      file=sys.stderr)
                return 1
        chosen.append((wanted, table))
        print("%s section of %d words: %d fields from %s%s"
              % (kind, wanted, len(table["fields"]), table["tool"],
                 " (%s)" % table["document"] if table["document"] else ""), file=sys.stderr)
        # Where the two fields the engine reads by name sit — the check that
        # the table is the section's own. Both move between lengths, so this
        # says where they are rather than asserting where they should be.
        for label, pattern in (("clock", r"SPI_ec_max_freq$"),
                               ("protected range", r"GLOBAL_PROTECTED_RNG")):
            found = [f for f in table["fields"] if re.search(pattern, f["name"])]
            print("   %-16s %s" % (label + ":", "; ".join(
                "%s word %d bits %d..%d" % (f["name"], f["offset"] // 4, f["low"], f["high"])
                for f in found) or "—"), file=sys.stderr)

    print(swift(kind, chosen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
