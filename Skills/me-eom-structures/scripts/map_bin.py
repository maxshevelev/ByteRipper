#!/usr/bin/env python3
"""Compile the map descriptions from JSON into the binary the app reads.

The JSON files are the source of truth and what a review reads; the binary is
what ships. The format is deliberately small and language-neutral so the web
port can read the same bytes with a reader of its own.

    # Rebuild, bumping the build number the code is marked with.
    python3 Skills/me-eom-structures/scripts/map_bin.py build \
        --out Packages/UEFIImage/Sources/UEFIImage/Resources/StrapMaps/StrapMaps.bin \
        --version-file Packages/UEFIImage/MapSources/build.version \
        --swift-version-file Packages/UEFIImage/Sources/UEFIImage/StrapMapDataVersion.swift \
        Packages/UEFIImage/MapSources/strap/*.json

    # Verify the committed binary and Swift constant against the JSON.
    python3 Skills/me-eom-structures/scripts/map_bin.py build --check ...

    # Read a binary back, for review or debugging.
    python3 Skills/me-eom-structures/scripts/map_bin.py dump <file.bin>

The format (`BRM1`, version 1), all numbers little-endian:

    header, 32 bytes
        0   magic "BRM1"
        4   u16 formatVersion
        6   u16 headerSize (32)
        8   u32 build
        12  u16 kind (1 = strap)
        14  u16 flags
        16  u32 sectionCount
        20  u32 checksum — FNV-1a over the whole file with this field zero
        24  u32 reserved
        28  u32 reserved

    sections, 12 bytes each
        u16 kind | u16 flags | u32 offset | u32 length

    section 1, strings: NUL-terminated UTF-8, deduplicated; a reference is a
        byte offset, and 0xFFFFFFFF means no string.
    section 2, maps: u32 count, then per map 24 bytes:
        u32 idRef | u32 nameRef | u16 words | u16 set
        u32 fieldCount | u32 fieldsOffset | u32 helpRef
    section 3, fields: 28 bytes each:
        u32 nameRef | u16 word | u8 low | u8 high | u16 flags
        u32 defaultValue | u32 labelRef | u32 optionsOffset
        u16 optionsCount | u16 reserved
        flags: 1 = default present, 2 = options present, 4 = label present
    section 4, options: 8 bytes each: u16 value | u16 reserved | u32 textRef

Reader rules: the magic, the format version and the build must match what the
code was marked with, or no byte is interpreted at all. Unknown sections are
skipped by their length, and a field's flags say which optional parts follow,
so a newer file degrades rather than misreads.

Stdlib only, deterministic, no network.
"""

import json
import os
import struct
import sys

MAGIC = b"BRM1"
FORMAT_VERSION = 1
HEADER_SIZE = 32
KIND_STRAP = 1
SECTION_STRINGS = 1
SECTION_MAPS = 2
SECTION_FIELDS = 3
SECTION_OPTIONS = 4
SECTION_TABLE = 12
MAP_RECORD = 24
FIELD_RECORD = 28
OPTION_RECORD = 8
NO_REF = 0xFFFFFFFF
SET_NAMES = {"pch": 0, "spt": 1, "cpu": 2, "other": 3}


def fnv1a32(data):
    value = 2166136261
    for byte in data:
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return value


def fail(message):
    print(message, file=sys.stderr)
    return 1


class StringPool:
    """UTF-8 strings, deduplicated, referenced by their byte offset."""

    def __init__(self):
        self.data = bytearray()
        self.offsets = {}

    def ref(self, text):
        if text is None or text == "":
            return NO_REF
        if text in self.offsets:
            return self.offsets[text]
        encoded = text.encode("utf-8")
        if b"\x00" in encoded:
            raise ValueError("a string may not contain NUL: %r" % text)
        offset = len(self.data)
        self.offsets[text] = offset
        self.data += encoded + b"\x00"
        return offset

    def string(self, data, ref):
        if ref == NO_REF:
            return None
        end = data.find(b"\x00", ref)
        if end < 0:
            raise ValueError("unterminated string at 0x%X" % ref)
        return data[ref:end].decode("utf-8")


def load(path):
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    if document.get("schema") != "byteripper.map/1":
        raise ValueError("%s: schema is not byteripper.map/1" % path)
    if document.get("kind") != "strap":
        raise ValueError("%s: kind is not strap" % path)
    maps = document.get("maps")
    if not isinstance(maps, list) or not maps:
        raise ValueError("%s: no maps" % path)
    return document


def option_pairs(field):
    raw = field.get("options") or []
    if isinstance(raw, dict):
        return sorted((int(key), value) for key, value in raw.items())
    pairs = []
    for item in raw:
        if not isinstance(item, list) or len(item) != 2:
            raise ValueError("options must be [value, text] pairs: %r" % (item,))
        pairs.append((int(item[0]), item[1]))
    return sorted(pairs)


def validate(document, path):
    for index, mapping in enumerate(document["maps"]):
        where = "%s: map %d" % (path, index)
        for key in ("id", "set", "name", "words", "fields"):
            if key not in mapping:
                raise ValueError("%s: no %s" % (where, key))
        if mapping["set"] not in SET_NAMES:
            raise ValueError("%s: unknown set %r" % (where, mapping["set"]))
        words = int(mapping["words"])
        if words <= 0 or words > 0xFFFF:
            raise ValueError("%s: %d words" % (where, words))
        for field in mapping["fields"]:
            if not field.get("name"):
                raise ValueError("%s: a field has no name" % where)
            word = int(field["word"])
            low, high = field["bits"]
            low, high = int(low), int(high)
            if not (0 <= word < words):
                raise ValueError("%s: %s in word %d of %d"
                                 % (where, field["name"], word, words))
            if not (0 <= low <= high < 32):
                raise ValueError("%s: %s bits %d..%d"
                                 % (where, field["name"], low, high))
            width = high - low + 1
            default = field.get("default")
            if default is not None:
                default = int(default)
                if default < 0 or (width < 32 and default >= (1 << width)):
                    raise ValueError("%s: %s default %d does not fit %d bits"
                                     % (where, field["name"], default, width))
            for number, text in option_pairs(field):
                if number < 0 or (width < 32 and number >= (1 << width)):
                    raise ValueError("%s: %s option %d does not fit %d bits"
                                     % (where, field["name"], number, width))
                if not isinstance(text, str):
                    raise ValueError("%s: %s option %r is not text"
                                     % (where, field["name"], text))


def compile_maps(documents, build):
    """The binary bytes for the JSON documents, with `build` in the header."""
    mappings = []
    for document in documents:
        mappings.extend(document["maps"])
    ids = [mapping["id"] for mapping in mappings]
    if len(ids) != len(set(ids)):
        raise ValueError("map ids repeat: %s"
                         % ", ".join(sorted({i for i in ids if ids.count(i) > 1})))

    strings = StringPool()
    fields_blob = bytearray()
    options_blob = bytearray()
    option_offsets = {}
    map_records = []

    for mapping in mappings:
        field_list = mapping["fields"]
        fields_offset = len(fields_blob)
        for field in field_list:
            low, high = (int(field["bits"][0]), int(field["bits"][1]))
            default = field.get("default")
            pairs = option_pairs(field)
            options_offset = NO_REF
            if pairs:
                key = tuple(pairs)
                if key not in option_offsets:
                    option_offsets[key] = len(options_blob)
                    for number, text in pairs:
                        options_blob += struct.pack(
                            "<HHI", int(number), 0, strings.ref(text))
                options_offset = option_offsets[key]
            flags = 0
            if default is not None:
                flags |= 1
            if pairs:
                flags |= 2
            if field.get("label"):
                flags |= 4
            fields_blob += struct.pack(
                "<IHBBHIIIHHH",
                strings.ref(field["name"]),
                int(field["word"]), low, high, flags,
                int(default) if default is not None else 0,
                strings.ref(field.get("label")),
                options_offset,
                len(pairs),
                0,
                0,
            )
        map_records.append(struct.pack(
            "<IIHHIII",
            strings.ref(mapping["id"]),
            strings.ref(mapping.get("name")),
            int(mapping["words"]),
            SET_NAMES[mapping["set"]],
            len(field_list),
            fields_offset,
            NO_REF,
        ))

    maps_blob = struct.pack("<I", len(map_records)) + b"".join(map_records)
    sections = [(SECTION_STRINGS, bytes(strings.data)),
                (SECTION_MAPS, maps_blob),
                (SECTION_FIELDS, bytes(fields_blob)),
                (SECTION_OPTIONS, bytes(options_blob))]
    sections = [section for section in sections if section[1]]
    offset = HEADER_SIZE + len(sections) * SECTION_TABLE
    table = bytearray()
    body = bytearray()
    for kind, payload in sections:
        table += struct.pack("<HHII", kind, 0, offset, len(payload))
        body += payload
        offset += len(payload)
    header = bytearray(struct.pack(
        "<4sHHIHHIIII", MAGIC, FORMAT_VERSION, HEADER_SIZE, build,
        KIND_STRAP, 0, len(sections), 0, 0, 0))
    data = bytes(header) + bytes(table) + bytes(body)
    checksum = fnv1a32(data)
    data = data[:20] + struct.pack("<I", checksum) + data[24:]
    return data


def swift_version(build):
    return (
        "// Generated by `Skills/me-eom-structures/scripts/map_bin.py`. "
        "Do not edit.\n"
        "//\n"
        "// The binary map file and the code are marked with one build: the\n"
        "// reader refuses a file whose build differs, so a stale resource is\n"
        "// reported before a byte of it is interpreted.\n"
        "enum StrapMapDataVersion {\n"
        "    static let formatVersion: UInt16 = %d\n"
        "    static let build: UInt32 = %d\n"
        "}\n" % (FORMAT_VERSION, build))


def read_version(path):
    if not os.path.exists(path):
        return 0
    with open(path, encoding="utf-8") as handle:
        return int(handle.read().strip())


def build(args):
    if "--out" not in args:
        print("build needs --out", file=sys.stderr)
        return 2
    out = args[args.index("--out") + 1]
    version_file = (args[args.index("--version-file") + 1]
                    if "--version-file" in args else None)
    swift_file = (args[args.index("--swift-version-file") + 1]
                  if "--swift-version-file" in args else None)
    check = "--check" in args
    skip = set()
    for name in ("--out", "--version-file", "--swift-version-file"):
        if name in args:
            at = args.index(name)
            skip.update((at, at + 1))
    paths = [a for i, a in enumerate(args)
             if i not in skip and not a.startswith("-")]
    if not paths:
        print("build needs JSON files", file=sys.stderr)
        return 2

    documents = []
    for path in paths:
        try:
            document = load(path)
            validate(document, path)
            documents.append(document)
        except (OSError, ValueError) as error:
            return fail(str(error))

    version = read_version(version_file) if version_file else 0
    build_number = version if check else version + 1
    try:
        data = compile_maps(documents, build_number)
    except ValueError as error:
        return fail(str(error))

    if check:
        try:
            with open(out, "rb") as handle:
                committed = handle.read()
        except OSError as error:
            return fail(str(error))
        if committed != data:
            return fail("%s is stale: rebuild with --build" % out)
        if swift_file:
            with open(swift_file, encoding="utf-8") as handle:
                if handle.read() != swift_version(build_number):
                    return fail("%s is stale: rebuild with --build" % swift_file)
        print("%s: build %d, %d maps, %d bytes — current"
              % (out, build_number,
                 sum(len(document["maps"]) for document in documents), len(data)),
              file=sys.stderr)
        return 0

    if version_file:
        with open(version_file, "w", encoding="utf-8") as handle:
            handle.write("%d\n" % build_number)
    if swift_file:
        with open(swift_file, "w", encoding="utf-8") as handle:
            handle.write(swift_version(build_number))
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(data)
    print("%s: build %d, %d maps, %d bytes"
          % (out, build_number, sum(len(d["maps"]) for d in documents), len(data)),
          file=sys.stderr)
    return 0


def dump(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < HEADER_SIZE or data[:4] != MAGIC:
        return fail("%s: not a BRM1 file" % path)
    magic, version, header_size, build, kind, flags, count, checksum, _, _ = \
        struct.unpack_from("<4sHHIHHIIII", data, 0)
    zeroed = bytearray(data)
    zeroed[20:24] = b"\x00\x00\x00\x00"
    print("format %d, build %d, kind %d, %d bytes, checksum %s"
          % (version, build, kind, len(data),
             "ok" if fnv1a32(zeroed) == checksum else "MISMATCH"))
    sections = {}
    for index in range(count):
        skind, sflags, offset, length = struct.unpack_from(
            "<HHII", data, header_size + index * SECTION_TABLE)
        sections[skind] = (offset, length)
        print("  section %d: offset 0x%X, %d bytes" % (skind, offset, length))
    strings_at, _ = sections.get(SECTION_STRINGS, (0, 0))
    def text(ref):
        if ref == NO_REF:
            return "—"
        end = data.find(b"\x00", strings_at + ref)
        return data[strings_at + ref:end].decode("utf-8")
    maps_at, _ = sections.get(SECTION_MAPS, (0, 0))
    fields_at, _ = sections.get(SECTION_FIELDS, (0, 0))
    options_at, _ = sections.get(SECTION_OPTIONS, (0, 0))
    total = struct.unpack_from("<I", data, maps_at)[0]
    for index in range(total):
        record_at = maps_at + 4 + index * MAP_RECORD
        id_ref, name_ref, words, set_id, field_count, fields_offset, _ = \
            struct.unpack_from("<IIHHIII", data, record_at)
        print("map %s (%s), %d words, %d fields"
              % (text(id_ref), text(name_ref), words, field_count))
        for field_index in range(field_count):
            at = fields_at + fields_offset + field_index * FIELD_RECORD
            (name_ref, word, low, high, fflags, default,
             label_ref, options_offset, options_count, _, _) = \
                struct.unpack_from("<IHBBHIIIHHH", data, at)
            suffix = ""
            if fflags & 1:
                suffix += ", default %d" % default
            if fflags & 4:
                suffix += ", label %r" % text(label_ref)
            print("  %-60s word %3d bits %2d..%-2d%s"
                  % (text(name_ref), word, low, high, suffix))
            if fflags & 2:
                for option_index in range(options_count):
                    number, _, option_ref = struct.unpack_from(
                        "<HHI", data, options_at + options_offset + option_index * OPTION_RECORD)
                    print("      %d = %r" % (number, text(option_ref)))
    return 0


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    if args[0] == "build":
        return build(args[1:])
    if args[0] == "dump":
        if len(args) != 2:
            print("dump needs one file", file=sys.stderr)
            return 2
        return dump(args[1])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
