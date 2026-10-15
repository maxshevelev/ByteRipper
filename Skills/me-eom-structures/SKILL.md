---
name: me-eom-structures
description: Read the End-of-Manufacturing, Boot Guard and OEM-key facts out of an ME dump — the MFS/configuration records behind them, the UEP area, and how they compare with MFIT's own report. Use when working on the ME Analyzer's manufacturing/Boot Guard rows, when a dump's EOM or Boot Guard state has to be established, or when MFIT's build report has to be checked against the bytes.
---

# ME EOM / Boot Guard / OEM key structures

This is the research home for three facts a repair bench needs from an ME dump,
and for the flash structures that carry them. Everything here was established on
real dumps and cross-checked against MFIT's own configuration and build report
(see `reference/structures.md` for the addresses, values and sources).

## The three facts and where they live

| fact | MFIT setting | flash |
|---|---|---|
| will the platform close Manufacturing at first boot | `CsePlugin:EomNvar:EOM#EomFirstBootEnabled` | MFS `/home/mca/eom` (1 byte), default in the OEM configuration |
| what EOM commits | `CsePlugin:EomNvar:EOM_Config#FlexibleEomSettings` | MFS `/home/mca/eom_config` (2 bytes) |
| Boot Guard level | `CsePlugin:UEP:BtGuardProfileConfig` (`0 - No_FVME`, `3 - VM`, `4 - FVE`, `5 - FVME`) | the JSON record in the **CDMD** partition's configuration — the number is an index into that list, not the level itself |
| OEM public key hash | `CsePlugin:UEP:OemPublicKeyHash` (SHA-384, 48 bytes; all zeros = signing disabled) | the UEP, mirrored in the MFS key table |

The BIOS side carries its own, different key hash — the Boot Guard Key Manifest the
FIT table points at — and that one is *not* the OEM public key hash MFIT reports.

## Reading a dump

```bash
python3 Skills/me-eom-structures/scripts/me_eom.py <dump> [<dump>…]
```

It prints, per dump: whether the descriptor's BIOS master is open or locked, the
UEP container's address and how much of the area is erased, the OEM
configuration's records for `eom` / `eom_config` / `manuf_lock`, the 48-byte
values the UEP holds copies of (key hashes), and the Boot Guard profile from the
CDMD configuration's JSON. Stdlib only, read-only, no network: a run is a diff to
review.

Note what it does *not* say: the values it prints for `eom` / `eom_config` are the
OEM configuration's defaults — the page a clean image carries too. What is in
force now is in the MFS file system, and that is what the app's engine decodes.

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

`reference/structures.md` ends with what is *not* known: what the fields of a UEP
entry mean (the window in the BIOS region, the `0x4FE`/`0xFE` word, the 32-bit
sum), what the CDMD configuration's other records are, and where a CSME 15
image keeps the Boot Guard profile — its CDMD carries no such record at all, so
the panel answers "no profile record in this image" for those boards while
ECFinder calls them profile 0.
