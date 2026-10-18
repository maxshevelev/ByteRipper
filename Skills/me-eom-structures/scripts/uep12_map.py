"""Emit CSME 12's FPF/UEP layout from Flash Image Tool 12's class documents.

FIT 12 states the area as a `Uep` class of `LayoutEntry`s, `CfgOpt`s and
`GetBitArrayValue` actions:

    <Class name="Uep">
      <LayoutEntry name="Signature" value="0x50455524" type="dword"/>
      <LayoutEntry name="Crc" type="word"/>
      <LayoutEntry name="Reserved" type="word"/>
      <LayoutEntry name="UepBitsArray0" type="class:BLOB"/>
      …
      <!--FW_TYPE-->
      <CfgOpt name="fw_type" type="dword" value="0x3"/>
      <Action name="GetBitArrayValue" source="fw_type"
              target="UepBitsArray0"
              params="{'offset':'0x40','startBit':19,'bitCount':3}"/>
      <!--OEM_ID-->
      <Action name="GetBitArrayValue"
              source="$OEMandPlatformIDs/OemVendorId" target="UepBitsArray0"
              params="{'offset':'0x3c','startBit':0,'bitCount':16}"/>

The container is the class's own eight-byte header — signature, CRC-16,
reserved — followed by arrays of 0x80 bytes; the CSME 12 map has four of
them. The CNP document is the one with exactly those four arrays, `fw_type`
among its settings and none of the RPMC options CML and later add. Its
placement of `fw_type` is confirmed by the CSME 12 dump at hand: the
container's CRC-16 covers header and arrays (+6…+0x208) and the word at
array 0 +0x40 reads 3 with its valid bit set, the tool's own default.

Later arrays repeat several of the first's names at other offsets. A name is
taken once, from the first array that holds it, so the readings carry no
duplicate; what only a later array holds is kept. The 256-bit OEM public key
hash is left out: a field the reader cannot take (more than 64 bits) would be
a row that never appears.

A setting's words are the tool's: a `$Class/Option` source is looked up in
that class's `CfgOpt` — its label, help and, for a `class:…` type, the value
words the class defines (`SupportedFpfValues`' 0xC "No", 0xF "Yes"). A bare
bit has the UEP document's own `<!--NAME-->` comment.

    python3 uep12_map.py <fit-12.exe> > \\
        Packages/MEFirmware/Sources/MEFirmware/Configuration/UEPMap+CSME12.swift

Stdlib only, read-only, no network; read the diff, don't paste blind.
"""

import collections
import hashlib
import os
import re
import sys
import zlib

GENERATION = "12"
ARRAY_SIZE = 0x80
MAX_BITS = 64

TAG = re.compile(r'<([A-Za-z_][\w:.-]*)([^>]*?)/?>')
ATTR = re.compile(r'([A-Za-z_][\w:.-]*)="([^"]*)"')


def documents(blob):
    """Every zlib stream in the executable that holds an XML document."""
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


def classes(text):
    """The document's `<Class name="…">` bodies, in order."""
    for match in re.finditer(r'<Class name="([^"]+)"[^>]*>(.*?)</Class>',
                             text, re.S):
        yield match.group(1), match.group(2)


def attrs_of(text):
    return dict(ATTR.findall(text))


def elements(body, name):
    """Every `<name …>` of a class body as (attributes)."""
    out = []
    for match in TAG.finditer(body):
        if match.group(1) != name:
            continue
        out.append(attrs_of(match.group(2)))
    return out


def numbered(text):
    try:
        return int(text, 0)
    except (TypeError, ValueError):
        return None


def value_classes(documents_found):
    """The tool's value classes: class name → {number: word}.

    A value class is a `<Class>` whose `CfgOpt`s are bare named numbers with
    no label of their own — `No` 0 / `Yes` 1, `Disabled` 0 / `Enabled` 1,
    `SupportedFpfValues`' `No` 0xC / `Yes` 0xF.
    """
    tables = collections.defaultdict(lambda: collections.defaultdict(list))
    for text in documents_found:
        for name, body in classes(text):
            entries = elements(body, "CfgOpt")
            if len(entries) < 2:
                continue
            table = {}
            for entry in entries:
                word = entry.get("name")
                number = numbered(entry.get("value"))
                if not word or number is None or entry.get("label"):
                    break
                if not re.fullmatch(r"[A-Za-z][A-Za-z0-9 _-]*", word):
                    break
                table[number] = word
            else:
                for number, word in table.items():
                    tables[name][number].append(word)
    out = {}
    for name, by_number in tables.items():
        words = {}
        for number, candidates in by_number.items():
            words[number] = collections.Counter(candidates).most_common(1)[0][0]
        if len(set(words.values())) == len(words) and words:
            out[name] = words
    return out


def settings_words(documents_found):
    """The tool's label, help and value type for `Class/Option` sources."""
    found = collections.defaultdict(lambda: {"labels": [], "helps": [],
                                             "types": []})
    for text in documents_found:
        for name, body in classes(text):
            for entry in elements(body, "CfgOpt"):
                option = entry.get("name")
                if not option:
                    continue
                key = (name, option)
                if entry.get("label"):
                    found[key]["labels"].append(entry["label"])
                if entry.get("help"):
                    found[key]["helps"].append(entry["help"])
                if entry.get("type", "").startswith("class:"):
                    found[key]["types"].append(entry["type"][len("class:"):])
    words = {}
    for key, entry in found.items():
        label = (collections.Counter(entry["labels"]).most_common(1)[0][0]
                 if entry["labels"] else None)
        help_text = max(entry["helps"], key=len) if entry["helps"] else None
        kind = (collections.Counter(entry["types"]).most_common(1)[0][0]
                if entry["types"] else None)
        words[key] = {"label": label, "help": help_text, "class": kind}
    return words


def uep_body(documents_found):
    """The CNP `Uep` class: four arrays, `fw_type`, no RPMC options."""
    chosen = []
    for text in documents_found:
        for name, body in classes(text):
            if name != "Uep":
                continue
            arrays = set()
            for action in elements(body, "Action"):
                if action.get("name") != "GetBitArrayValue":
                    continue
                target = re.search(r"UepBitsArray(\d+)",
                                   action.get("target", ""))
                if target:
                    arrays.add(int(target.group(1)))
            rpMc = "PttRpmc" in body or "RpmcConfiguration" in body
            if arrays == {0, 1, 2, 3} and "fw_type" in body and not rpMc:
                chosen.append(body)
    if len(chosen) != 1:
        raise SystemExit("expected one CNP Uep class, found %d" % len(chosen))
    return chosen[0]


def commented_names(body):
    """The `<!--NAME-->` the document puts before a setting's block."""
    names = {}
    current = None
    for line in body.splitlines():
        comment = re.search(r"<!--([A-Z][A-Z0-9_]{1,})-->", line)
        if comment and not comment.group(1).startswith("UepBitsArray"):
            current = comment.group(1)
            continue
        if current and "GetBitArrayValue" in line:
            source = re.search(r'source="([^"]+)"', line)
            if source:
                names.setdefault(source.group(1), current)
    return names


def unescaped(text):
    if not text:
        return text
    for entity, character in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'),
                              ("&apos;", "'"), ("&amp;", "&")):
        text = text.replace(entity, character)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    return re.sub(r"\r\n?", "\n", text).strip()


def settings(body, words, values):
    """Every readable setting, once, in the array that holds it first."""
    comments = commented_names(body)
    taken = {}
    skipped = []
    settings_out = []
    for action in elements(body, "Action"):
        if action.get("name") != "GetBitArrayValue":
            continue
        source = action.get("source", "")
        target = re.search(r"UepBitsArray(\d+)", action.get("target", ""))
        place = re.search(
            r"'offset':'(0x[0-9A-Fa-f]+)','startBit':(\d+),'bitCount':(\d+)",
            action.get("params", ""))
        if not source or not target or not place:
            continue
        name = source.split("/")[-1]
        if name in taken:
            continue
        offset = int(place.group(1), 0)
        bit = int(place.group(2))
        count = int(place.group(3))
        if count > MAX_BITS or bit + count > MAX_BITS:
            skipped.append(name)
            continue
        taken[name] = True
        section = None
        label = None
        help_text = None
        options = None
        if source.startswith("$"):
            parts = source[1:].split("/")
            if len(parts) >= 2:
                section = parts[0]
                entry = words.get((parts[0], parts[1]), {})
                label = entry.get("label")
                help_text = unescaped(entry.get("help"))
                options = values.get(entry.get("class") or "")
        if label is None:
            label = comments.get(source)
        settings_out.append({
            "name": name,
            "array": int(target.group(1)),
            "offset": offset,
            "bit": bit,
            "count": count,
            "label": label,
            "section": section,
            "help": help_text,
            "options": options,
        })
    return settings_out, skipped, taken


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    for character, escape in (("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")):
        escaped = escaped.replace(character, escape)
    return '"%s"' % escaped


def swift(tool, entries):
    lines = [
        "// The FPF/UEP settings of CSME %s, as %s lays them out — emitted by"
        % (GENERATION, tool),
        "// `Skills/me-eom-structures/scripts/uep12_map.py` from the tool's own",
        "// `Uep` and configuration class documents. Names, labels, sections,",
        "// option words and places are the tool's; nothing here is read out of a",
        "// dump.",
        "//",
        "// A setting's place is an array and an offset into it, in the four 0x80-",
        "// byte arrays that follow the container's 8-byte `$UEP` header",
        "// (signature, CRC-16, reserved). A name the tool places in several arrays",
        "// is kept once, where it first appears.",
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
                "placement: Placement(array: %d, offset: 0x%X, bit: %d, count: %d)"
                % (entry["array"], entry["offset"], entry["bit"], entry["count"])]
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
              "        arrayStart: 8,",
              "        arraySize: 0x%X)" % ARRAY_SIZE,
              "}", ""]
    return "\n".join(lines)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    base = os.path.splitext(os.path.basename(path))[0]
    version = re.search(r"(\d+(?:\.\d+)*)", base)
    tool = "Flash Image Tool %s" % (version.group(1) if version else base)
    blob = open(path, "rb").read()
    documents_found = list(documents(blob))
    if not documents_found:
        print("no XML documents found in this build", file=sys.stderr)
        return 1
    body = uep_body(documents_found)
    values = value_classes(documents_found)
    words = settings_words(documents_found)
    entries, skipped, _ = settings(body, words, values)
    for name in sorted(set(skipped)):
        print("! left out %s: more than %d bits" % (name, MAX_BITS),
              file=sys.stderr)
    entries.sort(key=lambda s: (s["section"] or "", s["array"],
                                s["offset"], s["bit"], s["name"]))
    arrays = collections.Counter(entry["array"] for entry in entries)
    print("settings: %d (%s); %d carry the tool's label, %d a section"
          % (len(entries),
             ", ".join("array %d: %d" % (a, arrays[a]) for a in sorted(arrays)),
             sum(1 for e in entries if e["label"]),
             sum(1 for e in entries if e["section"])),
          file=sys.stderr)
    print(swift(tool, entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
