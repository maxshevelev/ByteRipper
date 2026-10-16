"""Emit the strap fields of a descriptor section for the engine and the panel.

The Flash Image Tool executables carry the chipset's strap layout as their own
resources — `<LayoutEntry name="PCH_Strap_SPI_ec_max_freq" type="bitfield32"
value="0x4" offset="0x50" bitfield_high="5" bitfield_low="3"/>` — a name, the
byte offset of the word the field sits in, the bits it takes, and the value the
tool builds the strap with. That is the specification the panel has been
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
are `CPU_Strap_*` and whose offsets are relative to that section's own base.
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


ENTRY = re.compile(
    r"<LayoutEntry name=\"((?:CPU|PCH|PMC|SA)_Strap_[^\"]+)\" type=\"(\w+)\" value=\"([^\"]*)\" "
    r"offset=\"([^\"]*)\" bitfield_high=\"(\d+)\" bitfield_low=\"(\d+)\"")


def tables(blob, tool):
    """Every strap table in the executable: its entries and the section it spans.

    A document holds one CPU, one PCH and one PMC table at once — the three
    sections the descriptor keeps separately — so they are split by their name
    prefix, and a table's length is what its own entries reach, in words.
    """
    found = []
    for text, name in documents(blob):
        entries = ENTRY.findall(text)
        if len(entries) < 50:
            continue
        by_kind = collections.defaultdict(list)
        for entry_name, kind, default, offset, high, low in entries:
            by_kind[entry_name.split("_")[0]].append({
                "name": entry_name,
                "type": kind,
                "default": int(default, 16) if default.startswith("0x") else int(default or 0),
                "offset": int(offset, 16) if offset.startswith("0x") else int(offset),
                "high": int(high),
                "low": int(low),
            })
        for kind, fields in by_kind.items():
            words = max(field["offset"] for field in fields) // 4 + 1
            found.append({"kind": kind, "words": words, "fields": fields,
                          "document": name, "tool": tool})
    return found


def swift_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def swift(kind, chosen):
    """One file for the tools at hand: a table per length asked for."""
    lines = []
    lines.append("// The %s strap section, field by field, as Intel's Flash Image Tool"
                 % ("PCH" if kind == "PCH" else "processor"))
    lines.append("// lays it out — emitted by `Skills/me-eom-structures/scripts/strap_map.py`")
    lines.append("// from the tool's own resources. Names, offsets, bits and defaults are the")
    lines.append("// tool's, copied; nothing here is read out of a dump.")
    lines.append("//")
    lines.append("// A table is picked by the length of the section it describes — the words the")
    lines.append("// descriptor's own FLMAP1 states — because that is what an image states about")
    lines.append("// itself. `StrapMap.swift` says what a table is and what the lookup does;")
    lines.append("// another length is added by running the script with it.")
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
        table = (named or matches)[0][1]
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
