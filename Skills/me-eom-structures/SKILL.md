---
name: me-eom-structures
description: Read the End-of-Manufacturing, Boot Guard and OEM-key facts out of an ME dump — the MFS/configuration records behind them, the UEP area, and how they compare with MFIT's own report. Use when working on the ME Analyzer's manufacturing/Boot Guard rows, when a dump's EOM or Boot Guard state has to be established, or when MFIT's build report has to be checked against the bytes.
---

# ME EOM / Boot Guard / OEM key structures

This is the research home for three facts a repair bench needs from an ME dump,
and for the flash structures that carry them. Everything here was established on
real dumps and cross-checked against MFIT's own configuration and build report
(see `reference/structures.md` for the addresses, values and sources).

What the app makes of them, which generation each is read for, and what is still
undetermined on the older ones — the reason to come back here — is
`Design/ME_STRUCTURES.md`.

## The three facts and where they live

| fact | MFIT setting | flash |
|---|---|---|
| will the platform close Manufacturing at first boot | `CsePlugin:EomNvar:EOM#EomFirstBootEnabled` | the **descriptor's access rights** decide it (the host CPU / BIOS master: factory rights close it, all-ones does not); the flag is an explicit order on top — bit 0 of the MFS file `/home/mca/eom_config` (2 bytes), written both into the image's OEM Configuration partition and into the live file system, and **only MFIT sets it**. A flag of 0 means the descriptor answers, not that Manufacturing stays open |
| what EOM commits | `CsePlugin:EomNvar:EOM_Config#FlexibleEomSettings` | bits 1–2 of the same record |
| what the board the dump came from already did | — | MFS `/home/mca/eom` (1 byte, 1 = closed) — read as evidence that the file system was read, **not** reported: the row answers for the next first boot |
| Boot Guard level | `CsePlugin:UEP:BtGuardProfileConfig` (`0 - No_FVME`, `3 - VM`, `4 - FVE`, `5 - FVME`) | the JSON record in the **CDMD** partition's configuration, where the number is an index into that list; and, where the image has no such record (every CSME 15 image), the four settings a profile is made of, as bits of the UEP area's first `UepBitsArray` — `$UEP`+0x6E, bits 0 FBG ACM, 3 protect, 4 measured, 5 verified, with Intel's `BootGuardProfiles` table naming the combinations. Read on CSME 15 and 16 only, the generations it was verified on |
| OEM public key hash | `CsePlugin:UEP:OemPublicKeyHash` (all zeros = signing disabled) | the record the image's **generation** keeps: 0xA0 bytes into the UEP area's entry, 48 bytes (SHA-384) on CSME 15 and later — mirrored in the MFS key table — and 0x90 bytes in, 32 bytes (SHA-256) with 16 bytes of assignment bits behind it, on CSME 12 to 14. What the field holds is the finding: zeros = signing disabled, `FF` = never written, anything else = a layout the reader does not walk |

The BIOS side carries its own, different key hash — the Boot Guard Key Manifest the
FIT table points at — and that one is *not* the OEM public key hash MFIT reports.

## Reading a dump

```bash
python3 Skills/me-eom-structures/scripts/me_eom.py <dump> [<dump>…]
```

It prints, per dump: whether the descriptor's BIOS master is open or locked, the
UEP container's address, its header and how much of the area is erased, the OEM
configuration's records for `eom` / `eom_config` / `manuf_lock`, the key-hash
record of each generation (32 bytes at +0x90 and 48 at +0xA0, so the script can
be read on an image whose generation it does not identify), the 48-byte values
the UEP holds copies of, and the Boot Guard profile — from
the CDMD configuration's JSON where the image has one, and from the UEP area's
Boot Guard bits where it does not, saying which of the two answered. Stdlib only,
read-only, no network: a run is a diff to review.

Note what it does *not* say: the values it prints for `eom` / `eom_config` are the
OEM configuration's defaults — the page a clean image carries too. What is in
force now is in the MFS file system, and that is what the app's engine decodes.

## Emitting a generation's configuration map

```bash
python3 Skills/me-eom-structures/scripts/mfit_map.py <mfit.exe> > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME16.swift
```

MFIT's settings database, unpacked and turned into the map the panel reads: the
files, the settings in each, their offsets, bits, MFIT's own option labels,
what its panel says about a setting (`help`, on the `<UI>` element — shown
behind the `?` beside a row) and
its `Auto`/`Generic` marks, and the tool's own name for a setting where its panel
shows something other than the identifier (`label` — "LAN Power Well" for
`MELanPowerWell`). It merges the platform lists and reports what
it could not merge rather than guessing — a setting two lists lay out differently is
dropped and named. Same rules as above: read the diff, don't paste blind.

The older FIT carries the same material in its own shape, per platform:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-15.0.exe> --straps tgp_lp > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME15.swift
```

There a setting's place is a `ProcessNvar` action — `filePath` into an alias
table, and a cell (`cellIndex × cellSize + cellOffset`) or a plain
`startOffset`/`varSize` — and its words come from the value class its
`type="class:…"` names, its declaration (`<CfgOpt …>`) giving the tool's own name
for it (`label`) and what its panel says about it (`help`) beside the
identifier. Both tools write the help as one attribute with their own breaks in
it — FIT `&#60;br /&#62;`, MFIT `&#13;&#10;` — and the generator resolves the
entities and turns a break into the line it stands for, so a map carries prose
and no markup. `--straps` picks the family whose layout
is wanted
(`tgp_lp` is ME 15's own), and `--generation`/`--tool` name the map in the file
it emits:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-14.0.exe> \
    --straps cml_lp --generation 14 --tool 14.0 > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME14.swift
```

**A generation has two maps, one for each half of it** — the mobile families
(`_lp`, `_p`) and the desktop ones (`_h`, `_s`) lay a few settings out
differently, so both are emitted, the mobile one under `csme<generation>` and
the desktop one under `csme<generation>Desktop` (`--variable`). Which one a
dump is read with is `MEConfigurationMap.forME(major:family:)`, and the family
is the descriptor's answer: its PCH strap section is 69, 70 or 74 words on the
mobile parts and 90, 101 or 115 on the desktop ones
(`MEPlatformFamily(strapWords:)`). Nothing in the ME region says it — the
manifest's platform name is the same for both halves.

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-15.0.exe> \
    --straps tgp_h --generation 15 --tool 15.0 --variable csme15Desktop > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME15Desktop.swift
```

ME 14's families are `cml_lp` and `cml_h`, ME 13's `icl_lp` and `icl_h`
(`icp_n_icl_h` is the same map with one setting fewer). MFIT needs neither:
its database merges the eight platform lists it builds from, and conflicts are
dropped and named. When a new family is added, run the generator twice and keep
both files — the panel and the engine ask through `forME`, so a half without a
map is a generation read with the other half's offsets.

The tool lays the Boot Guard bits out per family as well, which is a fact about
the *tool's documents* and not about where a vendor image keeps them: on both
generations at hand the four settings reach the image through the UEP area's
record, not through the array those layouts name (see the end of
`reference/structures.md`). One thing that generator cannot take from the chosen
platform: the End of Manufacturing record, which the newer layouts do not bind
at all (the tool writes it through `EomNvar`), so it is filled in from whichever
document binds `EOM_Config` and marked as such in the file's header.

## Emitting the descriptor's strap layout

The same executables carry the chipset's own layout of the descriptor's PCH
strap section — a `<LayoutEntry>` per field, with the tool's identifier, the
word and bits it takes and the value the tool builds it with — which is what
names the words in the UEFI Structure panel:

```bash
python3 Skills/me-eom-structures/scripts/strap_map.py \
    <fit-15.0.exe> <fit-14.0.exe> --words 69,70,74,90,101 > \
    Packages/UEFIImage/Sources/UEFIImage/StrapMap+PCH.swift
```

A table is asked for by the **length of the section it describes** — the words
the descriptor's own `FLMAP1` states — because the documents carry no reliable
platform name of their own (only some say `File Name: cnp_h_rvp.xml` in an XML
comment, and one of those names is on two different documents). The length is a
good key: 69 and 74 words are the same field for field in every tool that
carries them, FIT 15's three 70-word tables differ only in 50 defaults and two
spellings, and where a length has several differently-laid-out documents the
one that names itself wins — for 90 words that is `cnp_h_rvp.xml`, which FIT 13
carries as well, over a nameless document of the same length whose 417 fields
sit at other offsets. On stderr the script says which document each table came
from and where the two fields the engine reads by name — `SPI_ec_max_freq` and
`SPI_GLOBAL_PROTECTED_RNG_DEF` — sit in it, which is the check that the table is
the section's own: they move with the length, and the 69- and 74-word sections
carry no clock field at all. A length is added by naming it in `--words` and running the script
again; whatever the app does not carry stays a list of numbers in the panel.
`--kind cpu` emits the processor strap section's table instead.

## Checking against MFIT

MFIT prints the same facts in its build report:

```
Boot Guard Status: BG0 - Boot Guard Disable NO_FVME
EOM (End of Manufacturing) on First Boot Disabled
OEM Public Key Hash (SHA-384): 05c6…
```

A disagreement between the script's output and MFIT's report is the useful signal:
it means a field's location or meaning in `reference/structures.md` is still wrong.
Report it there rather than bending the script.

## Open questions

`reference/structures.md` ends with what is *not* known: what the other fields of
a UEP entry mean (the bits beside the four Boot Guard ones, the window in the
BIOS region, the `0x4FE`/`0xFE` word, the range the checksum covers), what the
CDMD configuration's other records are, and how CSME 14, 12, 11 and 18 keep the
profile — 18 has a CDMD block without the key, the older three have no block at
all, and a reading of their bits waits for a dump whose profile is known
independently, the way CSME 15's was settled.

And the file ends with the experiment that closed the last open question of the
reading: **MFIT writes the same four bits on CSME 16 that FIT 15 does**, so the
agreement between an image's CDMD record and its UEP bits is the tool's own
doing rather than a leftover from the input. Three MFIT builds of one image,
differing only in the profile, moved those bits with it — and left the rest of
the image byte-identical, which is why the engine's 15–16 gate stands.
