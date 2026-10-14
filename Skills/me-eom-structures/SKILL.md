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
| Boot Guard level | `CsePlugin:UEP:BtGuardProfileConfig` (`0 - No_FVME`, `3 - VM`, `4 - FVE`, `5 - FVME`) | the ME region's **UEP** area |
| OEM public key hash | `CsePlugin:UEP:OemPublicKeyHash` (SHA-384, 48 bytes; all zeros = signing disabled) | the UEP, mirrored in the MFS file `/home/mca/3LVLSCD.dat` |

The BIOS side carries its own, different key hash — the Boot Guard Key Manifest the
FIT table points at — and that one is *not* the OEM public key hash MFIT reports.

## Reading a dump

```bash
python3 Skills/me-eom-structures/scripts/me_eom.py <dump> [<dump>…]
```

It prints, per dump: whether the descriptor's BIOS master is open or locked, the
UEP container's address and how much of the area is erased, the OEM
configuration's records for `eom` / `eom_config` / `manuf_lock`, and the 48-byte
values that repeat across the ME region (key hashes). Stdlib only, read-only, no
network: a run is a diff to review.

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

`reference/structures.md` ends with what is *not* known — above all which UEP
byte carries the Boot Guard profile, which needs two images built in MFIT that
differ only in that setting.
