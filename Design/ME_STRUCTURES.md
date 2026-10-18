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
the flag decides the EOM on First Boot row, and the flexible setting has a row of its
own beside it, in those four values — it is stored whether or not the flag is
set, so it says what an image would lock if it ever ran.

Two further bytes on that row of the file system are **not** in any MFIT
database: `/home/mca/manuf_lock`, and `/home/mca/eom`'s live value. They record
the *board*, not the image, and the controlled first boot settled what they say
(below): a board flashed an image with the flag clear — nothing for End of
Manufacturing to lock — has both at **0** after that boot, while every factory
dump at hand has both at **1**. So `manuf_lock` is the one statement a dump
makes about whether the machine has been through End of Manufacturing, and with
it committed the fuses; the engine reports it as the row **Manufacturing Lock**
(`Locked` / `Not locked`, and a dash where the record is not in the image), and
`/home/mca/eom` duplicates the flag and is not reported separately. The image's own question — what its next first boot will
do — stays the EOM on First Boot row.

**Where a volume starts, and how CSME 18 writes its first page.** An FPT
entry's offset is measured from the FPT partition's base, and on a whole image
from CSME 12 to 18 the `$FPT` sits on a 4 KiB boundary and is that base itself.
The CSME 18 dump's MFS, EFS, FITC, CDMD and UEP all begin 0x10 after the
`$FPT − 0x10` reading would put them, and every aligned-anchor dump at hand
reads its partitions only from the marker; the older layout — the region base
holds a CSE Layout Table and the `$FPT` sits at +0x10 — is not aligned and
keeps the `− 0x10` base. The CSME 18 volume also writes its **first System page
with the page signature erased**: the page number, `FirstChunkIndex` and the
chunk index array are all valid, and its chunk 0 is the volume header. So the
parser takes an untagged page when the tagged pages do not yield the volume
header (18.0.10.2288: MFS @0x3D9000, pages 1–15 System, the first Data page's
`FirstChunkIndex` 717, 2048 file records, declared volume size 0x1512C0 — all
of it checked against the parsed volume). The EFS region of that dump begins
0x10 after its entry too, and its dictionary then matches the MFS volume's.

**The UEP area** — an FPT region named `UEP` (0x2A0000 in the Z Flow dump,
8 KiB), opened by the ASCII container `$UEPC` on 15 and 16 and by the bare
`$UEP` on 18 (both spellings are found by `BootGuardReader.containerOffset`).
It holds an entry that carries a window into the BIOS region (an address and a
size), a 32-bit sum, a Key Manifest ID, and the **OEM public key hash**. The
area's own layout is not documented anywhere that could be found, and the hash
sits in **two different records, one per generation**:

| generation | record | where |
|---|---|---|
| CSME 15 and later | SHA-384, 48 bytes | 0xA0 bytes into the entry, and again 0x10A0 in where the area's second half is written |
| CSME 12 to 14 | SHA-256, **32 bytes**, with 16 bytes of assignment bits behind it | 0x90 bytes into the entry, once — the second half of those areas is erased on every image at hand |

**Which record is read follows the image's generation, and not a guess**, because
the two fields are one byte apart in kind: a 48-byte read of a CSME 14 image
starts on the second half of its hash and runs into the bitmap behind it, and a
32-byte read of a CSME 15 image starts on the zeroes ahead of its key. Both
wrong reads *look* like key material at one end and padding at the other, which
is exactly how the earlier reader printed "layout not recognized" for every
CSME 14 image — the field it read was half a key and half a bitmap. The 32-byte
record was measured off the container on five CSME 14 boards (Acer, Razer,
Lenovo, HP, Dell) and a sixth image of the same Acer board whose key reads
identically; the 48-byte one on every CSME 15 and 16 dump.

The field is what the row reads, and what it holds is the finding:
**all zeros** is MFIT's own "OEM signing is disabled", **all `FF`** an area never
written, and **anything else** a layout this reader does not walk (CSME 11 has
no area at all). The row says which, because they are three states of a boot
chain, not one silence. The rest of the entry — the window, the sum, the
`0x4FE` word — is still unknown.

**The CDMD partition** — an FPT region named `CDMD` (0x29D000 in the Z Flow
dump, 0x3000) whose configuration opens with `FIT AS A FIDDLE` and carries small
JSON records, among them **`{"BtGuardProfileConfig": n}`** — the Boot Guard
profile, written as an **index into MFIT's own list**: 0 → `0 - No_FVME`,
1 → `3 - VM`, 2 → `4 - FVE`, 3 → `5 - FVME`. Other records of the same block are
the strap and harness the image was built from, `{"FpfSvnEnabled": 1}`,
`{"sku": …}` and `{"ResizeNftpForFtpr": "Enabled"}`.

**The profile has a second keeping, and it is the older one.** An image with no
CDMD record — every CSME 15 image — carries not the profile's *index* but **the
four settings the profile is made of**, as bits of the UEP area's first
`UepBitsArray`: FBG ACM bit 0, `ProtectBiosEnvironment` 3, `MeasuredBoot` 4,
`VerifiedBoot` 5 of the byte at `$UEP`+0x6E, and Intel's own `BootGuardProfiles`
class is the table from that combination to the four profiles (0 = all four
false, 3 = verified+measured+protect, 4 = ACM+verified+protect, 5 = all four
true). FIT's layout documents write both ends of that down — the class that
places the settings in the array (`GetBitArrayValue … offset="0x60"
startBit="16"`) and the table that names the profiles — which is why this is a
reader and not a guess. Both keepings are read and they agree on every image
that carries both (a CSME 16.1 dump: CDMD 5, bits 0x79 → FVME). What is *not*
read is the same byte's two debug bits, whose values disagree with FIT's own
report on the images at hand; and the reading is applied to CSME 15 and 16 only
by *this* layout, the generations whose array was verified to carry it.

**The profile on CSME 12 to 14 sits in the same area in a different container**,
and the shape had to be found before it could be read:

| at `$UEP` | |
|---|---|
| +0x04 | the container's checksum (a u16, the two bytes above it zero) |
| +0x28 … +0x37 | its policy words |
| +0x34 | the mask: `0xCC` where the ACM is not forced, `0xFF` where it is |
| +0x48, +0xE4, +0x174 | the record's source pointer, one per copy |
| +0x4C, +0xE8, +0x178 | the flags byte of each copy — the four settings in the same bits as 15's |
| +0x90 | the OEM public key hash (the 32-byte record above) |

Four FIT 14.0.20 builds of one CSME 14 image — profiles 0, 3, 4 and 5, whose
`.xml` readings differ in `BtGuardProfileConfig` and nothing else — differ in
**five bytes of sixteen million**: the checksum, the mask, and the flags byte of
each of the record's three copies (which are always equal). The build's own bits
are `0x46` — `0x42` on a CSME 15 image, which is the same four settings in
another container — and the three profiles turn on `0x38`, `0x29` and `0x39` of
them: the same three constants the 15/16 array uses, so Intel's table from
combination to profile holds on this generation too. The mask corroborates it on
eleven images and builds — `0xFF` exactly where the ACM bit is set, `0xCC` where
it is not — and is what tells this container from the later one (zeroes there, so
a 15 image read as a 12–14 one answers nothing) and an area never written from a
written one (its all-ones flags would otherwise read as profile 5).

What the **bit-array layouts FIT 14's own database describes do not hold these
settings**: it carries seven of them, one per platform family, and on the images
at hand the arrays they point at are empty — which is also why the first answer
here was that the profile is not in the image at all. The arrays are still the
right description of where FIT *15* keeps its bits, and of the fields the tool
places around them.

Two more of the eleven are CSME 12 images that carry a key (`69602F34…`, the same
hash on both, and both Corporate H); they read FVME. The four whose key field is
all zeros read No_FVME, which is MFIT's "OEM signing is disabled" — the setting
FIT refuses to move off 0 while signing is off.

**What corroborates the CSME 12 readings** is not only the mask: the BIOS region
of the two images that read 5 — the same two that carry a key — holds the
vendor's **`__KEYM__` and `__BPM__` manifests** once each, and the four that read
0 hold neither, so the flags agree with an independent sign of a configured boot
chain on all six. They are still readings no field tool has confirmed — ECFinder
runs on Windows — and CSME 13's is read by its own record (below). What the four builds
show about the BIOS side is worth keeping
too: their BIOS regions are **byte-identical**, so the profile reaches the ME
region's own record and nothing else in an image built this way.

**CSME 13 turned out to be a third container, and the tool's own build settled
it.** The two `Lenovo NM-C711` dumps (13.0.21.1319 and 13.0.32.1478, both Ice
Lake-U, in the schematic collection on Google Drive) keep the four settings in
the container's record as CSME 12 and 14 do, at their own offsets: the policy
words `FF FF CF 0C` / `FF C0 0C 00` at +0x34, the ACM mask at **+0x40** (its low
byte 0xCC or 0xFF, with 0xC0 above it — where the 12–14 container keeps the same
byte with zeroes above), the record's source pointer at **+0x60**, and its flags
byte at **+0x64**, in three copies 0xDC apart (+0x150, +0x22C) where 12–14 has
three 0x9C apart.

Four FIT 13.0 builds of one of those dumps — profiles 0, 3, 4 and 5, the `.xml`
readings differing in `BtGuardProfileConfig` and nothing else — differ in **six
bytes of sixteen million**: the container's checksum, the mask, and the flags
byte of each copy, which read 0x40, 0x78, 0x69 and 0x79. XOR against the image's
own 0x40 is 0x38, 0x29 and 0x39 — the same three constants every other
generation turns on — so Intel's table names the profile here too, and both
factory dumps (0x40, i.e. profile 0) agree with the absence of any `__KEYM__` or
`__BPM__` in their BIOS regions.

The tool's own UEP document says the same about the *bits*: `fit-13.0.exe` places
`$BootGuardProfileSettings/FBGAcmEn`, `ProtectBiosEnvironment`, `MeasuredBoot` and
`VerifiedBoot` at bits 16 to 21 of the first bit array. What it does not say, and
what the builds do, is where they land: no byte of any array moved on the four
builds, and the byte that did is the record's. The key record is confirmed for
the generation as well: the same 32-byte hash sits at +0x90 on both dumps, where
the 12–14 rule looks for it.

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
| CSME 16.1 (Z Flow, Legion, Asus, Dell) | v2 ✓ | ✓ FITC record and the live one | ✓ CDMD JSON — 5 and 0 seen, and the **UEP bits agree on every dump that carries both** (three MFIT builds of one image, differing only in the profile, moved the bits with it) | ✓ UEP, 6 + 6 copies — **verified** for the Z Flow family |
| CSME 16.0 (Legion) | v2 ✓ | ✓ | ✓ (5, 0) | ✓ |
| CSME 15 (Lenovo 1.bin, 2.rom, corporate) | v2 ✓ | ✓ records present; the live page is absent on a never-booted build | ✓ **UEP bits** — 0 on the three boards, and 3/4/5 on the owner's three builds, each matching the `.xml` FIT itself wrote for that build | ✓ UEP — **unverified** |
| CSME 14 (Lenovo Comet Lake, and five more boards) | v2 ✓ | **no such setting**, and FIT 14's own map binds none either (see "ME 14" above) | ✓ **the UEP record's flags byte** at +0x4C — 0 on the factory dump, and 0, 3, 4 and 5 on the owner's four FIT 14.0 builds of it, each matching the `.xml` FIT wrote for that build | ✓ **the 32-byte SHA-256 at `$UEP`+0x90**, read by generation — the same Acer board's second image carries the same hash |
| CSME 12 (Dell, Lenovo, HP) | v2 ✓ | no such setting | ✓ **the same record** — 5 on the two images whose key field holds a hash, 0 on the four whose field is zeros, the container's mask agreeing with the flags' ACM bit on all six | **all zeros** on four of the six: signing disabled. The Dell Optiplex dump and `W25Q256JV.orig.bin` carry `69602F34…`, the same hash on both |
| CSME 13 (Lenovo NM-C711, Ice Lake-U) | v2 ✓ | no such setting | ✓ **the UEP record's flags byte** at +0x64, with its own mask at +0x40 and three copies 0xDC apart — 0 on both factory dumps, and 0, 3, 4 and 5 on the owner's four FIT 13.0 builds, each matching the `.xml` FIT wrote for that build | ✓ the 32-byte SHA-256 at `$UEP`+0x90 — where the generation rule looks for it, and the same hash on both dumps |
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
the EOM on First Boot row exists. The closed side of the comparison is available
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

## MFIT's settings database: what lives where, and with what values

`mfit.exe` carries its settings database as zlib-compressed XML inside the
binary. Unpacked, it answers the question the panel keeps asking — *which*
parameters live in *which* files, and what they may say:

| what the database gives, per setting | example (`mca/eom_config`) |
|---|---|
| the file it lives in, and the file's alias | `mca/eom_config`, alias `EOM_Config` |
| where in that file: byte offset and length | offset 0, length 2 |
| for a bitfield, the bits | `EomFirstBootEnabled` bits 0–0, `FlexibleEomSettings` bits 1–2 |
| the kind of the field | `Data` (a value), `Bitwise` (bits in a word), `Binary`, `String` |
| the values it may take, with their numbers | the four EOM options, numbered from zero |
| the default, and MFIT's own help text | `Lock Descriptor and OEM Configs` |
| who fills it in | `process_type`: `Generic` or `Auto` (see below) |

**`Generic` and `Auto` are the whole of it, and they are not a suggestion.**
Every one of the 134 settings the 16.0.15 build lists carries the attribute, and
its value is one of those two words — MFIT's own enum is
`NvarProcessType { Auto, Generic }`, beside `NvarPhysicalType { Data, Binary,
String, Bitwise }` in the tool's own code. What they mean is in that code too:
the reading path is written `if nvar.nvar_process_type == NvarProcessType.Generic
and nvar_bucket.file_name == …: read_nvar_bucket(…)` — a **Generic** setting is
read out of the file it is listed under, which is what a build is given. An
**Auto** setting is handled elsewhere: it is written into the image's own
`AutoNvars` container, a class whose own words are *"Container reads / writes
auto NVARs to CSC fitc partition"*, and whose settings are referred to as
`CsePlugin:AutoNvars:<File>#<Setting>` rather than as a file. So `Auto` is not
"the platform writes it after boot" — it is "**the tool works it out and writes
it, not the builder**", and 67 of the 137 settings have no place in a file at
all (`length="0"`): they are computed, not stored — except where the file holds
nothing but that one setting, which the map reads (below).

The 16.0.15 build's database holds **74 files and 137 settings** across its
eight platform lists (four ADL-S of 63–72 files, three MTL, one ELG); of those,
**67 settings in 26 files have a place in the bytes** and the rest do not. The
useful part is that **those file paths are MFS paths**: `/home/mca/eom_config`, `/home/policy/cfgmgr/cfg_rules`,
`/home/iunit/iunit_oem_cfg`, `/home/pavp/hdcp_ports`, `/home/ish_srv/INTC_pdt` …
So every setting in the database is a setting the app can read out of a dump the
same way it reads the EOM one — the MFS file by its File ID through
`FileTable.dat`, and the image's own record in the FITC partition — and a setting
whose values are enumerated (`FlexibleEomSettings`, `ProcEmulation`,
`MewlanPowerWell`, `Hdcp5kedisp1`, … twelve of them) can be printed by name
rather than as a number.

**Both copies are read, and shown side by side.** A dump carries each of these
files twice: the record the build wrote into the OEM Configuration (FITC)
partition, and the file the platform copied into the ME file system on its first
boot. Which of the two is *the* configuration is not a question with one answer
— a setting the platform rewrote and a setting the build chose are different
facts about one machine — so the panel gives each a column and marks the pairs
that disagree, in bold and in no colour of its own: a rewritten setting is not a
fault, and the palette's colours are verdicts. An image that has never been
through a first boot has only the build's copy (verified: on `image.bin` and
`image1.bin` every file reads from the image and the file system's column is
empty, and the panel then draws that column as its heading and nothing else; on
`image.after.bin` and `image1.after.bin` both copies are there — 17 of the
mapped files on a Lenovo Legion board — and they agree on every setting).

**The map the panel reads is emitted from that database, not typed out.**
`Skills/me-eom-structures/scripts/mfit_map.py <mfit.exe>` prints
`MEConfigurationMap+CSME16.swift`: every file with a readable setting, its
offset, length, bits, MFIT's option labels and its `Auto` marks, straight from
the XML. It merges the platform lists into one — the four ADL-S lists agree on
every offset of every setting we map, so one map serves them — and reports what
it cannot merge: a setting whose **place** differs between lists is dropped and
named. Mere wording is not a place (below), and neither is the window around a
bitfield: `icpsSwSkuing` is read as 8 bytes in six lists and 32 in one, all of
them bit 0 of byte 0, so the bit is the same bit. A new generation is a rerun
against its own `mfit.exe`.

**A file that is one setting is read; a file the tool places itself is not.**
Most `length="0"` settings are computed and are left alone. But where the tool
gives a file exactly one logical setting, of a numeric kind, and no place in
it, the file *is* the setting: the value is its first bytes, and the width is
the kind's — `bup_sku/hw_binding`'s `HwBindingEn` (the RPMC / RPMB binding, one
byte), `policy/hmrfpo_state`'s `HmrfpoEnable`, `amt/rtfd/amt.wol`'s two-byte
`AmtIdleTimeout`, and seven more. A file with several such settings —
certificates, the ICC profiles, `pavp/hdcp_ports`' second port — is left to
MFIT's plugin: a guess would put one setting's byte under another's name. The
16 map holds **88 settings in 40 files** with these rules — every setting the
database gives a place in the bytes, whole-file or bitfield, and nothing else.
Since 2026-10-17 it is emitted from **three builds at once** (16.0.15.1662,
16.1.25.2091 and 16.1.42), merged with the same rules as one build's lists: a
file or a setting a newer build's lists dropped (a platform retired, a name
changed) is still read out of the images the older builds wrote, and the three
agree on every setting all of them carry. 16.1.42 adds ten settings the older
builds lack — `OEMInfo` / `OEMMakeInfo` / `OEMModelInfo` / `OEMDataStore` /
`MfgCountryOfOrigin`, `PSRSupported` (`/home/psr/genesis_info`), `SpiSwSeqEnable`
(`/home/mca/host_sw_sqnc_mode`), `ECOOBSmbusAddr`
(`/home/mctp/ec_oob_smbus_addr`), `BindingSigType` (`/home/rbe/binding_sig_type`)
and `icmEntitlement`.

**Two lists that word a setting differently are not a conflict.** Offset,
width, bits and options make the setting; the label and the help text are the
tool's prose and the lists truncate them differently (`IshPowerUpState`'s label,
`MctpEcAddress`'s help). The generator keeps the fuller wording and drops a
setting only where the *place* differs.

**A setting has two names and the map carries both.** The identifier is what the
tools' own layouts, reports and Intel's documents spell (`MELanPowerWell`); the
*label* is what the tool's panel shows ("LAN Power Well"), and it sits beside the
identifier in the same declaration — FIT's `<CfgOpt … label="LAN Power Well">`,
MFIT's `<UI name="MELanPowerWell" label="LAN Power Well" section="…">`. The
generators copy it where it differs from the identifier, so the panel can draw
"LAN Power Well" — the words an engineer reads on the tool's screen, with the
identifier (`MELanPowerWell`) the map's and a report's own. FIT 15 is the case
worth knowing: it
states no label at all for `FID_PAV`, `FID_ISH` and the other `FID_` settings,
because its panel shows those identifiers, and the map carries none rather than
repeating one. MFIT's `<UI>` element names a **panel section** the same way
(`section="WiredLanConfiguration"`); the maps do not carry it — nothing on the
panel groups by it yet.

**The UEP arrays carry 155 settings and the images write almost none of them** —
checked
2026-10-17, over the FIT 15 layout of the TGL LP family and two CSME 15 dumps
(`1.bin`, profile 0, and `CSME 15.bin`, profile 5). Every documented placement of
every other setting reads zero in both, including ones that *must* be set on a
Board built for profile 5: `$PlatformIntegrity/OemManifestSet` is 0 at all six of
its array-0 placements on the image whose Boot Guard is configured and whose BIOS
region carries the manifests, and so are `sb_acm_svn`, `sb_km_svn`,
`idlm_m_svn`, `cse_bootstrap_m_svn`, `ftpm_ek` and `RpmcSupported`. What is
written is the family's own Boot Guard word: `FBGAcmEn` reads 0 on one dump and 1
on the other, at **one** of its placements — the document merges every family's
placements for the one setting, and only the image's own family is live. So these
bits are the tool's *intent* for the fuses, not the image's record of them: what
the platform burns at End of Manufacturing is computed there, which is also why
`OemManifestSet` can read 0 while the manifests it is about are in the BIOS
region. Reading more of them from a dump is therefore not the next step; four
bytes at array 0 +0x70 that differ between the two dumps match no documented
placement and are the one thing here still unnamed.

**The panel shows them anyway, as the FPF Settings group.** The 155 count is
every array the tool writes; the settings the app reads are the ones placed in
the **first** array — the one the Boot Guard word is in — 56 in FIT 15's TGL LP
documents and 76 in MFIT 16.1.42's (71 in 16.1.25's), and their map (`UEPMap`)
is emitted from the same
`GetBitArrayValue` actions by
`Skills/me-eom-structures/scripts/uep_map.py`. The engine reads each setting's
bits out of the little-endian word at its offset (`UEPReader`, array 0 at
`$UEP`+0x0C) and the Full Info tree lists them under **FPF Settings**, in the
tool's own sections (`RpmcConfiguration`, `PlatformIntegrity`) with the tool's
label where it has one. The group is not a verdict about the fuses and the
values are not the platform's state: they are what the build wrote into the
image, which is what a dump can say, and most of them are zero. The rows are
under the tool's sections rather than the configuration map's because no
configuration map carries a section yet.

### The same material in FIT's own shape (ME 15)

The older FIT — `fit-15.0.exe` and its neighbours — carries the layout per
platform as its own resources, and
`Skills/me-eom-structures/scripts/fit_map.py <fit-15.0.exe> --straps tgp_lp`
prints `MEConfigurationMap+CSME15.swift` from them. A setting's place there is
an action of the `Nvar` module — `filePath` through an alias table, and a cell
(`cellIndex × cellSize + cellOffset`) or a plain `startOffset` with `varSize` —
and its words are the value class its `type="class:…"` names, its declaration
(`<CfgOpt …>`) giving the tool's own name for the setting (`label`) and what its
panel says about it (`help` — MFIT has the same words on the `<UI>` element of
the setting, with its paragraphs as `&#13;&#10;` where FIT writes `&#60;br
/&#62;`). Both are copied into the map and the Configuration tab shows the
second behind the `?` beside a row, in the tool's English: it is the tool's
documentation read where the row is. TGL LP gives **21 files and 60 settings**;
two of the four TGL layouts (`tgp_lp_a1`, `tgp_lp_c0`) agree on every binding
they share, and the H ones are another SKU's, so the LP pair is read as one map.

**ME 12 is the oldest generation with a map of its own.** FIT 12's CNP
documents give `cnp_lp_rvp` and `cnp_h_rvp`: 9 files and 21 settings for the
mobile half, 15 and 39 for the desktop one (the H documents add AMT, MCTP and
manageability settings), emitted as `MEConfigurationMap+CSME12` and
`…+CSME12Desktop` by `fit_map.py --generation 12`. Its volumes carry no
`FileTable.dat`, so the engine walks the MFS **home directory** for the paths
when the table is absent (`MEFirmwareAnalyzer`) — the part's own names, which
are the map's `/home/...` paths — and the CSME 12 dump at hand reads 11 files
through it: the EOM records, the policy file, `bup/si_features`,
`bup/bup_sku/hw_binding`, the HCI IDs, the live `manuf_lock` record appended
to every map, and others its build wrote.

**A place can be conditional.** The tool binds a setting to a file only under
another setting's value (`buildConditional`), and `MctpEcAddress` on the LP
family is the case: `eSpiEnabled = No` puts it in `/home/mctp/smt2_devices`
(+4, two bytes) and `= Yes` in `/home/mctp/espi_devices` (+0, two bytes), with
`ResetMctpEcAddress` mirrored to clear the copy the address left behind. The
desktop family binds it once, in `smt3_devices`. Both places are in the map with
their condition, and the engine picks the branch the image holds: the
condition's own value from the pages, or — where neither page carries the file
it lives in, as on `CSME 15.bin` — the branch whose file is there, marked
`assumed`. The value is decided once per condition, not per setting: a branch
chosen per setting would let the address and its reset disagree about the same
switch, and did, before that rule. `SmlinkBusSelection` carries the tool's other
relation, `DisableIf eSpiEnabled = Yes` — its value is in the file and does not
apply.

**RPMC is a file, not a setting the maps lay out.** Flash Image Tool's
"Hardware Binding Enabled" (`HwBindingEn`, `FpfHwBindingEn` on the Comet Point
documents) is the FPF hardware and RPMC / RPMB binding, and the tool keeps it
in `/home/bup/bup_sku/hw_binding` — one byte of `DisabledEnabledValues`, 0
Disabled and 1 Enabled. Its *siblings* in the tool's `RpmcConfiguration`
section, `RpmcSupported` and `RpmcRebindEn`, are placements in the UEP bit
arrays (`UepBitsArray0` +0x74 bit 4, `UepBitsArray3` +0x20, `UepBitsArray4`
+0x10) and read zero on every dump at hand — FIT-built CSME 15 and MFIT-built
CSME 16 alike — so nothing is claimed from them; the same conclusion the UEP
section above reaches from the other side. Measured on the dumps at hand:
`CSME 15.bin` Disabled, `1.bin` Enabled, `CSME 13.BIN` Enabled, `CSME 14.bin`
Disabled, both CSME 16 dumps Enabled, and `CSME 12.BIN` has no such file at all
— the setting is CSME 13's and later. The Summary's **RPMC Hardware Binding** row reports that
byte, the file system's copy first and the OEM Configuration partition's record
of it as the fallback.

**Each generation has two maps, one for each half of it.** The mobile families
(`_lp`, `_p`) and the desktop ones (`_h`, `_s`) layout a few settings
differently — TGL LP against TGL H: 56 settings against 52, 50 shared, one of
them moved (`SecureTouch` 8 → 18) and two the H half has alone — so the map
followed is the board's own. **Which half a dump is, nothing in the ME region
says**: the manifest's platform name is the same for both ("TGP" covers Tiger
Lake LP and H), and MFIT's chipset init table names the chipset rather than the
SKU. The descriptor does say: its PCH strap section is 69, 70 or 74 words on
the mobile parts and 90, 101 or 115 on the desktop ones. So
`FirmwareAnalysis.platformFamily` is read from that length
(`MEPlatformFamily(strapWords:)`), and both the engine and the panel ask
`MEConfigurationMap.forME(major:family:)` for the map — a dump with no
descriptor (an extracted region) is read as the mobile half, which is what
every map was before the choice existed. Measured on the dumps at hand:
`CSME 14.bin` 69, `CSME 13.BIN` 74, `CSME 15.bin` 70, `1.bin` 101,
`CSME 12.BIN` 90.

Three things that came out of reading the two databases against each other:

- **A kind's name lists its members in value order.** `yes_no_options` is Yes at
  0, `no_yes_options` No at 0, and the same for the Enabled/Disabled pair — which
  FIT states outright in its classes (`<Class name="YesNoValues">`: `Yes` 0, `No`
  1). Reading them as interchangeable had put "No" on every 0 of four ME 16
  settings, two of them readable in a dump (`CryptoHwSupport`,
  `NetServicesSupported`); the emitted map now says what the database says.
- **15 and 16 agree on `cfg_rules` and not on everything.** `MELanPowerWell` is
  at 188 in both, `ProcEmulation` at 488 in both; but `SecureTouch` is at byte 8
  of `iunit_oem_cfg` in FIT 15's layout and at 18 in MFIT 16's, and the settings
  `PavpSupported`/`IshSupported` are named `FID_PAV`/`FID_ISH` on 15 — which is
  why a generation reads its own map and not the newer one's.
- **The End of Manufacturing record is the one thing the newer layouts do not
  bind** — the tool writes it through `EomNvar` — so the 15 map takes those three
  entries from whichever document binds `EOM_Config`, and says so in its header.
  The bytes are the same in every generation (bit 0 of a 2-byte record, and the
  single byte of `mca/eom`), which is what makes borrowing them honest.

### ME 14: the same shape, one family at a time

`fit-14.0.exe` carries the same kind of resources for its own platforms —
`cml_lp`, `cml_h`, `icl_lp`, `icl_h`, `ehl`, `jsl`, `lkf`, `dg1` and the TGL
ones it shares with 15 — and the generator reads one family the same way:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py fit-14.0.exe \
    --straps cml_lp --generation 14 --tool 14.0 > MEConfigurationMap+CSME14.swift
```

Which family is *the dump's* was the first question, and the **microcode in the
BIOS region answers it**: `SPI_EF4018_128Mbit.orig.bin` (14.0.33.1125, SKU
Consumer LP) carries CPUIDs `0x806EA`, `0x806EB` and `0x806EC` — Comet Lake U —
and `0xA0660` — Comet Lake S — so its family is `cml_lp`, not one of Ice Lake's
or Jasper Lake's. Reading it through that map gives **10 files and 31 settings**,
and five of them are in the dump itself: `mca/eom` (`EOM = 1`, which is what the
engine's own live-record read of the same file says), `cfg_rules`, `si_features`,
`mctp/smt2_devices` and `amt/skip_rtfd/ncsi` — the five every map from 14 up lays
out, so a bench reads the same things first on any generation.

### ME 13: the same generator, its own family

`fit-13.0.exe` carries the same resources, read the same way, and its family for
the boards at hand is `icl_lp` — Ice Lake U, which is the dump's own chipset
string (`ICP-LP`) rather than an inference:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py fit-13.0.exe \
    --straps icl_lp --generation 13 --tool 13.0 > MEConfigurationMap+CSME13.swift
```

Ten files and 35 settings, and two things of its own beside the offsets:

- **The host-interface file is not there.** `/home/amt/skip_rtfd/ncsi` is laid
  out by 14 and every newer map and by neither the 13 one nor any other Ice
  Lake layout — a bench reading a 13 dump sees four of the five files it sees
  anywhere else.
- **No `Auto` marks at all.** The attribute is MFIT's; of the four maps only the
  CSME 16 one carries it, which is what makes a setting the builder cannot enter
  a newer-generation fact.

The NM-C711 dump reads nine of the map's ten files: `/home/mca/eom_config` is
laid out by FIT 13 but absent from that image, which is why its EOM on First Boot row
leans on the descriptor — the same state a CSME 14 image is in for a different
reason.



Two differences from the newer maps hold for the family:

- **No End of Manufacturing record.** FIT 14 binds `/home/mca/eom` and no
  `eom_config`, which is why the panel's EOM on First Boot row for an image of this
  generation leans on the descriptor's rights instead of on the flag.
- **Its own iunit files.** `iunit/port_cfg`, `iunit/sec_ctl`, `iunit/sec_touch`
  and `iunit/camera_mask` are in the 14 map and in neither of the newer two,
  where `iunit_oem_cfg` and `iunit_privacy_mode` stand instead.

**And where the profile lives is not in those layouts.** The four settings are
written in the UEP container's own record — the flags byte at `$UEP`+0x4C, in
three copies — and not in any `UepBitsArray`: the arrays that FIT 14's seven
layouts name are empty on every image at hand, which is exactly why reading them
gave 0 under every candidate placement and the first answer here was that the
profile is not in the image. Four FIT 14.0.20 builds of this dump, one per
profile, settled it (see "Where each fact lives" for the bytes). The layouts
remain the answer for the *file* map and for the settings beside the bits.

Two things the database is not. It is **per platform**: the lists are
`ADL-S`, `ELG`, `MTL-M`, `MTL-S` in that build, so a dump of another platform
needs the list for it (the offsets we read repeat across them — verified: the
four ADL-S lists differ in no offset — but the file lists differ in length, and a
Corporate-only setting like `ProcMissingDetect` is simply absent from a Consumer
list). And from **MFIT 18** the same file changes shape — 18.0.10.2285's
`Files.xml` holds 107 file paths and no
layouts at all — so the layouts for a newer generation are somewhere else in that
binary, to be found when that generation's structures are.

**What else the same binary documents.** The settings database is not the only
structure MFIT carries in its XMLs, and the others cover ground this project had
to work out by hand:

| XML (16.0.15.1662) | what it holds |
|---|---|
| `<platform>_Files.xml` | the ME file system settings — 66 files, **all** of them MFS files (`FileTable.dat` knows every one) |
| `StrapsDetails.xml` (967 KB) | the descriptor's straps, by name: `CPU_Strap_BIST`, `CPU_Strap_FIAx16_LOSL…`, the device-disabled bits, their CRC |
| `straps_projects.xml` | which strap project each platform type takes — `Intel(R) AlderLake P Chipset - Consumer - SPI` → `adp_p_straps.xml`, which is the string the Z Flow dump's own CDMD record carries |
| `DescConfFields.xml` | the descriptor's regions as fields: GbE (enable, length, binary), EC, PDR, IDLM, the OEM section, DMUP, PUNIT, the BIOS region |
| `pch_fuses.xml` | the fuses by project, platform and SKU — `ADL` → `S` → `Q670`/`W680` → the seven fuse names each |
| `AdditionalSMLinkConfFields.xml` | the SMLink fields |

**MFIT 18 rewrote the database.** `mfit-18.1.exe` (CSME 18.1, the System Tools
18.1.18.2749 package) carries its material in a new shape: `mfit_root`
documents of `serialized_item`s — a name, `offset`, `bit_low`/`bit_high`, and a
value that is a per-RVP expression (`?($rvp == MTL-P DDR5 … ? 0x3 : … )`) — with
`ui_item`s carrying the panel's label, section and help and `bind_action`s tying
the two together. The settings are `<Files>` documents of
`<File name=ALIAS><nvar name="…"><physical offset length bit_low bit_high>` plus
`<sku_support>` (identical in shape to what `Files.xml` gave until 16, but keyed
by alias and without the project lists), 59 files and 127 settings in this
build, with a second `<Files>` document listing the MFS paths
(`<FileName>`/`<FilePath>`).

**The strap layouts are still in the executable**, in the harness documents
the layout imports by name (`DescriptorPluginsCommon/data/straps/`:
`mtl_arl_p_a0_complex_straps.xml`, `mtl_m_…`, `mtl_p_…`). The packaging keeps
each as `mfit_data` blocks of `serialized_item`s — `CPU_smip` (the 35 CPU
strap fields, with the UI's labels and option words through `bind_action`s),
`PMC_SoC_smip` (257 fields, the MIP-table header and the CPU message header
among them), `CSME_smip`, `IOE_smip` and the PMC variants — so the CPU straps
are readable from the package after all; the earlier note that they were not
was looking at the `<import>` line rather than the document behind it. The
platform families are told by a new dictionary rather than by project
attributes: **MTL, ARL, LNL, PTL**. The IFWI layout adds the ESE package
(ESE, DMU, PUNIT, AUNIT, SOC ESE, SOC SPHY, SOC PMC) and the ACE / SOCC / PCHC
sub-partitions, and the descriptor's MIP area is restructured
(`MipDescNvar`, `PlatformSoftStraps`, `DescriptorSoftStraps`).

The **UEP data survived** as `UEPs_Data` documents: a `serialized_item` per bit
(offset plus `bit_low`/`bit_high`, no array index — `arrays_count` says how
many arrays), the FPF settings beside them as `ui_item`s, and the bindings as
`bind_action type="get_value"`. Four new ESE FPF bits sit beside the old ones
(`ESE_CFG_DONE`, `ESE_TRC_EN`, `ESE_ROM_SVN_EN` and the ESE package's own FPF
block). Both maps of this shape are read now. The **configuration map**:
`Skills/me-eom-structures/scripts/mfit18_map.py` turns the `<Files>` settings,
the path document and the `<ui_item>` words into
`MEConfigurationMap+CSME18` (67 settings in 32 files in 18.1), and the engine's
CSME 18 dump at hand — HP EliteBook 630 13.3 inch G11, 18.0.10.2288 — reads 17
of its configuration files through that map. The **UEP map**:
`uep18_map.py` turns `UEPs_Data` (a `serialized_item` per bit, a `ui_item` and
a `bind_action` for its words) into `UEPMap+CSME18`, 41 settings, and the tool's
own layout is what settles the container question the 15/16 pages had to
measure:

- The container is an **8-byte `$UEP` header** — signature, CRC-16, reserved —
  built by `UepHeader` in the tool's code and followed directly by
  `arrays_count × 0x80` bytes of arrays (`FitByteArray(arrays_count * 0x80)`).
  A `serialized_item`'s offset counts from the start of the arrays, so the
  first array begins **8 bytes** into the container, where the 15/16 area's
  measured start is 0x0C. `UEPMap.arrayStart` carries the generation's answer.
  An item at 0x80 or beyond is in a later array: the generator emits
  `Placement(array: at // 0x80, offset: at % 0x80)` and the map says
  `arraySize: 0x80`, so seven settings the MTL document places in the second
  array are read too (`PLAT_ID`, `DNX`, `RPMC_RB`, `ESE_ROM_SVN_EN`, the CSE
  FVC states and `PLAT_ID_V`). On the HP dump that array's word at +0x84 is
  0x001D0000 — `DNX` disabled, rebinding off, platform ID 0, the three FVC
  states set — and the readings agree.
- The header's CRC-16 is CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection)
  over the reserved word and every array: on the HP dump it reproduces the
  stored 0x9D38 over bytes +6…+0x208 — reserved plus four arrays — which also
  fixes the arrays' extent.
- Read at +8, the MTL document's items are coherent on that dump: `OEM_ID`
  0x103C (HP's PCI vendor ID), `KM_ID` 1, `FW_TYPE` 3, `BTG_PROFILE` 5,
  `OEM_CFG_DONE`/`GLITCH_D_EN` 1, the validity bits set. Read at the 15/16
  start they are not (`KM_ID` 15, `FW_TYPE` 0, `OEM_CFG_DONE` 0). The Boot
  Guard profile of that image is therefore 5, and the analyzer reads it through
  the map.

**CSME 12 to 14's UEP layouts are the FIT builds' class documents.** FIT
states the same area as a `Class name="Uep"` of `LayoutEntry`s, `CfgOpt`s and
`GetBitArrayValue` actions, one document per platform (`cnp_uep`, `cml_uep`,
`icl_uep`, …). `uep_fit_map.py --generation` takes each generation's own —
the CNP document for 12, Ice Lake's for 13 and Comet Lake's for 14, told by
the arrays the document builds and the RPMC options its platform has — and
emits `UEPMap+CSME12/13/14`: 42, 43 and 44 settings. The first array holds
most of each; what only later arrays hold is kept too (`SB_ACM_SVN`,
`SB_KM_SVN`, `SB_BSMM_SVN`, the TPM seed bits on 12; `IDLM_M_SVN` and the key
hash's siblings). The container is the class's own 8-byte header and its
0x80-byte arrays — four on 12 and 14, six on 13 — and the dumps at hand
confirm it: the CRC-16 covers header and arrays (+6…+0x208, +6…+0x302 and
+6…+0x202), `FW_TYPE` reads 3 with its valid bit, and on the four Boot Guard
builds of 13 and of 14 the profile bits at array 0 +0x5C and +0x44 read 0,
0x78, 0x69 and 0x79 — profiles 0, 3, 4 and 5, matching each build's record.
A setting's words are the tool's: a `$Class/Option` source takes that class's
label, help and value class (`SupportedFpfValues`' 0xC "No", 0xF "Yes" —
which is why `SPI`/`EMMC`/`UFS` read 12 or 15 rather than 0 or 1); a bare bit
takes the document's own `<!--NAME-->` comment. The 256-bit key hash is left
out, the reader taking at most 64 bits. The Boot Guard profile proper is
still the record these generations keep; the array's bits are read beside it.

**The CPU strap message.** `strap18_map.py` turns the `CPU_smip` document into
`CPUStrapMap+CSME18` (35 fields), and the message itself is read out of the
image's **MIP table**, which CSME 18 keeps in the FITC partition rather than
in the descriptor's MIP area:

- The FITC payload is a record table (`u32 count`, then 12-byte
  `{FileID, offset, size, flags}` records whose values are packed in order).
  One record is a MIP descriptor: `u16 NumberOfDescriptors`, `u16 SizeOfMip`,
  then `{BlockType, BlockOffset, BlockLength, Reserved}` per block, contiguous
  from the end of the header to the record's own last byte. On the HP dump it
  is FileID `0x10023E00` — the `smip` nvar, which is not an MFS file and has
  no FileTable name — with `NumberOfDescriptors` 4 and `SizeOfMip` 404.
- The blocks on that dump: type 1 `PmcAndCpu` 0x58 bytes, type 2 0x40 bytes,
  type 4 (CSME/DBC) 0xD0, and a type 0 terminator of 8 zero bytes. The first
  block is the `PMC_SoC_smip` container (its 257 fields run to 0x47), then the
  **CPU message header** at 0x48 — `Reserved_15_0`, `Interpretation_Num`
  (bit 16), `Reserved_23_17`, `CPU_Strap_Length` (bits 24–31) — and the
  message itself at 0x4C, `CPU_Strap_Length` words long.
- On the HP dump the length is 3 and the message is `00801000 04002000
  D6CE0000`; the stored CRC-16 `0xD6CE` is CCITT-FALSE over the words after
  the first with the CRC field zeroed, and the fields decode to the tool's own
  UI values: hyperthreading not disabled, all big cores active, BIST No, flex
  ratio 0, boot at P1, compute small cores all and small cores 2, IA/GT/SA VR
  addresses 0/1/2. The analyzer reports the message as `cpuStraps` and the panel
  as the **CPU straps** group.

**The MIP table's other containers.** The same table keeps the CSME (DBC),
PMC IOE and IOE blocks of `MipDescNvar`; their block types and document
layouts are the tool's, and the reading is checked the same way:

| type | container | document | block | fields |
|---|---|---|---|---|
| 1 | PMC SoC | `PMC_SoC_smip` | 0x58 (PMC straps 0x48 + CPU header and message) | 253 |
| 0 | CSME / DBC | `CSME_smip` | 8 bytes | 5 |
| 2 | PMC IOE | `PMC_IOE_smip` | 0x40 | 249 |
| 4 | IOE | `IOE_smip` | 0x3C (MTL-M) / 0xD0 (MTL-P, ARL-P) | 133 / 515 |
| 3 | PMC SOC 2 | `PMC_SOC_2_smip` | 0x60 (first 0x48) | 253 |
| 3 | CPU 2 | `CPU_2_smip` | 0x60 (last 0x18, at 0x48) | 42 |

The type-3 block is MTL-P / ARL-P only (`PmcAndCpu_2`). **No dump at hand
has a five-block table**, so its type and 0x60 length are the tool's struct
defaults (`MipDescriptorHeader5Blocks`: 1, 2, 4, 3, 0) and the two documents'
extents rather than a reading; the reader matches block type and length, so a
different shape simply reads nothing for those two. Their fields' UI text is
borrowed from `PMC_SoC_smip`/`CPU_smip` through the layout's
`ui_ref_container`.

`PMC_SoC_smip` also declares the CPU message header and the CPU fields; the
generator keeps only the `PMC_SoC_smip_Strap_` names, since the CPU message
has its own map.

`mip18_map.py` emits them into `MIPStrapMap+CSME18`. The IOE document has two
layouts that place the shared names at different offsets, so a layout is
chosen by the block's own length — the CSME 18 dump's block is 0xD0 and reads
the MTL-P layout. The check: every field whose document states one value for
every reference platform reads that value — 223/227 in PMC SoC, 249/249 in
PMC IOE, 5/5 in CSME, 443/448 in IOE. The PMC SoC four are this board's own
values (debug messaging off, ISH disabled, two Type-C SMBus addresses unset);
the IOE five likewise, and its 63 constant-valued fields all match.

**The SPHY OEM configuration nvar.** The FITC partition's `phy_oem_cfg`
(`/home/bup/phy_oem_cfg`, FileID 0x1001F200) carries the PHY tuning block, and
the `SphyNvar` document lays it out (`offset*8 + bitfield_low … + bitfield_high`;
`ValidByte`/`EnableBit` are the byte at `offset`). The package carries four SPHY
variants (522, 542, 967 fields and an API-table form) with identical headers;
the emitted layout is the one the CSME 18 dump verifies — all **522** constant
values read exactly — and it carries anchors (the common header, plus
`Sub_Section_Entry2_Header_8` = 0x5 against the 542-field variant's 0x19) so
another variant answers nothing. The panel shows the fields under "SPHY OEM
configuration".

**The descriptor's registers.** The same harness documents lay out FLMAP0/1/2,
FLCOMP, FLIL, FLMSTR, FLDRPLCY and FLUMAP1 bit by bit; `descriptor18_map.py`
emits them into `DescriptorRegisterMap+CSME18`, and the UEFI Structure panel
shows each register with the tool's field names. Places: absolute for
FLMAP0/1/2 (0x14/0x18/0x1C), FLDRPLCY (0x340) and FLUMAP1 (0xEFC); `FCBA << 4`
for FLCOMP/FLIL and `FMBA << 4` for FLMSTR. Verified on the CSME 18 dump:
FLMAP0 `00040003`, FLMAP1 `82100208` (two masters, strap section 0x100/130),
FLCOMP `0930F0F6`, FLUMAP1 `C0FF00FF`. The map is used from Meteor Lake on,
since FLCOMP's density and clock fields are that generation's.

**The descriptor's strap section on Meteor Lake is the SoC block.** `FLMAP1`
still places and counts it — 130 words at 0x100 on the HP dump — and the
harness document's `SoC` block is its layout: `mfit_data id="SoC"`, 1185
fields per document, **byte-addressed** (`offset` is a byte, bits count from
its LSB). `pch18_map.py` emits the 1184 fields the three documents agree on as
the 130-word table (`StrapMap+PCH18.swift`). The check is the dump itself: of
the fields whose document states a constant value — no `$rvp` expression — all
**250** read exactly that value in the image's section at 0x100. Thirteen
fields cross a 32-bit word boundary (three 32-bit CSME SMT IDs, three 16-bit
MPPHY pipe configs, four reserved spans) and cannot be a one-word field, so
they are left out; the words 41, 46 and 51 they partly cover hold no field of
their own.

**The PCH fuses are not in a dump.** `pch_fuses.xml` names the seven fuses per
platform and SKU — `CSME_FUSE_VALUE_BYTE_0…5` and
`MB_EN_AND_LPCDID_FUSE_VALUE_BYTE_0` — and the same binary carries their values
in a C header, `PCH_FUSES_H_` (`PREMIUM_RPP_P_CCG_CSME_FUSE_VALUE_BYTE_0 0x10`,
with bit meanings in its comments: csme_fuse 8–15, PSVN removal, fusa disable,
OEM IFP disable, ICC enhanced and SPI boot). They are the **SRAM-fuse
emulation** values Flash Image Tool writes for a harness, not a field of the
image: none of the 44 dumps at hand holds any SKU's seven-byte sequence
(checked 2026-10-17). There is therefore nothing in a dump for a row to
report, and no row is made. The bits a dump *does* carry next to them are the
PCH soft straps, which the descriptor panel reads (§2.6 of
`Design/UEFI/UEFI_IMAGE_FORMAT.md`).

So the descriptor's straps and the fuse landscape are documented in the same
place, in Intel's own naming — which is where a *descriptor* tool would read
them, not an ME one. The master-access masks this project reads by hand
(`FlashDescriptor.biosMaster`) are not in that list: those fields are still ours.

The straps are also in the *older* tools' own documents, with their places:
`fit-*.exe` carries a `<LayoutEntry name="PCH_Strap_…" offset="…"
bitfield_high="…" bitfield_low="…" value="…"/>` per field of the section, and
that is the layout the descriptor panel now names its strap words by —
`Design/UEFI/UEFI_IMAGE_FORMAT.md` §2.6, generated by
`Skills/me-eom-structures/scripts/strap_map.py`. The same documents carry the
processor strap section's layout (`CPU_Strap_…`), which the panel shows on the
descriptors that still hold the section — up to Cannon Point; the script emits
it with `--kind cpu` and keeps only the fields the documents of one length
agree on, because there the length is a weaker key (§2.7).

Where the databases are, on this machine: `mfit.exe` per tool version, and the
binary is the file to unpack
(`/Volumes/HDD 10Tb/.../Modular Flash Image Tool <version>/mfit.exe`, with
16.0.15.1662, 16.50.0.1186, 18.0.10.2285, 20.0.0.1482 and 21.0.2.1482 at hand —
one per generation the other-version work will reach for).

## What to work out next

**Where CSME 15 keeps the Boot Guard profile — settled, see above.** The section
is kept because the *method* is the one the next generation needs, and because
the first answer it produced was wrong in a way worth not repeating: the search
was for a **number**. MFIT offers the setting for
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

FIT 15's own `_uep.xml` documents answer the *shape* of it: the UEP area is
`$UEP`, a CRC and eight 0x80-byte blocks, and the Boot Guard block is at 0x60 of
the first one (`FBGAcmEn` 16, CPU debug 17, BSP init 18, `ProtectBiosEnvironment`
19, `MeasuredBoot` 20, `VerifiedBoot` 21, key manifest id 22–25), with Intel's
own `BootGuardProfiles` class tying each of the four profiles to one combination
of those bits — the profile is *not* in the image as a number, which is why the
tool's layouts have no field for it. What is missing is where a **vendor** dump
puts those blocks: the flags at that offset read zero on every image at hand,
including two whose CDMD states profile 5, so a reader that trusted the offset
would answer "0 - No_FVME" to every image whose key field is not empty. The
anchor that *is* verified is the OEM key hash at 0x98 of the second block — the
same byte the engine already reads through the entry, on all four CSME 15 dumps.
The two-build diff above is still the way to find the blocks themselves; the
scripts and the field map are in `Skills/me-eom-structures/reference/structures.md`.

**That experiment has now been run** (four FIT 15 builds of one project, differing
only in the profile). It settles one half of the question: the profile is **not a
number in the image** — no byte or dword holds 0, 3, 4 and 5 at the same
offset — which is true and was read at the time as "the profile is not in the
image at all". What it *is* is the four settings, as bits (see "The CDMD
partition" above); the search that produced this paragraph was looking for a
number, then for one byte that separates all four profiles, and neither exists.
The builds did show one thing that moves with the profile beside the bits: the
length of a table of
"key-manifest hash usage" records in the ME region's EFS area (48/56/72/64
records for profiles 0/3/4/5, strictly nested, eight records per step). That
table describes **a build**: on real board dumps it is board-specific (30, 33, 18
and 21 records on four of them), and none of them carries the profile's records —
including one whose CDMD states profile 5. A board's Boot Guard level is on the
**BIOS** side, in the boot policy manifest ECFinder reads, which is outside the
ME region this engine is given.

**Whether an older generation carries the profile in another place.** CSME 15 is
answered, and CSME 16 with it: three MFIT builds of one 16.1 image, differing
only in the profile, moved the UEP bits with it (`0x00`/`0x38`/`0x39` for
profiles 0/3/5) while CDMD's JSON and MFIT's own `.xml` said the same thing —
so on 16 the two keepings are both the tool's writing, not one inherited from
the input (the numbers are in
`Skills/me-eom-structures/reference/structures.md`). CSME 15 keeps the four
settings the same way (see "The CDMD
partition" above, and the correction at the end of
`Skills/me-eom-structures/reference/structures.md` for what the earlier search
looked for and why it could not find it). What is not answered is CSME 14, 12
and 11 — no CDMD configuration at all (no `FIT AS A FIDDLE` block anywhere in
the region) — and CSME 18, which carries the block and no
`BtGuardProfileConfig` key in it. For the older three the next step is the same
one that settled 15: a dump whose profile is known *independently* (a tool's own
report), then read the same bits; today the reading is deliberately limited to
the generations it was verified on, and a CSME 12 or 18 image answers "no record"
rather than a number taken from bits that mean something else. CSME 18 needs the
key's other spelling, which MFIT's settings database is the place to find.

For **CSME 14** the reading is blocked on one thing only: *where* its UEP area
keeps the bits. FIT 14 lays the four settings out **per platform family** —
seven different placements are in its resources, from `UepBitsArray0` offset
0x60 bit 16 (the one 15 and 16 use) to `UepBitsArray1` offset 0, and which is
`cml_lp`'s cannot be read out of the executable (its resource names are not in
it in plain form). The dump itself does not decide either: every candidate
placement reads 0x00 there, which is "profile 0" and also what an area with no
bits gives. One FIT 14 build at a known profile settles it, the way three builds
settled 15 and 16 — and the tool refuses a non-zero profile without an OEM key
hash in the project, so a key has to be put in first.

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
what confirmed CSME 16's reading of the key. Two limits, one now from its author:
on version 16 ECFinder looks at the **EOM flag alone** and builds its report from
that, so it says nothing about the descriptor's rights — an image that will close
Manufacturing by them reads there as if it would not. And its Boot Guard verdict
is two-valued — `BG0` or `BG5` — tracking the vendor manifests and the engine's
state rather than the profile number, so it can confirm that a profile is
*configured* and not which one. What it is good for is the key hash, where its
report matched the entry's field byte for byte on the image that was checked.

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
