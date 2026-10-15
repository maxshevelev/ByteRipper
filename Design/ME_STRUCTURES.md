# ME structures — what the ME Analyzer reads, and what it does not yet

The Intel ME / CSME firmware in a dump carries three facts a repair bench asks
before an image is written to a board: whether the platform closes Manufacturing
on its first boot, which Boot Guard profile the image is built for, and which
OEM public key hash it carries. None of them is in the format documentation that
the upstream project (`MEA.py`) follows, none of them is read by that project at
all, and three of the structures that hold them are described nowhere.

This doc is what is known about those structures, which generation each is read
for, and what has to be worked out for the generations where it is not — the
last is the reason the doc exists: **Boot Guard and the key hash are read on
CSME 16 and not on the older generations**, and the way to reach them there is
the same experiment that reached them here.

The address-level record — every offset, every value, the dump each was seen in,
and the corrections along the way — is the research log:
`Skills/me-eom-structures/reference/structures.md`, with its oracle
`Skills/me-eom-structures/scripts/me_eom.py`. Where the two disagree, the log is
right and this doc is stale.

## Where each fact lives

**The flash descriptor** — the first 4 KiB of a whole-flash image (signature
`5A A5 F0 0F` at 0x10, FLMAP0 at 0x14, FLMAP1 at 0x18). The **master section**
starts at FLMAP1's low byte, in 0x10 units, one dword per master; from Skylake
(Sunrise Point) on, each is `read = word >> 8 & 0xFFF` and
`write = word >> 20 & 0xFFF`, one bit per region. The host CPU / BIOS master —
MFIT calls it *Host CPU / BIOS*, the bench calls it the descriptor's rights —
carries `0x00F` / `0x00A` in a serial image and `0xFFF` / `0xFFF` in a service
image that lets the host rewrite the whole flash.

That pair is the first of the two mechanisms that decide End of Manufacturing:
**a serial image closes Manufacturing on its first boot by its access rights
alone**, which is how it was done before MFIT grew a setting for it, and how
serial images with no setting are still done. MFIT's own rule names the same
field from the other side (`CsePlugin:EomNvar`): *"When 'Host CPU / BIOS' Read
and Write Master Access are set to 0xFFFF, End of manufacturing on first boot
and locking descriptor is not allowed"* — the flag and the descriptor lock are
one operation, which is also why a flag set beside open rights is an image MFIT
would not have built.

Only the v2 word form is read. A v1 descriptor (Ich8 … Lynx Point) keeps a byte
per mask, and reading it as v2 would invent an answer; the row is therefore
shown for CSME 11 and later and says `noSwitch` for anything older.

**The OEM Configuration partition** — an FPT region named `FITC` (0x295000 in
the Z Flow dump). A revision-1 header of 0x10 bytes, then the payload: a u32
record count and 12-byte records `{u32 FileID, u32 offset, u16 size, u16 flags}`.
The records are the **image's own page** of the OEM configuration: what the build
wrote, which the platform applies when it enters End of Manufacturing. Two of
its File IDs are the switch: `/home/mca/eom_config` (bit 0 = `EOM on first boot`,
bits 1–2 = `FlexibleEomSettings`) and `/home/mca/eom`.

**The MFS file system** — a data region (`MFS`, 0x21C000 in the Z Flow dump)
holding files the volume names either by index (before CSME 15) or, on CSME
15/16, by **File ID** through the `FTBL` table of the firmware database
(`FileTable.dat`). The File IDs the switch is about are stable:
`/home/mca/eom` = `0x10020000` (1 byte), `/home/mca/eom_config` = `0x1001EE00`
(2 bytes), `/home/mca/manuf_lock` = `0x10020100` (1 byte), and the key table
`/home/mca/3LVLSCD.dat` (0x900 bytes). These files are the **live page** — what
the file system of *that board* holds now — so MFIT's own database gives two of the File IDs a setting each — and it names the
same setting twice, which is where a common misreading starts:
`/home/mca/eom_config` carries `EomFirstBootEnabled` in **bit 0** and
`FlexibleEomSettings` in **bits 1–2** (its `config_params` are 0-based:
`Lock Descriptor and OEM Configs` = 0 … `Do not lock` = 3), and `/home/mca/eom`
carries `EomFirstBootEnabled` again as a **raw byte**. The panel prints both:
the flag decides the Manufacturing row, and the flexible setting has a row of its
own beside it, in those four values — it is stored whether or not the flag is
set, so it says what an image would lock if it ever ran. Two further bytes on that
row of the file system are **not** in any MFIT database: `/home/mca/manuf_lock`,
and `/home/mca/eom`'s live value, which is 1 on every dump taken from a machine
whose engine has run while the image's own record of the same byte reads 0. What
the platform meant by writing them is not documented anywhere at hand, so the
row reports neither — and neither is evidence of anything on its own.

**The UEP area** — an FPT region named `UEP` (0x2A0000 in the Z Flow dump,
8 KiB), opened by the ASCII container `$UEPC`. It holds an entry that carries a
window into the BIOS region (an address and a size), a 32-bit sum, a Key
Manifest ID, and the **OEM public key hash** — a SHA-384, 48 bytes — which sits
**0xA0 bytes into the entry**, and again 0x10A0 in where the area's second half
is written. The area's own layout is not documented anywhere that could be
found; that one offset was measured off the container and then checked against
every dump at hand, across CSME 12 to 18, where it holds the same value the
repeated-window search this replaced used to find (and reads two images that
search could not).

The field is what the row reads, and what it holds is the finding:
**all zeros** is MFIT's own "OEM signing is disabled", **all `FF`** an area never
written, and **anything else** a layout this reader does not walk — CSME 14's
entry holds a pointer-like value there, CSME 11 has no area at all. The row says
which, because they are three states of a boot chain, not one silence. The rest
of the entry — the window, the sum, the `0x4FE` word — is still unknown.

**The CDMD partition** — an FPT region named `CDMD` (0x29D000 in the Z Flow
dump, 0x3000) whose configuration opens with `FIT AS A FIDDLE` and carries small
JSON records, among them **`{"BtGuardProfileConfig": n}`** — the Boot Guard
profile, written as an **index into MFIT's own list**: 0 → `0 - No_FVME`,
1 → `3 - VM`, 2 → `4 - FVE`, 3 → `5 - FVME`. Other records of the same block are
the strap and harness the image was built from, `{"FpfSvnEnabled": 1}`,
`{"sku": …}` and `{"ResizeNftpForFtpr": "Enabled"}`.

A profile is what the platform burns into the chipset's fuses when Manufacturing
closes, and the fuses cannot be taken back — which is why the profile is worth
reading before an image is written, and why a wrong answer is worse than none.

## Which generation carries what

What the panel reads today, per generation, as a run over the dumps at hand
printed it (2026-10-15). "not found" means the bytes were not there to read —
not that the fact is absent from the platform.

| generation (dumps at hand) | descriptor rights | EOM flag | Boot Guard profile | OEM key hash |
|---|---|---|---|---|
| CSME 18 (EliteBook 630 G11) | v2 ✓ — the row's gate | **not found**: the FITC partition is there, the `eom_config` record is not | **not found** — CDMD present, no `BtGuardProfileConfig` | ✓ read — `0D7C0D45…`, the same key as its sibling at CSME 16.1.30 |
| CSME 16.1 (Z Flow, Legion, Asus, Dell) | v2 ✓ | ✓ FITC record and the live one | ✓ CDMD JSON — 5 and 0 seen | ✓ UEP, 6 + 6 copies — **verified** for the Z Flow family |
| CSME 16.0 (Legion) | v2 ✓ | ✓ | ✓ (5, 0) | ✓ |
| CSME 15 (Lenovo 1.bin, 2.rom, corporate) | v2 ✓ | ✓ records present; the live page is absent on a never-booted build | **not found** — no CDMD record in any of them | ✓ UEP — **unverified** |
| CSME 14 (Lenovo) | v2 ✓ | **no such setting**: the configuration records are the named (0x1C) layout and hold no `eom_config` | **not found** — no CDMD partition at all in that image | **layout not recognized** — the field holds a pointer-like value, not a key |
| CSME 12 (Dell, Lenovo, HP) | v2 ✓ | no such setting | **not found** | **all zeros** — the field is there and reads zeros: signing disabled |
| CSME 11 (corporate) | v2 ✓ | no such setting | **not found** — no CDMD and no `$UEP` container at all | **layout not recognized** — no area to read the field from |
| ME 6, 7, 10 (Apple) | v1 — not read | — | — | — |

Two things this table is not. It is not a claim about the generation — one dump
of a generation is one dump — and the key hash column is not a claim about the
*value* unless it says verified: the Z Flow family's hash is the one a field
tool's report confirms byte for byte, and every other value is read off the
entry's field but unconfirmed by a tool.

**A first boot, measured.** The owner flashed an image with the flag clear and the
descriptor's rights open (`image.bin`), booted the board, and dumped it again
(`image.after.bin`, a Legion 5 Pro 16IAH7H / CSME 16.0.15.1662). The descriptor
region is byte-identical between the two — nothing was locked, which is what the
row had said would happen — and the only bytes the platform wrote are the MFS
volume and its neighbours (180,566 bytes over 59 runs), with the FITC, CDMD and
UEP untouched. The file system moved from **Configured** to **Initialized**, so
the engine had certainly run, and both bytes of the board's own record —
`/home/mca/eom` and `/home/mca/manuf_lock` — are **0** after it. That is the
control the earlier reading lacked: those two read 1 on a board whose
Manufacturing was closed, not on a board that has merely run.

The other half of that pair — the same board flashed with the flag enabled — is
**not** to be produced on a working machine: closing Manufacturing burns the
key hashes into the chipset's fuses and cannot be undone, which is exactly why
the Manufacturing row exists. The closed side of the comparison is available
from the factory dumps instead (Z Flow, Legion, the Lenovo service images), and
it is the side that matters for reading an image.

**The cross-check to make.** The owner has MFIT's build report and ECFinder's
capture for other generations; those name the profile and print the OEM public
key hash as text. Matching them against this reader is the test: the key the
reader prints has to be the key the tool prints, byte for byte, on the same
dump — and where the tool prints one and the reader says "not set" or "layout
not recognized", the reader's offsets are wrong for that generation and the
entry has to be read properly. Bring the two together, dump by dump
(`Skills/me-eom-structures` holds the oracle that prints the same facts).

**A key is per vendor, and the shapes are what tell them apart.** Two vendors'
images cannot carry the same hash, so a value that turns up under two of them is
a wrong reading by definition. One did: the CSME 18 row above reports no key now
because its candidate sits **once per half** of the UEP area, where every
established layout has **three**, and the rule reads a value only where it has
that shape (`BootGuardReader.oemPublicKeyHash`). Its 48 bytes turned up on a
CSME 16.1.30 image as well — which the dump's own strings show to be an image of
the *same* vendor, whatever its folder is called, so that pair proved nothing
about vendors and everything about shapes.

What that leaves open is the other reading of those bytes: the image carrying
them six times in the UEP has exactly the established shape, so the rule reports
it, and no field tool has confirmed it. It is the first value to take to
ECFinder or MFIT's report, and until then the table says unverified rather than
verified.

What the panel says where a fact is absent, and the wording is deliberate:
**No profile record in this image** and **No key material in this image**. A
number would have to be a guess at what a vendor configured on some other
machine, and the two absences are not the same case: CSME 15's boards are Boot
Guard 0 by the field tools' verdict, which the dump does not state, while a
region whose UEP was wiped carries no key at all.

## What to work out next

**Where CSME 15 keeps the Boot Guard profile.** MFIT offers the setting for
CSME 15 projects too (`CsePlugin:UEP:BtGuardProfileConfig`, with the FPF field
map below), so it is written somewhere. The experiment that settled CSME 16 is
the one to repeat: two MFIT projects over the same dump differing in nothing but
`Boot Guard Profile`, built to files, then diffed — the bytes that move are the
answer. CSME 16's were a JSON digit in CDMD and the CRC of that block.

> A caution from the first attempt at this, which cost two days: the two builds
> that were diffed turned out to be **the same file** (equal sizes, equal
> SHA-256), so the "no difference" they showed proved nothing and the conclusion
> drawn from it — that the profile is not in the image — was wrong. Compare the
> two artifacts before trusting a null diff, and change one setting at a time.

**Whether an older generation carries the profile in another place.** The
survey above is the first half of the answer, and it splits the generations in
two: CSME 15, 14, 12 and 11 carry **no CDMD configuration at all** (no `FIT AS A
FIDDLE` block anywhere in the region), while CSME 18 carries the block and no
`BtGuardProfileConfig` key in it. The first group needs the MFIT experiment
above — the setting exists in MFIT for those projects, so it is written
somewhere, most likely into the UEP entries whose layout is unknown. The second
group needs the key's other spelling, which MFIT's settings database is the
place to find.

**Where CSME 15 and 18 keep the EOM flag.** The flag was found in the FITC
partition on CSME 15 and 16 and *not* on CSME 18, whose MFS volume also could
not be read by the engine. Either CSME 18 names the record differently, or its
FITC holds it under another File ID, or the setting is not CSME 15's any more.
The same MFIT experiment answers it: build two images differing only in `EOM on
first boot` and diff.

**The rest of the UEP entry.** One field of it is measured — the key hash at
+0xA0 — and the window, the 32-bit sum and the `0x4FE` word beside it are not.
CSME 14's entry holds something else where CSME 12 to 18 hold the key, which is
either a different layout at that generation or a field this reader mistakes for
the key's; its own MFIT report and ECFinder capture would say which, since
ECFinder prints an OEM key hash for the images it understands.
`mfit.exe` carries its settings database as
zlib-embedded XML that gives a *field map*: for each setting, the structure and
the bit offset it is written at. For the FPF/UEP word it is
`OEM_ID` 0–15, `KM_ID` 23–26, `FW_TYPE` 27–29, **`BTG_PROFILE` 30–32**, with
`OEM_KH_0` at 0x98 and `OEM_KH_1` at 0xC8 (384 bits each), and boolean bits at
0x4C (`OEM_KH_0_V`, `KM_ID_V`, `BTG_PROFILE_V`, …). That map describes where the
*platform* is told to burn the values; the UEP area is where the image keeps them
until it does. Reading the UEP entries by that map — rather than by the shape
heuristic in use — is the step that would also read a region whose key hash does
not repeat, and would say what the window, the sum and the `0x4FE` word mean.

**The key hash on generations whose UEP differs.** CSME 12.BIN carries no
repeated 48-byte value in its ME region at all. Whether that is a different UEP
layout, a key stored once rather than mirrored, or an image whose key really is
absent is not known.

**ECFinder as an external cross-check.** The field tools print a Boot Guard
verdict and the key hash in a text report, and the owner's captures of them are
what confirmed CSME 16's reading. Its verdict is two-valued — `BG0` or `BG5` —
and it tracks the vendor manifests and the engine's state rather than the
profile number, so it can confirm that a profile is *configured* and not which
one; its EOM line was seen to read "Enabled" on an image whose own MFIT report
says Disabled, so it is not usable as ground truth for that row.

## The method that works on this material

1. **Find the bytes.** Change one setting in a build, or take two dumps that
   differ in one fact, and diff them. A fact nobody can point at in a hex view
   is not a fact yet.
2. **Read them back.** The candidate offset has to reproduce on dumps whose
   answer is known independently — the owner's ground truth, MFIT's own build
   report, a field tool's capture — and it has to fail on a dump where the fact
   is different. A rule that fits one dump is a coincidence.
3. **Say what is not known.** Three structures above are read by shape because
   nothing documents them. The row's wording keeps that honest ("no profile
   record in this image" rather than a number), and the research log carries an
   explicit list of what is still guesswork.
4. **Keep the panel and the oracle in step.** The oracle prints the same facts
   from the same bytes for a run over a folder; a disagreement is the signal
   that the doc, the code or the oracle has drifted.

## Where the code is

| what | where |
|---|---|
| the EOM verdict and the FTBL File IDs | `Packages/MEFirmware/Sources/MEFirmware/FileSystem/Manufacturing.swift` |
| the profile out of the CDMD JSON, the hash out of the UEP | `Packages/MEFirmware/Sources/MEFirmware/Layout/BootGuard.swift` |
| the descriptor's BIOS master | `Packages/MEFirmware/Sources/MEFirmware/Layout/IFWI.swift` (`FlashDescriptor.biosMaster`) |
| where the facts are assembled | `Packages/MEFirmware/Sources/MEFirmware/Engine/MEFirmwareAnalyzer.swift` (the "three facts" block), `analyze(descriptorBytes:)` |
| the descriptor page handed to the engine | `Packages/MEReads/Sources/MEReads/MEReads.swift` |
| the rows, their wording and their colours | `Modules/MEATool/Sources/MEATool/MEASummary.swift`, `Packages/MEPresentation/Sources/MEPresentation/MEABenchFactsText.swift`, `MEATones.swift` |
| the help page the rows are explained on | `Packages/HelpBook/Sources/HelpBook/Resources/Help/<language>/Topics/recipe-me-check.md` |
| the research log and its oracle | `Skills/me-eom-structures/` |
