#!/usr/bin/env python3
"""Compile the map descriptions from JSON into the binary the app reads.

The JSON files are the source of truth and what a review reads; the binary is
what ships. The format is deliberately small and language-neutral so the web
port can read the same bytes with a reader of its own.

    # Rebuild. The version in the JSON manifest changes only when the source
    # JSON changes; the same version is written into the binary and must
    # already be the code's mark.
    python3 Skills/me-eom-structures/scripts/map_bin.py build \
        --out Packages/UEFIImage/Sources/UEFIImage/Resources/StrapMaps/StrapMaps.bin \
        --manifest Packages/UEFIImage/MapSources/manifest.json \
        --swift-version-file Packages/UEFIImage/Sources/UEFIImage/StrapMapDataVersion.swift \
        Packages/UEFIImage/MapSources/strap/*.json

    # Verify the committed binary, manifest and Swift constant agree.
    python3 Skills/me-eom-structures/scripts/map_bin.py build --check ...

    # Read a binary back, for review or debugging.
    python3 Skills/me-eom-structures/scripts/map_bin.py dump <file.bin>

The version is the data contract, not a build counter. `manifest.json` holds
it and a digest of the source JSON. `build` recomputes the digest:

    * digest changed — the version is incremented, written into the manifest
      and the binary, and the Swift constant is written with the same number;
    * digest unchanged — the version stays, and the Swift constant must
      already carry it, or the build stops: the code was not marked with the
      data it reads.

`--check` writes nothing: it fails if the JSON changed since the version, if
the Swift constant carries another number, or if the committed binary differs
from what the JSON compiles to.

The format (`BRM1`, version 1), all numbers little-endian:

    header, 32 bytes
        0   magic "BRM1"
        4   u16 formatVersion
        6   u16 headerSize (32)
        8   u32 version (the data contract)
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

Reader rules: the magic, the format version and the data version must match
what the
code was marked with, or no byte is interpreted at all. Unknown sections are
skipped by their length, and a field's flags say which optional parts follow,
so a newer file degrades rather than misreads.

Stdlib only, deterministic, no network.
"""

import hashlib
import json
import os
import struct
import sys

MAGIC = b"BRM1"
FORMAT_VERSION = 1
HEADER_SIZE = 32
KIND_STRAP = 1
KIND_CONFIGURATION = 2
KIND_UEP = 3
KIND_GPIO = 4
SECTION_STRINGS = 1
SECTION_MAPS = 2
SECTION_FIELDS = 3
SECTION_OPTIONS = 4
SECTION_FILES = 5
SECTION_SETTINGS = 6
SECTION_TABLE = 12
MAP_RECORD = 24
FIELD_RECORD = 28
OPTION_RECORD = 8
CONFIG_MAP_RECORD = 24
FILE_RECORD = 20
SETTING_RECORD = 50
UEP_MAP_RECORD = 24
UEP_SETTING_RECORD = 32
GPIO_MAP_RECORD = 40
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
    if document.get("kind") not in ("strap", "configuration", "uep", "gpio"):
        raise ValueError("%s: unknown kind %r" % (path, document.get("kind")))
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


def pairs_of(mapping, key, where):
    raw = mapping.get(key) or []
    if not isinstance(raw, list):
        raise ValueError("%s: %s is not a list of [number, text]" % (where, key))
    pairs = []
    for item in raw:
        if not isinstance(item, list) or len(item) != 2:
            raise ValueError("%s: %s entry %r is not [number, text]"
                             % (where, key, item))
        number, text = int(item[0]), item[1]
        if number < 0 or number > 0xFFFF:
            raise ValueError("%s: %s number %d" % (where, key, number))
        if not isinstance(text, str):
            raise ValueError("%s: %s text %r" % (where, key, text))
        pairs.append((number, text))
    return sorted(pairs)


def validate_uep(document, path):
    for index, mapping in enumerate(document["maps"]):
        where = "%s: map %d" % (path, index)
        for key in ("id", "name", "settings"):
            if key not in mapping:
                raise ValueError("%s: no %s" % (where, key))
        for key in ("arrayStart", "arraySize"):
            value = int(mapping.get(key, 0))
            if not (0 <= value <= 0xFFFF):
                raise ValueError("%s: %s %d" % (where, key, value))
        for entry in mapping["settings"]:
            if not entry.get("name"):
                raise ValueError("%s: a setting has no name" % where)
            array = int(entry.get("array", 0))
            offset = int(entry.get("offset", -1))
            bit = int(entry.get("bit", -1))
            count = int(entry.get("count", 0))
            if not (0 <= array <= 0xFFFF):
                raise ValueError("%s: %s array %d" % (where, entry["name"], array))
            if not (0 <= offset <= 0xFFFF):
                raise ValueError("%s: %s offset %d" % (where, entry["name"], offset))
            if not (0 <= bit < 64 and 1 <= count <= 64 and bit + count <= 64):
                raise ValueError("%s: %s bit %d count %d"
                                 % (where, entry["name"], bit, count))
            for number, text in pairs_of(entry, "options", where):
                if number >= (1 << count):
                    raise ValueError("%s: %s option %d does not fit %d bits"
                                     % (where, entry["name"], number, count))


def validate_gpio(document, path):
    dictionaries = ("features", "usages", "ownerships", "padModes", "groups")
    for index, mapping in enumerate(document["maps"]):
        where = "%s: map %d" % (path, index)
        for key in ("id", "name", "usages"):
            if key not in mapping:
                raise ValueError("%s: no %s" % (where, key))
        for key in dictionaries:
            pairs_of(mapping, key, where)


def validate(document, path):
    if document["kind"] == "strap":
        validate_strap(document, path)
    elif document["kind"] == "configuration":
        validate_configuration(document, path)
    elif document["kind"] == "uep":
        validate_uep(document, path)
    else:
        validate_gpio(document, path)


def validate_strap(document, path):
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


def condition_value(condition, where):
    if condition is None:
        return None
    if not isinstance(condition, dict) or not condition.get("name"):
        raise ValueError("%s: a condition is not {name, value}" % where)
    return (condition["name"], int(condition.get("value", 0)))


def validate_configuration(document, path):
    for index, mapping in enumerate(document["maps"]):
        where = "%s: map %d" % (path, index)
        for key in ("id", "name", "files"):
            if key not in mapping:
                raise ValueError("%s: no %s" % (where, key))
        for file_index, entry in enumerate(mapping["files"]):
            at = "%s: file %d" % (where, file_index)
            for key in ("path", "alias", "settings"):
                if key not in entry:
                    raise ValueError("%s: no %s" % (at, key))
            for setting in entry["settings"]:
                if not setting.get("name"):
                    raise ValueError("%s: a setting has no name" % at)
                length = int(setting["length"])
                offset = int(setting["offset"])
                if length <= 0 or length > 0xFFFF:
                    raise ValueError("%s: %s length %d" % (at, setting["name"], length))
                if offset < 0:
                    raise ValueError("%s: %s offset %d" % (at, setting["name"], offset))
                bits = setting.get("bits")
                if bits is not None:
                    low, high = int(bits[0]), int(bits[1])
                    if not (0 <= low <= high < length * 8):
                        raise ValueError("%s: %s bits %d..%d of %d bytes"
                                         % (at, setting["name"], low, high, length))
                    width = high - low + 1
                else:
                    width = length * 8
                for number, text in option_pairs(setting):
                    if number < 0 or (width < 32 and number >= (1 << width)):
                        raise ValueError("%s: %s option %d does not fit %d bits"
                                         % (at, setting["name"], number, width))
                    if not isinstance(text, str):
                        raise ValueError("%s: %s option %r is not text"
                                         % (at, setting["name"], text))
                for key in ("condition", "disabledBy"):
                    condition = condition_value(setting.get(key), at)
                    if condition and not condition[0]:
                        raise ValueError("%s: an empty condition name" % at)
                for key in ("auto", "hex", "text"):
                    if not isinstance(setting.get(key, False), bool):
                        raise ValueError("%s: %s %s is not a boolean"
                                         % (at, setting["name"], key))


def compile_strap(documents, version):
    """Kind 1: the descriptor strap tables."""
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
    return assemble(KIND_STRAP, sections, version)


def compile_configuration(documents, version):
    """Kind 2: the ME configuration, file by file and setting by setting."""
    mappings = []
    for document in documents:
        mappings.extend(document["maps"])
    ids = [mapping["id"] for mapping in mappings]
    if len(ids) != len(set(ids)):
        raise ValueError("map ids repeat: %s"
                         % ", ".join(sorted({i for i in ids if ids.count(i) > 1})))

    strings = StringPool()
    files_blob = bytearray()
    settings_blob = bytearray()
    options_blob = bytearray()
    option_offsets = {}
    map_records = []

    for mapping in mappings:
        files_offset = len(files_blob)
        file_records = []
        for entry in mapping["files"]:
            settings_offset = len(settings_blob)
            for setting in entry["settings"]:
                pairs = option_pairs(setting)
                options_offset = NO_REF
                if pairs:
                    key = tuple(pairs)
                    if key not in option_offsets:
                        option_offsets[key] = len(options_blob)
                        for number, text in pairs:
                            options_blob += struct.pack(
                                "<HHI", int(number), 0, strings.ref(text))
                    options_offset = option_offsets[key]
                bits = setting.get("bits")
                condition = condition_value(setting.get("condition"), entry["path"])
                disabled = condition_value(setting.get("disabledBy"), entry["path"])
                flags = 0
                if bits is not None:
                    flags |= 1
                if pairs:
                    flags |= 2
                if setting.get("label"):
                    flags |= 4
                if setting.get("help"):
                    flags |= 8
                if setting.get("auto"):
                    flags |= 16
                if setting.get("hex"):
                    flags |= 32
                if setting.get("text"):
                    flags |= 64
                if condition:
                    flags |= 128
                if disabled:
                    flags |= 256
                settings_blob += struct.pack(
                    "<IIHHBBIIIHHIiIiI",
                    strings.ref(setting["name"]),
                    int(setting["offset"]),
                    int(setting["length"]),
                    flags,
                    int(bits[0]) if bits else 0,
                    int(bits[1]) if bits else 0,
                    strings.ref(setting.get("label")),
                    strings.ref(setting.get("help")),
                    options_offset,
                    len(pairs),
                    0,
                    strings.ref(condition[0]) if condition else NO_REF,
                    condition[1] if condition else 0,
                    strings.ref(disabled[0]) if disabled else NO_REF,
                    disabled[1] if disabled else 0,
                    0,
                )
            file_records.append(struct.pack(
                "<IIIII",
                strings.ref(entry["path"]),
                strings.ref(entry["alias"]),
                len(entry["settings"]),
                settings_offset,
                0,
            ))
        files_blob += b"".join(file_records)
        map_records.append(struct.pack(
            "<IIIIII",
            strings.ref(mapping["id"]),
            strings.ref(mapping["name"]),
            len(mapping["files"]),
            files_offset,
            0,
            0,
        ))

    maps_blob = struct.pack("<I", len(map_records)) + b"".join(map_records)
    sections = [(SECTION_STRINGS, bytes(strings.data)),
                (SECTION_MAPS, maps_blob),
                (SECTION_FILES, bytes(files_blob)),
                (SECTION_SETTINGS, bytes(settings_blob)),
                (SECTION_OPTIONS, bytes(options_blob))]
    return assemble(KIND_CONFIGURATION,
                    [section for section in sections if section[1]], version)


def compile_uep(documents, version):
    """Kind 3: the FPF/UEP settings and their places in the bit arrays."""
    mappings = []
    for document in documents:
        mappings.extend(document["maps"])
    ids = [mapping["id"] for mapping in mappings]
    if len(ids) != len(set(ids)):
        raise ValueError("map ids repeat: %s"
                         % ", ".join(sorted({i for i in ids if ids.count(i) > 1})))

    strings = StringPool()
    settings_blob = bytearray()
    options_blob = bytearray()
    option_offsets = {}
    map_records = []
    for mapping in mappings:
        settings_offset = len(settings_blob)
        for setting in mapping["settings"]:
            pairs = pairs_of(setting, "options", mapping["id"])
            options_offset = NO_REF
            if pairs:
                key = tuple(pairs)
                if key not in option_offsets:
                    option_offsets[key] = len(options_blob)
                    for number, text in pairs:
                        options_blob += struct.pack(
                            "<HHI", number, 0, strings.ref(text))
                options_offset = option_offsets[key]
            flags = 0
            if setting.get("label"):
                flags |= 1
            if setting.get("section"):
                flags |= 2
            if setting.get("help"):
                flags |= 4
            if pairs:
                flags |= 8
            settings_blob += struct.pack(
                "<IHHHBBIIIIHH",
                strings.ref(setting["name"]),
                flags,
                int(setting.get("array", 0)),
                int(setting["offset"]),
                int(setting["bit"]),
                int(setting["count"]),
                strings.ref(setting.get("label")),
                strings.ref(setting.get("section")),
                strings.ref(setting.get("help")),
                options_offset,
                len(pairs),
                0,
            )
        map_records.append(struct.pack(
            "<IIHHIII",
            strings.ref(mapping["id"]),
            strings.ref(mapping["name"]),
            int(mapping.get("arrayStart", 0)),
            int(mapping.get("arraySize", 0)),
            len(mapping["settings"]),
            settings_offset,
            0,
        ))
    sections = [(SECTION_STRINGS, bytes(strings.data)),
                (SECTION_MAPS, struct.pack("<I", len(map_records))
                 + b"".join(map_records)),
                (SECTION_SETTINGS, bytes(settings_blob)),
                (SECTION_OPTIONS, bytes(options_blob))]
    return assemble(KIND_UEP,
                    [section for section in sections if section[1]], version)


def compile_gpio(documents, version):
    """Kind 4: the five value dictionaries behind a feature pin."""
    dictionaries = ("features", "usages", "ownerships", "padModes", "groups")
    mappings = []
    for document in documents:
        mappings.extend(document["maps"])
    ids = [mapping["id"] for mapping in mappings]
    if len(ids) != len(set(ids)):
        raise ValueError("map ids repeat: %s"
                         % ", ".join(sorted({i for i in ids if ids.count(i) > 1})))

    strings = StringPool()
    options_blob = bytearray()
    option_offsets = {}
    map_records = []
    for mapping in mappings:
        offsets, counts = {}, {}
        for key in dictionaries:
            pairs = pairs_of(mapping, key, mapping["id"])
            offsets[key], counts[key] = NO_REF, len(pairs)
            if pairs:
                content = tuple(pairs)
                if content not in option_offsets:
                    option_offsets[content] = len(options_blob)
                    for number, text in pairs:
                        options_blob += struct.pack(
                            "<HHI", number, 0, strings.ref(text))
                offsets[key] = option_offsets[content]
        map_records.append(struct.pack(
            "<IIIIIIIHHHHHH",
            strings.ref(mapping["id"]),
            strings.ref(mapping["name"]),
            offsets["features"], offsets["usages"], offsets["ownerships"],
            offsets["padModes"], offsets["groups"],
            counts["features"], counts["usages"], counts["ownerships"],
            counts["padModes"], counts["groups"], 0,
        ))
    sections = [(SECTION_STRINGS, bytes(strings.data)),
                (SECTION_MAPS, struct.pack("<I", len(map_records))
                 + b"".join(map_records)),
                (SECTION_OPTIONS, bytes(options_blob))]
    return assemble(KIND_GPIO,
                    [section for section in sections if section[1]], version)


def compile_documents(documents, version):
    kinds = {document["kind"] for document in documents}
    if len(kinds) != 1:
        raise ValueError("one binary holds one kind, not %s"
                         % ", ".join(sorted(kinds)))
    kind = kinds.pop()
    if kind == "strap":
        return compile_strap(documents, version)
    if kind == "configuration":
        return compile_configuration(documents, version)
    if kind == "uep":
        return compile_uep(documents, version)
    return compile_gpio(documents, version)


def assemble(kind, sections, version):
    """The header, the section table, the sections and the checksum."""
    offset = HEADER_SIZE + len(sections) * SECTION_TABLE
    table = bytearray()
    body = bytearray()
    for section_kind, payload in sections:
        table += struct.pack("<HHII", section_kind, 0, offset, len(payload))
        body += payload
        offset += len(payload)
    header = bytearray(struct.pack(
        "<4sHHIHHIIII", MAGIC, FORMAT_VERSION, HEADER_SIZE, version,
        kind, 0, len(sections), 0, 0, 0))
    data = bytes(header) + bytes(table) + bytes(body)
    checksum = fnv1a32(data)
    return data[:20] + struct.pack("<I", checksum) + data[24:]


def swift_version(version, enum_name="StrapMapDataVersion"):
    return (
        "// Generated by `Skills/me-eom-structures/scripts/map_bin.py`. "
        "Do not edit.\n"
        "//\n"
        "// The binary map file and the code are marked with one version: the\n"
        "// reader refuses a file whose version differs, so a stale resource is\n"
        "// reported before a byte of it is interpreted.\n"
        "enum %s {\n"
        "    static let formatVersion: UInt16 = %d\n"
        "    static let version: UInt32 = %d\n"
        "}\n" % (enum_name, FORMAT_VERSION, version))


def source_hash(paths):
    """A digest of the source JSON, in the order the binary compiles them.

    The version changes when this changes, and only then: a rebuild that only
    rewrites the same descriptions keeps the version and the bytes.
    """
    digest = hashlib.sha256()
    for path in paths:
        with open(path, "rb") as handle:
            data = handle.read()
        digest.update(struct.pack("<I", len(data)))
        digest.update(data)
    return digest.hexdigest()


def read_manifest(path):
    if not os.path.exists(path):
        return {"schema": "byteripper.maps/1", "version": 0, "sourceHash": None}
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("schema") != "byteripper.maps/1":
        raise ValueError("%s: schema is not byteripper.maps/1" % path)
    return manifest


def write_manifest(path, version, digest):
    manifest = {"schema": "byteripper.maps/1", "version": version,
                "sourceHash": digest}
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=1, sort_keys=True)
        handle.write("\n")


def build(args):
    if "--out" not in args:
        print("build needs --out", file=sys.stderr)
        return 2
    if "--manifest" not in args:
        print("build needs --manifest", file=sys.stderr)
        return 2
    out = args[args.index("--out") + 1]
    manifest_path = args[args.index("--manifest") + 1]
    swift_file = (args[args.index("--swift-version-file") + 1]
                  if "--swift-version-file" in args else None)
    enum_name = (args[args.index("--swift-enum-name") + 1]
                 if "--swift-enum-name" in args else "StrapMapDataVersion")
    check = "--check" in args
    skip = set()
    for name in ("--out", "--manifest", "--swift-version-file", "--swift-enum-name"):
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

    try:
        manifest = read_manifest(manifest_path)
        digest = source_hash(paths)
    except (OSError, ValueError) as error:
        return fail(str(error))

    if check:
        version = manifest["version"]
        if manifest.get("sourceHash") != digest:
            return fail("the JSON sources changed since version %d: rebuild "
                        "with --build" % version)
        if swift_file:
            try:
                with open(swift_file, encoding="utf-8") as handle:
                    if handle.read() != swift_version(version, enum_name):
                        return fail("%s is not marked with version %d: rebuild "
                                    "with --build" % (swift_file, version))
            except OSError as error:
                return fail(str(error))
        try:
            data = compile_documents(documents, version)
        except ValueError as error:
            return fail(str(error))
        try:
            with open(out, "rb") as handle:
                committed = handle.read()
        except OSError as error:
            return fail(str(error))
        if committed != data:
            return fail("%s is stale: rebuild with --build" % out)
        print("%s: version %d, %d maps, %d bytes — current"
              % (out, version,
                 sum(len(document["maps"]) for document in documents), len(data)),
              file=sys.stderr)
        return 0

    changed = manifest.get("sourceHash") != digest
    version = (manifest["version"] + 1) if changed else manifest["version"]
    try:
        if changed:
            write_manifest(manifest_path, version, digest)
        if swift_file:
            if changed or not os.path.exists(swift_file):
                with open(swift_file, "w", encoding="utf-8") as handle:
                    handle.write(swift_version(version, enum_name))
            else:
                with open(swift_file, encoding="utf-8") as handle:
                    if handle.read() != swift_version(version, enum_name):
                        return fail("%s is not marked with version %d; set it "
                                    "to that version before building"
                                    % (swift_file, version))
        data = compile_documents(documents, version)
    except (OSError, ValueError) as error:
        return fail(str(error))

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(data)
    print("%s: version %d (%s), %d maps, %d bytes"
          % (out, version, "bumped" if changed else "unchanged",
             sum(len(document["maps"]) for document in documents), len(data)),
          file=sys.stderr)
    return 0


def dump_configuration(data, sections, text):
    """Kind 2, as the reader sees it: maps, files, settings and options."""
    maps_at, _ = sections.get(SECTION_MAPS, (0, 0))
    files_at, _ = sections.get(SECTION_FILES, (0, 0))
    settings_at, _ = sections.get(SECTION_SETTINGS, (0, 0))
    options_at, _ = sections.get(SECTION_OPTIONS, (0, 0))
    total = struct.unpack_from("<I", data, maps_at)[0]
    for index in range(total):
        at = maps_at + 4 + index * CONFIG_MAP_RECORD
        id_ref, name_ref, file_count, files_offset, _, _ = struct.unpack_from(
            "<IIIIII", data, at)
        print("map %s (%s), %d files"
              % (text(id_ref), text(name_ref), file_count))
        for file_index in range(file_count):
            fat = files_at + files_offset + file_index * FILE_RECORD
            (path_ref, alias_ref, setting_count, settings_offset,
             _) = struct.unpack_from("<IIIII", data, fat)
            print("  file %s (%s), %d settings"
                  % (text(path_ref), text(alias_ref), setting_count))
            for setting_index in range(setting_count):
                sat = settings_at + settings_offset + setting_index * SETTING_RECORD
                (name_ref, offset, length, flags, low, high,
                 label_ref, help_ref, options_offset, options_count, _,
                 condition_ref, condition_value, disabled_ref,
                 disabled_value, _) = struct.unpack_from(
                    "<IIHHBBIIIHHIiIiI", data, sat)
                marks = []
                if flags & 1:
                    marks.append("bits %d..%d" % (low, high))
                if flags & 16:
                    marks.append("auto")
                if flags & 32:
                    marks.append("hex")
                if flags & 64:
                    marks.append("text")
                if flags & 128:
                    marks.append("if %s = %d" % (text(condition_ref), condition_value))
                if flags & 256:
                    marks.append("off if %s = %d"
                                 % (text(disabled_ref), disabled_value))
                print("    %-55s offset %4d length %3d%s"
                      % (text(name_ref), offset, length,
                         (", " + ", ".join(marks)) if marks else ""))
                if flags & 4:
                    print("        label %r" % text(label_ref))
                if flags & 8:
                    print("        help %r" % text(help_ref))
                if flags & 2:
                    for option_index in range(options_count):
                        number, _, option_ref = struct.unpack_from(
                            "<HHI", data, options_at + options_offset
                            + option_index * OPTION_RECORD)
                        print("        %d = %r" % (number, text(option_ref)))
    return 0


def dump_uep(data, sections, text):
    maps_at, _ = sections.get(SECTION_MAPS, (0, 0))
    settings_at, _ = sections.get(SECTION_SETTINGS, (0, 0))
    options_at, _ = sections.get(SECTION_OPTIONS, (0, 0))
    total = struct.unpack_from("<I", data, maps_at)[0]
    for index in range(total):
        at = maps_at + 4 + index * UEP_MAP_RECORD
        id_ref, name_ref, array_start, array_size, count, offset, _ = \
            struct.unpack_from("<IIHHIII", data, at)
        print("map %s (%s), arrayStart 0x%X, arraySize 0x%X, %d settings"
              % (text(id_ref), text(name_ref), array_start, array_size, count))
        for setting_index in range(count):
            sat = settings_at + offset + setting_index * UEP_SETTING_RECORD
            (name_ref, flags, array, place, bit, bits, label_ref, section_ref,
             help_ref, options_offset, options_count, _) = struct.unpack_from(
                "<IHHHBBIIIIHH", data, sat)
            marks = ["array %d, offset 0x%X, bit %d, %d bits"
                     % (array, place, bit, bits)]
            if flags & 1:
                marks.append("label %r" % text(label_ref))
            if flags & 2:
                marks.append("section %r" % text(section_ref))
            print("  %-45s %s" % (text(name_ref), ", ".join(marks)))
            if flags & 8:
                for option_index in range(options_count):
                    number, _, option_ref = struct.unpack_from(
                        "<HHI", data, options_at + options_offset
                        + option_index * OPTION_RECORD)
                    print("      %d = %r" % (number, text(option_ref)))
    return 0


def dump_gpio(data, sections, text):
    maps_at, _ = sections.get(SECTION_MAPS, (0, 0))
    options_at, _ = sections.get(SECTION_OPTIONS, (0, 0))
    total = struct.unpack_from("<I", data, maps_at)[0]
    names = ("features", "usages", "ownerships", "padModes", "groups")
    for index in range(total):
        at = maps_at + 4 + index * GPIO_MAP_RECORD
        fields = struct.unpack_from("<IIIIIIIHHHHHH", data, at)
        print("map %s (%s)" % (text(fields[0]), text(fields[1])))
        offsets = fields[2:7]
        counts = fields[7:12]
        for name, offset, count in zip(names, offsets, counts):
            print("  %s: %d" % (name, count))
            if offset == NO_REF:
                continue
            for entry_index in range(count):
                number, _, entry_ref = struct.unpack_from(
                    "<HHI", data, options_at + offset + entry_index * OPTION_RECORD)
                print("    %d = %r" % (number, text(entry_ref)))
    return 0


def dump(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < HEADER_SIZE or data[:4] != MAGIC:
        return fail("%s: not a BRM1 file" % path)
    magic, version, header_size, data_version, kind, flags, count, checksum, _, _ = \
        struct.unpack_from("<4sHHIHHIIII", data, 0)
    zeroed = bytearray(data)
    zeroed[20:24] = b"\x00\x00\x00\x00"
    print("format %d, version %d, kind %d, %d bytes, checksum %s"
          % (version, data_version, kind, len(data),
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
    if kind == KIND_CONFIGURATION:
        return dump_configuration(data, sections, text)
    if kind == KIND_UEP:
        return dump_uep(data, sections, text)
    if kind == KIND_GPIO:
        return dump_gpio(data, sections, text)
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
        try:
            return dump(args[1])
        except BrokenPipeError:
            # `dump … | head` is a normal way to look at a table.
            return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
