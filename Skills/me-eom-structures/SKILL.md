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
files, the settings in each, their offsets, bits, MFIT's own option labels and
its `Auto`/`Generic` marks. It merges the platform lists and reports what it
could not merge rather than guessing — a setting two lists lay out differently is
dropped and named. Same rules as above: read the diff, don't paste blind.

The older FIT carries the same material in its own shape, per platform:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-15.0.exe> --straps tgp_lp > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME15.swift
```

There a setting's place is a `ProcessNvar` action — `filePath` into an alias
table, and a cell (`cellIndex × cellSize + cellOffset`) or a plain
`startOffset`/`varSize` — and its words come from the value class its
`type="class:…"` names. `--straps` picks the family whose layout is wanted
(`tgp_lp` is ME 15's own), and `--generation`/`--tool` name the map in the file
it emits:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-14.0.exe> \
    --straps cml_lp --generation 14 --tool 14.0 > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationMap+CSME14.swift
```

ME 14's own family has to be picked per dump — `cml_lp` was, for the Lenovo
Comet Lake board, by the CPUIDs in its BIOS region (`0x806EA`/`0x806EB`/`0x806EC`
are Comet Lake U, `0xA0660` Comet Lake S) rather than by anything in the ME
region. The tool also lays the Boot Guard bits out **per family**, which is why
a CSME 14 image's profile is not read yet: see the end of
`reference/structures.md`. One thing that generator cannot take from the chosen
platform: the End of Manufacturing record, which the newer layouts do not bind
at all (the tool writes it through `EomNvar`), so it is filled in from whichever
document binds `EOM_Config` and marked as such in the file's header.

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
