# The strap tables as data

The descriptor's strap layouts — a field's name, its word and bits, its default
and, for the SoC straps, its label and option words — used to be emitted as
Swift literals: `StrapMap+PCH.swift` alone was 6 407 lines and 650 KB. They are
descriptions, not logic, and they change only when a tool version is added.
They now live as JSON sources, which is what a review reads, and are compiled
into one binary, which is what ships.

The format below is deliberately small and language-neutral: the web edition
can read the same file with a reader of its own, and no Foundation type or
Swift layout is involved.

## Where things live

| What | Where | Committed |
| --- | --- | --- |
| JSON sources | `Packages/UEFIImage/MapSources/strap/*.json` | yes |
| Version and source digest | `Packages/UEFIImage/MapSources/manifest.json` | yes |
| Binary | `Packages/UEFIImage/Sources/UEFIImage/Resources/StrapMaps/StrapMaps.bin` | yes |
| Code's version mark | `Packages/UEFIImage/Sources/UEFIImage/StrapMapDataVersion.swift` | yes, generated |
| Reader | `Packages/UEFIImage/Sources/UEFIImage/StrapMapData.swift` | yes |
| Compiler and dumper | `Skills/me-eom-structures/scripts/map_bin.py` | yes |

The JSON is the source of truth. The manifest holds the version and a digest
of those JSON files; the binary and the Swift constant are generated from it.
`map_bin.py build --check` rebuilds them in memory and compares, so a stale
pair is reported rather than shipped.

## JSON

One file per group of tables, one field per line, so a diff reads a field at a
time:

```json
{
 "kind": "strap",
 "schema": "byteripper.map/1",
 "tool": "Flash Image Tool 18.1",
 "maps": [
  {"id": "pch130", "name": "…", "set": "pch", "words": 130, "fields": [
   {"bits": [0, 0], "default": 0, "name": "PCH_Strap_…", "word": 0},
   …
  ]}
 ]
}
```

- `set` groups the table for the reader: `pch`, `spt`, `cpu` or `other`.
- `fields[].bits` is `[low, high]`, inclusive.
- `default` is the number the tool builds the field with, or `null`.
- `label` and `options` are optional; options are `[value, words]` pairs.
- `source` is provenance for a reviewer; the compiler ignores it.

## Binary

All numbers are little-endian and unaligned; every offset and length is checked
before it is used.

### Header, 32 bytes

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | 4 bytes | `BRM1` |
| 4 | u16 | format version (1) |
| 6 | u16 | header size (32) |
| 8 | u32 | version (the data contract) |
| 12 | u16 | kind (1 = strap) |
| 14 | u16 | flags |
| 16 | u32 | section count |
| 20 | u32 | checksum: FNV-1a over the whole file with this field zeroed |
| 24 | u32 | reserved |
| 28 | u32 | reserved |

### Section table

One 12-byte entry per section: `u16 kind`, `u16 flags`, `u32 offset`,
`u32 length`. Section kinds: 1 strings, 2 maps, 3 fields, 4 options. A reader
skips a section kind it does not know by its length.

### Strings (1)

NUL-terminated UTF-8, deduplicated. A string reference is a byte offset into
this section; `0xFFFFFFFF` means "no string". Strings may not contain NUL.

### Maps (2)

`u32 count`, then 24 bytes per map:

| Type | Field |
| --- | --- |
| u32 | id string reference |
| u32 | name string reference |
| u16 | section words |
| u16 | set (0 pch, 1 spt, 2 cpu, 3 other) |
| u32 | field count |
| u32 | field array offset, from the fields section start |
| u32 | help reference (reserved; `0xFFFFFFFF`) |

### Fields (3)

28 bytes per field:

| Type | Field |
| --- | --- |
| u32 | name reference |
| u16 | word |
| u8 | low bit |
| u8 | high bit |
| u16 | flags: 1 default present, 2 options present, 4 label present |
| u32 | default |
| u32 | label reference |
| u32 | options offset, from the options section start |
| u16 | options count |
| u16 | reserved |

### Options (4)

8 bytes per option: `u16 value`, `u16 reserved`, `u32 text reference`.

## Versioning

There are two numbers, for two different jobs:

- **format version** changes when the layout above changes. The reader has one
  it was written for and refuses any other; unknown sections are skipped, so a
  newer file with an unchanged core still reads.
- **version** is the data contract. It lives in `manifest.json` together with
  a digest of the source JSON, and changes **only when that digest changes**.
  The compile step recomputes the digest: a changed source increments the
  version once, an unchanged one leaves it; a rebuild that rewrites the same
  descriptions keeps both the version and the bytes. The same number is
  written into the binary and into `StrapMapDataVersion.swift`, and the reader
  compares the file's version with the code's **before reading a section**. A
  stale binary is therefore reported as a stale binary, never misread as a
  changed layout.

When the reader's *expectations* change without a data change (a new field
interpreted, a different rule), the version is bumped by hand in the manifest;
the build then requires the code mark to carry it too and refuses otherwise.
The build also refuses when the source digest is unchanged but
`StrapMapDataVersion.swift` carries another number — the code would not be
marked with the data it reads.

The checksum catches an edited or truncated file independently of the version.

The reader degrades: `StrapMapData.map(id:)` returns nil, `DescriptorStrapMap.all`
is empty, and the panel shows a strap section's words as numbers. Tests use the
`DescriptorStrapMap.pch69`-style accessors, which stop with the reader's reason
instead of returning an empty table.

## Rebuilding

```bash
# 1. Emit the JSON from the tools (see Skills/me-eom-structures/SKILL.md).
python3 Skills/me-eom-structures/scripts/strap_map.py \
    ~/Downloads/1/fit-15.0.exe ~/Downloads/1/fit-14.0.exe \
    --words 69,70,74,90,101,114,115 --format json > \
    Packages/UEFIImage/MapSources/strap/pch.json

# 2. Compile. The version comes from the manifest; if the JSON digest changed,
#    it is incremented and written into the binary and the Swift constant.
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/UEFIImage/Sources/UEFIImage/Resources/StrapMaps/StrapMaps.bin \
    --manifest Packages/UEFIImage/MapSources/manifest.json \
    --swift-version-file Packages/UEFIImage/Sources/UEFIImage/StrapMapDataVersion.swift \
    Packages/UEFIImage/MapSources/strap/pch.json \
    Packages/UEFIImage/MapSources/strap/pch18.json \
    Packages/UEFIImage/MapSources/strap/spt.json

# 3. Verify the committed pair (no write, byte-for-byte).
python3 Skills/me-eom-structures/scripts/map_bin.py build --check …same arguments…

# 4. Read a binary back, for review or debugging.
python3 Skills/me-eom-structures/scripts/map_bin.py dump <StrapMaps.bin>
```

The map order in the command is the order the reader returns: pch.json,
pch18.json, spt.json — the PCH set, then the 130-word SoC table, then SPT's.

## The web edition

A reader needs: little-endian 16/32-bit reads, byte slices, UTF-8, and FNV-1a.
It does not need a serializer, a Foundation type or a JSON parser. The
`dump` mode is the reference rendering, and the same binary and the same tests'
expected field counts apply. Data files are copied as they are.

## Pilot scope

This first conversion covers the PCH tables (`pch69` … `pch115`, `pch130`) and
FIT 11's SPT set (`sptPch66` … `sptPch139`). The legacy guide tables
(`pch16`, `pch18`, `pch21`), the processor tables (`cpu*`, `sptCpu3`), the MIP
tables and the PMC tables are still Swift; they follow the same format once it
has been measured in use.
