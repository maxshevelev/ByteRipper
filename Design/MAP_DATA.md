# The compiled map files

Four kinds of description used to be emitted as Swift literals: the
descriptor's strap layouts (`StrapMap+PCH.swift` alone was 6 407 lines and
650 KB), the ME configuration maps, the FPF/UEP layouts and the GPIO pin
dictionaries. All are descriptions, not logic, and change only when a tool
version is added. They now live as JSON sources, which is what a review reads,
and are compiled into binaries, which is what ships.

The format is deliberately small and language-neutral: the web edition can
read the same file with a reader of its own, and no Foundation type or Swift
layout is involved.

## Where things live

| What | Where | Committed |
| --- | --- | --- |
| Strap JSON sources | `Packages/UEFIImage/MapSources/strap/*.json` | yes |
| Strap version and source digest | `Packages/UEFIImage/MapSources/manifest.json` | yes |
| Strap binary | `Packages/UEFIImage/Sources/UEFIImage/Resources/StrapMaps/StrapMaps.bin` | yes |
| Strap code's version mark | `Packages/UEFIImage/Sources/UEFIImage/StrapMapDataVersion.swift` | yes, generated |
| Strap reader | `Packages/UEFIImage/Sources/UEFIImage/StrapMapData.swift` | yes |
| Configuration JSON sources | `Packages/MEFirmware/MapSources/configuration/*.json` | yes |
| Configuration version and source digest | `Packages/MEFirmware/MapSources/manifest.json` | yes |
| Configuration binary | `Packages/MEFirmware/Sources/MEFirmware/Resources/ConfigMaps/ConfigMaps.bin` | yes |
| Configuration code's version mark | `Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationDataVersion.swift` | yes, generated |
| Configuration reader | `Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationData.swift` | yes |
| UEP JSON sources | `Packages/MEFirmware/MapSources/uep/*.json` | yes |
| UEP version and source digest | `Packages/MEFirmware/MapSources/uep/manifest.json` | yes |
| UEP binary | `Packages/MEFirmware/Sources/MEFirmware/Resources/UEPMaps/UEPMaps.bin` | yes |
| UEP code's version mark | `Packages/MEFirmware/Sources/MEFirmware/Configuration/UEPMapDataVersion.swift` | yes, generated |
| UEP reader | `Packages/MEFirmware/Sources/MEFirmware/Configuration/UEPMapData.swift` | yes |
| GPIO JSON sources | `Packages/MEFirmware/MapSources/gpio/*.json` | yes |
| GPIO version and source digest | `Packages/MEFirmware/MapSources/gpio/manifest.json` | yes |
| GPIO binary | `Packages/MEFirmware/Sources/MEFirmware/Resources/GPIOMaps/GPIOMaps.bin` | yes |
| GPIO code's version mark | `Packages/MEFirmware/Sources/MEFirmware/Configuration/GPIOPinMapDataVersion.swift` | yes, generated |
| GPIO reader | `Packages/MEFirmware/Sources/MEFirmware/Configuration/GPIOPinMapData.swift` | yes |
| Envelope reader | `Packages/MapData/Sources/MapData/MapFile.swift` | yes |
| Compiler and dumper | `Skills/me-eom-structures/scripts/map_bin.py` | yes |

The JSON is the source of truth. Each family's manifest holds its version and
a digest of its JSON files; the binary and the Swift constant are generated
from it. `map_bin.py build --check` rebuilds them in memory and compares, so a
stale pair is reported rather than shipped. The four families version
independently: a strap change does not move the configuration map's version,
nor either family move the UEP or GPIO one.

## JSON

One file per group of maps, one record per line, so a diff reads a record at a
time. Both kinds share the envelope:

```json
{
 "kind": "strap",
 "schema": "byteripper.map/1",
 "tool": "Flash Image Tool 18.1",
 "maps": [
  {"id": "pch130", "name": "…", "set": "pch", "words": 130, "fields": [
   {"bits": [0, 0], "default": 0, "name": "PCH_Strap_…", "word": 0}
  ]}
 ]
}
```

- `set` groups a strap table for the reader: `pch`, `spt`, `cpu` or `other`.
- `fields[].bits` is `[low, high]`, inclusive.
- `default` is the number the tool builds the field with, or `null`.
- `label` and `options` are optional; options are `[value, words]` pairs.
- `source` is provenance for a reviewer; the compiler ignores it.

A configuration file states files and settings instead:

```json
{
 "kind": "configuration",
 "schema": "byteripper.map/1",
 "tool": "15.0",
 "maps": [
  {"id": "csme15", "name": "CSME 15 (…)", "files": [
   {"path": "/home/mca/eom_config", "alias": "eom_config", "settings": [
    {"name": "EomFirstBootEnabled", "offset": 0, "length": 2,
     "bits": [0, 0], "options": [[0, "No"], [1, "Yes"]],
     "label": "EOM on First Boot Enabled", "help": "…"}
   ]}
  ]}
 ]
}
```

- A setting's `length` is the field's width in bytes; `bits` is relative to
  that field, and absent on a whole-field setting.
- `auto`, `hex`, `text` are present only when true.
- `condition` and `disabledBy` are `{name, value}` objects when present.

A UEP file states settings and their places in the container's bit arrays:

```json
{
 "kind": "uep",
 "schema": "byteripper.map/1",
 "tool": "Modular Flash Image Tool 18.0",
 "maps": [
  {"id": "csme18", "name": "CSME 18 (…)", "arrayStart": 8, "arraySize": 128,
   "settings": [
    {"name": "BTG_PROFILE", "array": 0, "offset": 72, "bit": 30, "count": 3,
     "label": "Boot Guard Profile", "section": "BootGuardConfiguration",
     "options": [[0, "Boot Guard Disabled"], [3, "Debug Profile"],
                 [4, "Verified Boot"], [5, "Verified and Measured Boot"]]}
   ]}
 ]
}
```

- `arrayStart` is how far past the container's signature the first array
  begins; `arraySize` is the stride between arrays (0 where the map keeps to
  the first and offsets are already places in it).
- `array` is the array a setting sits in, `offset` a byte into it.
- `label`, `section`, `help` and `options` are optional.

A GPIO file states the five value dictionaries behind a feature pin:

```json
{
 "kind": "gpio",
 "schema": "byteripper.map/1",
 "tool": "15.0",
 "maps": [
  {"id": "csme15", "name": "CSME 15 (Flash Image Tool 15.0)",
   "features": [[1, "GPIO_TOUCH_FEATURE_ID"]],
   "usages": [[0, "INTEGRATED_TOUCH_1"]],
   "ownerships": [[1, "CSME_MODE"]],
   "padModes": [[4, "DEFAULT_MODE"]],
   "groups": [[4, "GPP_E"]]}
 ]
}
```

Every dictionary maps a number to the tool's name; an empty one may be
omitted.

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
| 12 | u16 | kind (1 = strap, 2 = configuration, 3 = UEP, 4 = GPIO) |
| 14 | u16 | flags |
| 16 | u32 | section count |
| 20 | u32 | checksum: FNV-1a over the whole file with this field zeroed |
| 24 | u32 | reserved |
| 28 | u32 | reserved |

### Section table

One 12-byte entry per section: `u16 kind`, `u16 flags`, `u32 offset`,
`u32 length`. Section kinds: 1 strings, 2 maps, 3 fields, 4 options, 5 files,
6 settings. A reader skips a section kind it does not know by its length.

### Strings (1) and options (4)

Strings are NUL-terminated UTF-8, deduplicated. A string reference is a byte
offset into this section; `0xFFFFFFFF` means "no string". Strings may not
contain NUL.

An option is 8 bytes: `u16 value`, `u16 reserved`, `u32 text reference`.
Options shared by settings are stored once and referenced by offset.

### Kind 1: strap

Maps (2): `u32 count`, then 24 bytes per map:

| Type | Field |
| --- | --- |
| u32 | id string reference |
| u32 | name string reference |
| u16 | section words |
| u16 | set (0 pch, 1 spt, 2 cpu, 3 other, 4 pmc, 5 mip, 6 legacy, 7 sptcpu) |
| u32 | field count |
| u32 | field array offset, from the fields section start |
| u32 | help reference (reserved; `0xFFFFFFFF`) |

Fields (3): 28 bytes per field:

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

### Kind 2: configuration

Maps (2): `u32 count`, then 24 bytes per map:

| Type | Field |
| --- | --- |
| u32 | id string reference |
| u32 | name string reference |
| u32 | file count |
| u32 | file array offset, from the files section start |
| u32 | reserved |
| u32 | reserved |

Files (5): 20 bytes per file:

| Type | Field |
| --- | --- |
| u32 | path reference |
| u32 | alias reference |
| u32 | setting count |
| u32 | setting array offset, from the settings section start |
| u32 | reserved |

Settings (6): 50 bytes per setting:

| Type | Field |
| --- | --- |
| u32 | name reference |
| u32 | offset into the file |
| u16 | length in bytes |
| u16 | flags: 1 bits, 2 options, 4 label, 8 help, 16 auto, 32 hex, 64 text, 128 condition, 256 disabled-by |
| u8 | low bit |
| u8 | high bit |
| u32 | label reference |
| u32 | help reference |
| u32 | options offset, from the options section start |
| u16 | options count |
| u16 | reserved |
| u32 | condition name reference |
| i32 | condition value |
| u32 | disabled-by name reference |
| i32 | disabled-by value |
| u32 | reserved |

### Kind 3: UEP

Maps (2): `u32 count`, then 24 bytes per map:

| Type | Field |
| --- | --- |
| u32 | id string reference |
| u32 | name string reference |
| u16 | array start |
| u16 | array size |
| u32 | setting count |
| u32 | setting array offset, from the settings section start |
| u32 | reserved |

Settings (6): 32 bytes per setting:

| Type | Field |
| --- | --- |
| u32 | name reference |
| u16 | flags: 1 label, 2 section, 4 help, 8 options |
| u16 | array |
| u16 | offset into the array |
| u8 | bit |
| u8 | bit count |
| u32 | label reference |
| u32 | section reference |
| u32 | help reference |
| u32 | options offset, from the options section start |
| u16 | options count |
| u16 | reserved |

### Kind 4: GPIO

Maps (2): `u32 count`, then 40 bytes per map:

| Type | Field |
| --- | --- |
| u32 | id string reference |
| u32 | name string reference |
| u32 | features offset, from the options section start |
| u32 | usages offset |
| u32 | ownerships offset |
| u32 | pad modes offset |
| u32 | groups offset |
| u16 | features count |
| u16 | usages count |
| u16 | ownerships count |
| u16 | pad modes count |
| u16 | groups count |
| u16 | reserved |

Each dictionary is an array of option records (8 bytes each, as above); an
empty one has count 0 and `0xFFFFFFFF` as its offset.

## Versioning

There are two numbers, for two different jobs:

- **format version** changes when the layout above changes. The readers have
  one they were written for and refuse any other; unknown sections are
  skipped, so a newer file with an unchanged core still reads.
- **version** is the data contract. It lives in the family's `manifest.json`
  together with a digest of its source JSON, and changes **only when that
  digest changes**. The compile step recomputes the digest: a changed source
  increments the version once, an unchanged one leaves it. The same number is
  written into the binary and into the family's Swift constant
  (`StrapMapDataVersion`, `MEConfigurationDataVersion`, `UEPMapDataVersion`,
  `GPIOPinMapDataVersion`), and the reader compares the file's version with
  the code's **before reading a section**.

When a reader's *expectations* change without a data change, the version is
bumped by hand in the manifest; the build then requires the code mark to carry
it too. The build also refuses when the source digest is unchanged but the
Swift constant carries another number — the code would not be marked with the
data it reads.

The checksum catches an edited or truncated file independently of the version.

## Rebuilding

```bash
# 1. Emit the JSON from the tools (see Skills/me-eom-structures/SKILL.md).
python3 Skills/me-eom-structures/scripts/strap_map.py \
    ~/Downloads/1/fit-15.0.exe ~/Downloads/1/fit-14.0.exe \
    --words 69,70,74,90,101,114,115 --format json > \
    Packages/UEFIImage/MapSources/strap/pch.json
python3 Skills/me-eom-structures/scripts/fit_map.py ~/Downloads/1/fit-15.0.exe \
    --straps tgp_lp --generation 15 --tool 15.0 --format json > \
    Packages/MEFirmware/MapSources/configuration/csme15.json
python3 Skills/me-eom-structures/scripts/uep_fit_map.py ~/Downloads/1/fit-15.0.exe \
    --generation 15 --tool 15.0 --format json > \
    Packages/MEFirmware/MapSources/uep/csme15.json
python3 Skills/me-eom-structures/scripts/gpio_map.py ~/Downloads/1/fit-15.0.exe \
    --generation 15 --tool 15.0 --format json > \
    Packages/MEFirmware/MapSources/gpio/csme15.json

# 2. Compile a family. The version comes from its manifest; if the JSON digest
#    changed, it is incremented and written into the binary and Swift constant.
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/UEFIImage/Sources/UEFIImage/Resources/StrapMaps/StrapMaps.bin \
    --manifest Packages/UEFIImage/MapSources/manifest.json \
    --swift-version-file Packages/UEFIImage/Sources/UEFIImage/StrapMapDataVersion.swift \
    Packages/UEFIImage/MapSources/strap/pch.json \
    Packages/UEFIImage/MapSources/strap/pch18.json \
    Packages/UEFIImage/MapSources/strap/spt.json \
    Packages/UEFIImage/MapSources/strap/cpu.json \
    Packages/UEFIImage/MapSources/strap/sptcpu.json \
    Packages/UEFIImage/MapSources/strap/pmc.json \
    Packages/UEFIImage/MapSources/strap/mip.json \
    Packages/UEFIImage/MapSources/strap/legacy-ibx.json \
    Packages/UEFIImage/MapSources/strap/legacy-cpt.json \
    Packages/UEFIImage/MapSources/strap/legacy-lpt.json
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/MEFirmware/Sources/MEFirmware/Resources/ConfigMaps/ConfigMaps.bin \
    --manifest Packages/MEFirmware/MapSources/manifest.json \
    --swift-version-file Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationDataVersion.swift \
    --swift-enum-name MEConfigurationDataVersion \
    Packages/MEFirmware/MapSources/configuration/csme11.json … csme18.json
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/MEFirmware/Sources/MEFirmware/Resources/UEPMaps/UEPMaps.bin \
    --manifest Packages/MEFirmware/MapSources/uep/manifest.json \
    --swift-version-file Packages/MEFirmware/Sources/MEFirmware/Configuration/UEPMapDataVersion.swift \
    --swift-enum-name UEPMapDataVersion \
    Packages/MEFirmware/MapSources/uep/csme12.json … csme18.json
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/MEFirmware/Sources/MEFirmware/Resources/GPIOMaps/GPIOMaps.bin \
    --manifest Packages/MEFirmware/MapSources/gpio/manifest.json \
    --swift-version-file Packages/MEFirmware/Sources/MEFirmware/Configuration/GPIOPinMapDataVersion.swift \
    --swift-enum-name GPIOPinMapDataVersion \
    Packages/MEFirmware/MapSources/gpio/csme11.json … csme15.json

# 3. Verify the committed pairs (no write, byte-for-byte).
python3 Skills/me-eom-structures/scripts/map_bin.py build --check …same arguments…

# 4. Read a binary back, for review or debugging.
python3 Skills/me-eom-structures/scripts/map_bin.py dump <file.bin>
```

The map order in a command is the order the reader returns; keep the commands
in `Skills/me-eom-structures/SKILL.md`, which lists every source file.

## The web edition

A reader needs: little-endian 16/32-bit reads, byte slices, UTF-8, and FNV-1a.
It does not need a serializer, a Foundation type or a JSON parser. The `dump`
mode is the reference rendering, and the same binary and the same tests'
expected counts apply. Data files are copied as they are.

## What is converted

- **Strap:** every table — the PCH set (`pch69` … `pch115`, `pch130`), FIT
  11's SPT set (`sptPch66` … `sptPch139`), the processor sections
  (`cpu1` … `cpu25`, `sptCpu3`), the PMC soft straps (`pmc7` … `pmc22`), the
  MIP CPU messages (`mipCpu17`, `mipCpu20`) and the legacy guides' PCH tables
  (`pch16`, `pch18`, `pch21`). `cpu.json` was bootstrapped from the generated
  processor tables of 2026-10-17: the FIT builds at hand state a different
  field set for those lengths, so it is edited as JSON until that is
  reconciled (`Skills/me-eom-structures/SKILL.md`).
- **Configuration:** CSME 11–16 (mobile and desktop where the generation has
  two halves) and CSME 18. CSME 16's map is merged from 16.1.42 and 16.0.15:
  the newer build's database no longer lists `/home/mctp/smt3_devices`, and
  the older one states it.
- **UEP:** CSME 12–16 and 18, each from its own tool build. 17 has no map yet.
- **GPIO:** CSME 11–15, the generations whose Flash Image Tool carries the
  `GpioCsme*` value classes. CSME 16 and 18 use MFIT's database, which does
  not, so they have no map.
