---
name: me-eom-structures
description: Read the End-of-Manufacturing, Boot Guard and OEM-key facts out of an ME dump — the MFS/configuration records behind them, the UEP area, and how they compare with MFIT's own report. Also the home of the generators that turn a tool's own layouts into the engine's maps — descriptor registers, PCH/PMC/CPU straps, configuration settings, UEP bits and GPIO feature pins. Use when working on the ME Analyzer's manufacturing/Boot Guard rows, when a dump's EOM or Boot Guard state has to be established, when MFIT's build report has to be checked against the bytes, or when one of those maps has to be emitted or extended.
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
python3 Skills/me-eom-structures/scripts/mfit_map.py \
    <mfit-16.1.42.exe> <mfit-16.0.15.exe> \
    --generation 16 --tool "16.1.42, 16.0.15.1817" --format json > \
    Packages/MEFirmware/MapSources/configuration/csme16.json
```

MFIT's settings database, unpacked and turned into the map the panel reads: the
files, the settings in each, their offsets, bits, MFIT's own option labels,
what its panel says about a setting (`help`, on the `<UI>` element — shown
behind the `?` beside a row) and
its `Auto`/`Generic` marks, and the tool's own name for a setting where its panel
shows something other than the identifier (`label` — "LAN Power Well" for
`MELanPowerWell`). **Several builds may be given at once**, and are merged with
the same rules: the CSME 16 map is emitted from 16.1.42 and 16.0.15.1817
together, so a file a newer build's lists dropped is still read out of the
images the older ones wrote. It merges the platform lists and reports what
it could not merge rather than guessing — a setting two lists lay out **differently**
(different offset, width or bits) is dropped and named. A setting the lists give
the same place but word differently — one truncates a label or a help sentence —
is not a conflict: the setting stays, with the fuller wording.

MFIT states no place for many settings (`length="0"`): values it computes,
certificates, the ICC profiles. One case is readable and is read: **a file that
is one setting** — the tool gives it exactly one logical setting, of a numeric
kind, and no place — is the setting at offset 0, with the width its kind names
(`disabled_enabled_options` one byte, `word` two). That is where
`bup_sku/hw_binding`'s `HwBindingEn` (the RPMC / RPMB binding) comes from, and
`policy/hmrfpo_state`, `amt/rtfd/amt.wol` and six more. A file the tool keeps
several such settings in is left to its plugin and not read: a guess would put
one setting's byte under another's name. Same rules as above: read the diff,
don't paste blind.

**MFIT 18 rewrites the database** (`mfit-18.1.exe`): no `<Files project>` lists
and no `ProcessNvar` actions any more. The settings are one `<Files>` document
of `<File name="POLICY_CFG_RULES">` elements, an `<nvar name="…">` per setting
with its `<physical offset length bit_low bit_high>`, the panel's words in the
platform documents' `<ui_item name label config_type config_params help_text>`,
and a second document mapping each alias to its MFS path
(`<FileName value="…"/><FilePath value="/home/policy/cfgmgr/cfg_rules"/>`). The
generator for that shape:

```bash
python3 Skills/me-eom-structures/scripts/mfit18_map.py ~/Downloads/1/mfit-18.1.exe \
    --format json > Packages/MEFirmware/MapSources/configuration/csme18.json
```

The same rules apply in the new shape: `length="dynamic"` is a place only the
plugin knows and is read when the file is one setting of a numeric kind, the
width taken from the kind; an `<nvar>` with no `<physical>` is a build input or
a string, and is left out. MFIT names a setting inside a file with the file's
suffix where one name serves several files
(`EomFirstBootEnabled_eom_config`, `TypeCPortRetimerMCTPSmbusAddr_ncsi`), and
the `ui_item` carries the bare name — the suffixes are stripped from the right
until one answers. A setting two platform documents give a different
`config_type` or option list for is dropped and named: its words would be
another platform's. 18.1 yields 67 settings in 32 files; the CSME 18 dump at
hand (HP EliteBook 630 G11, 18.0.10.2288) reads 17 of its configuration files
through the map. The CPU strap layouts are **not** in the 18 database: they
moved into the per-platform plugin data MFIT does not ship, so CSME 18 has no
MIP strap table here.

The older FIT carries the same material in its own shape, per platform:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-15.0.exe> --straps tgp_lp \
    --format json > Packages/MEFirmware/MapSources/configuration/csme15.json
```

There a setting's place is a `ProcessNvar` action — `filePath` into an alias
table, and a cell (`cellIndex × cellSize + cellOffset`) or a plain
`startOffset`/`varSize` — and its words come from the value class its
`type="class:…"` names, its declaration (`<CfgOpt …>`) giving the tool's own name
for it (`label`) and what its panel says about it (`help`) beside the
identifier. Both tools write the help as one attribute with their own breaks in
it — FIT `&#60;br /&#62;`, MFIT `&#13;&#10;` — and the generator resolves the
entities and turns a break into the line it stands for, so a map carries prose
and no markup. A place the tool names by **its file alone** (`{'filePath':'$FilePaths/HwBinding'}`,
no offset or size) is a setting the file *is*: the value is its first byte. The
width comes from the declaration's type — a value class is one byte, and
`byte`/`word`/`dword`/`qword` state their own. The types that are not numbers
(`path`, `string`, `bitmap`) and `target="this"` (the tool writing the whole
file, certificates among them) are left out, and the generator prints them as
one `not read — …` line, so what a map does not hold is a list rather than
silence.

**A layout is more than the platform document `--straps` selects.** FIT splits
it: that document carries the build's straps and the settings that differ,
while what every platform of the family shares is bound in a **common document
it includes** — Boot Guard's policy, key-manifest-id and OEM-key-hash files on
CSME 11, the FPF hardware binding, the ICC profile keys, the OEM certificates,
BIST, MCTP and the OEM tag on the newer generations. The generator follows
`<Include>` transitively and reads the bindings of the whole closure; reading
the selected document alone loses those settings without a warning. An include
names a file, and a document states its own name only in the licence header —
which most of them carry over from another file — so a name resolves an include
only where it is unique. FIT 15 packs two documents called
`lkf_fit_layout_1_7_common.xml`; the one that defines more of the classes the
including layout refers to is the one it was written against (114 of 191
against 55), and that is how the ambiguous name is settled.

A place the tool gives only under another setting's value — its
`buildConditional` actions — is kept with that condition (`Condition(name:value:)`,
the value resolved through the condition setting's own value class:
`eSpiEnabled = No` is `NoYesValues`' 0), and a setting the tool switches off
(`DisableIf`) carries `disabledBy`. Both branches of a conditional setting are
in the map, one in each of the two files; which one an image holds the engine
decides from the pages, and `Skills/me-eom-structures/reference/structures.md`
says how. `--straps` picks the family whose layout
is wanted
(`tgp_lp` is ME 15's own), and `--generation`/`--tool` name the map in the file
it emits:

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-14.0.exe> \
    --straps cml_lp --generation 14 --tool 14.0 --format json > \
    Packages/MEFirmware/MapSources/configuration/csme14.json
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-14.0.exe> \
    --straps cml_h --generation 14 --tool 14.0 --variable csme14Desktop \
    --format json > Packages/MEFirmware/MapSources/configuration/csme14Desktop.json
```

ME 11's is FIT 11's SPT layout (`--straps spt_fit_layout`): one set of
documents for both halves, so one map serves either family and there is no
desktop twin. Its volumes carry no `FileTable.dat` either, and the CSME 11
dump at hand (11.8.92.4222, Corporate LP) reads 37 of the map's 43 files
through the home directory — the EOM record, the policy file,
`bup/si_features`, `pavp/lspcon_port`, the PTT records, `manuf_lock`, and,
from the common document, **Boot Guard's own records**: `secureboot/bootpoltype`
(measured/verified boot), `bootpolres`, `kmid`, `pubkeyhash` (the OEM public
key hash), `enfpolicy`, `selftestres` and `s3optdis`.

ME 12's are `cnp_lp_rvp` and `cnp_h_rvp` (the strap include the CNP layout
names; the older tool calls its strap files `*_rvp`, not `*_straps`). Its
volumes carry **no `FileTable.dat`** — the names live in the MFS home
directory — so the engine walks that tree for the paths when the table is
absent (`MEFirmwareAnalyzer`). The two maps have 25 and 31 files, and the CSME
12 dump at hand reads 19 of the mobile map's 25, among them the EOM records,
the policy file, `bup/si_features` and `bup/bup_sku/hw_binding`.

```bash
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-12.exe> \
    --straps cnp_lp_rvp --generation 12 --tool 12.0 --format json > \
    Packages/MEFirmware/MapSources/configuration/csme12.json
python3 Skills/me-eom-structures/scripts/fit_map.py <fit-12.exe> \
    --straps cnp_h_rvp --generation 12 --tool 12.0 --variable csme12Desktop \
    --format json > Packages/MEFirmware/MapSources/configuration/csme12Desktop.json
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
    --straps tgp_h --generation 15 --tool 15.0 --variable csme15Desktop \
    --format json > Packages/MEFirmware/MapSources/configuration/csme15Desktop.json
```

ME 14's families are `cml_lp` and `cml_h`, ME 13's `icl_lp` and `icl_h`
(`icp_n_icl_h` is the same map with one setting fewer). MFIT needs neither:
its database merges the eight platform lists it builds from, and conflicts are
dropped and named. When a new family is added, run the generator twice and keep
both files — the panel and the engine ask through `forME`, so a half without a
map is a generation read with the other half's offsets.

The remaining families use the same invocation: `csme11` with
`--straps spt_fit_layout --generation 11 --tool 11.0`, `csme13` with
`icl_lp --generation 13 --tool 13.0`, `csme13Desktop` with `icl_h` and
`--variable csme13Desktop`, `csme14Desktop` with `cml_h` and its variable.

The JSON files are compiled into one binary; the version in
`Packages/MEFirmware/MapSources/manifest.json` changes only when their digest
does, and the same number is the code's mark (`Design/MAP_DATA.md`):

```bash
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/MEFirmware/Sources/MEFirmware/Resources/ConfigMaps/ConfigMaps.bin \
    --manifest Packages/MEFirmware/MapSources/manifest.json \
    --swift-version-file Packages/MEFirmware/Sources/MEFirmware/Configuration/MEConfigurationDataVersion.swift \
    --swift-enum-name MEConfigurationDataVersion \
    Packages/MEFirmware/MapSources/configuration/csme11.json \
    … csme12, csme12Desktop, csme13, csme13Desktop, csme14, csme14Desktop,
    csme15, csme15Desktop, csme16, csme18 …
python3 Skills/me-eom-structures/scripts/map_bin.py build --check …same arguments…
```

**CSME 16's map is the merge of two builds**, and the older one is not
optional: 16.1.42's database no longer lists `/home/mctp/smt3_devices`, so the
map read from it alone would lose that file and its `MctpEcAddress` setting.
The 16.0.15 build states it, and the merge keeps it.

The tool lays the Boot Guard bits out per family as well, which is a fact about
the *tool's documents* and not about where a vendor image keeps them: on both
generations at hand the four settings reach the image through the UEP area's
record, not through the array those layouts name (see the end of
`reference/structures.md`). One thing that generator cannot take from the chosen
platform: the End of Manufacturing record, which the newer layouts do not bind
at all (the tool writes it through `EomNvar`), so it is filled in from whichever
document binds `EOM_Config` and marked as such in the file's header.

## Emitting the GPIO feature pin map

Flash Image Tool names the pins the CSME firmware may drive in five value
classes — the feature set (`GPIO_TOUCH_FEATURE_ID`), the usage
(`INTEGRATED_TOUCH_1`), the owner (`CSME_MODE`), the pad mode
(`NATIVE_FUNCTION_1`) and the GPIO group (`GPP_E`) — and writes the configured
pins to `/home/gpio/csme_pins`, the file the `MeFeaturePins` class's
`ProcessFeatureGpios` action names. `gpio_map.py` emits the dictionaries, and
`GPIOPinReader` reads the file's records through them:

```bash
python3 Skills/me-eom-structures/scripts/gpio_map.py <fit-11.exe> \
    --generation 11 --tool 11.0 --variable csme11 --format json > \
    Packages/MEFirmware/MapSources/gpio/csme11.json
```

The JSON files are compiled into `GPIOMaps.bin`; the version in
`MapSources/gpio/manifest.json` changes only when their digest does, and the
same number is the code's mark (`Design/MAP_DATA.md`):

```bash
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/MEFirmware/Sources/MEFirmware/Resources/GPIOMaps/GPIOMaps.bin \
    --manifest Packages/MEFirmware/MapSources/gpio/manifest.json \
    --swift-version-file Packages/MEFirmware/Sources/MEFirmware/Configuration/GPIOPinMapDataVersion.swift \
    --swift-enum-name GPIOPinMapDataVersion \
    Packages/MEFirmware/MapSources/gpio/csme11.json … csme15 …
python3 Skills/me-eom-structures/scripts/map_bin.py build --check …same arguments…
```

Neither the file nor its records are in any published specification. Both
shapes were settled on the images at hand, and each field is anchored on
something the tool itself states:

- **CSME 11** writes **20-byte records of five dwords** — usage, group, pad,
  ownership, pad mode. Every record of the Lenovo CSME 11 image matches the
  default FIT 11 gives the same usage in its documents: `NFC_RST` = GPP_E_4,
  `NFC_IRQ` = GPP_E_12, `FWUPDATE` = GPP_B_15. That is what fixes the order.
- **CSME 12 and later** write **12-byte records of packed bytes** — feature id,
  group, pad, reserved, usage, reserved, ownership, pad mode, then four
  reserved bytes. The CSME 12 images at hand show a touch set (feature 1, usage
  0/1, group B/E), an SMT set (feature 3, usage 12/13, group C, native
  function 1) and a CPU detection pin (feature 2, usage 5).

The **OEM Configuration** stream (owning file 7) overrides the Intel one (6)
where both name the file, as it does for every configuration record, so the
reader prefers it. An empty file is a platform with no feature pins — what the
CSME 13-15 images carry — and is not decoded. MFIT's generations have no
`GpioCsme*` classes, so they have no map and their pin file is not read.
A group value the tool's own documents disagree about (GPP_J and GPD both take
9 in one family) is emitted unnamed, and the reading shows the number.

## Emitting a generation's FPF/UEP settings

The UEP area's bits the platform burns at End of Manufacturing are laid out by
the tool's `GetBitArrayValue` actions, and the settings the actions name are
declared in the same documents' `<CfgOpt>` lists:

```bash
python3 Skills/me-eom-structures/scripts/uep_map.py <mfit.exe> \
    --generation 16 --tool "Modular Flash Image Tool 16.1.42" \
    --format json > Packages/MEFirmware/MapSources/uep/csme16.json
```

The container keeps several arrays (`UepBitsArray0`, `…2`, `…4`) and the tool
places most settings in more than one. **Only the first array is kept**: it is
the one an image's reading takes (`UEPReader`, and the Boot Guard word is its
first caller — `$UEP`+0x6E is array 0 +0x60 bit 16), and a setting the tool
places only in another array is not in the map, which the script counts on
stderr. Each kept setting carries the tool's identifier (`name`), the place
(`offset`, `bit`, `count` in the little-endian word at that offset), and the
tool's own panel text where it has any: `label` ("RPMC Supported"), `section`
(`RpmcConfiguration`, how its interface groups them) and `help`. MFIT names its
settings in the interface; FIT 15 names only the identifiers for the low-level
bits, and those rows show the identifier. The first array holds 56 settings in
FIT 15's TGL LP documents and 76 in MFIT 16.1.42's (71 in 16.1.25's — the newer
build adds `CPU_AAB_ENABLED`, `PCH_AAB_ENABLED`, `OEM_CIM_ARB_EN`,
`OEM_PIM_ARB_EN` and `RpmcOverEc`).

What a dump's array holds is the **state the build wrote**, not the fuses: most
settings read zero on every dump at hand — `Design/ME_STRUCTURES.md` says why,
and that reading more of them from a dump is not a test of the map.

**CSME 18's documents are the rewritten `UEPs_Data` shape**, and have their own
generator:

```bash
python3 Skills/me-eom-structures/scripts/uep18_map.py ~/Downloads/1/mfit-18.1.exe \
    --format json > Packages/MEFirmware/MapSources/uep/csme18.json
```

A setting is a `<serialized_item name… type="BitfieldItem" offset bit_low
bit_high>`, its words a `<ui_item>` bound to it by `<bind_action
type="get_value" ui_controller=… serialized_item=…>`, and `arrays_count` says
how many arrays the container keeps. The tool's own code builds the area as
its 8-byte `$UEP` header (signature, CRC-16, reserved) followed by
`arrays_count × 0x80` bytes, and an item's `offset` counts from the start of
the arrays — so **the first array begins 8 bytes into the container**, not at
the 0x0C the 15/16 area was measured at (`UEPMap.arrayStart` states which).
An item at 0x80 or beyond is in a later array: it is emitted as
`Placement(array: at // 0x80, offset: at % 0x80)` and the map states
`arraySize: 0x80`, so the reader takes it where the tool puts it. An item past
the document's own `arrays_count` is not kept, and the script counts those.
Enumerated settings keep the tool's option words (`options`: the profile's
0/3/4/5 as "Boot Guard Disabled" … "Verified and Measured Boot"), so the panel
shows the word rather than the number.

18.1 yields 41 settings: 34 in the first array (32 from the MTL document,
offsets 0x20–0x4C, and two ESE bits) and seven in the second at offset 0x04 —
`ESE_ROM_SVN_EN`, `PLAT_ID`, `DNX`, `RPMC_RB`, `PLAT_ID_V`,
`CSE_BOOTSTRAP_SVN_EN`, `CSE_FW_SVN_EN`. On the CSME 18 dump at hand the
8-byte-header reading is what makes the bits coherent — `OEM_ID` 0x103C (HP's
PCI vendor ID), `KM_ID` 1, `FW_TYPE` 3, `BTG_PROFILE` 5, the validity bits set
— while the 15/16 array start gives `KM_ID` 15 and `FW_TYPE` 0; the second
array's word reads 0x001D0000 (`PLAT_ID` 0, `DNX` 1 — disabled, `RPMC_RB` 0,
the three FVC states 1); and the header's CRC-16 (poly 0x1021, init 0xFFFF, no
reflection) over reserved + four arrays reproduces the stored word exactly.

**CSME 12, 13 and 14's documents are the FIT class documents**, in the older
shape: `<Class name="Uep">` with `LayoutEntry`s, `CfgOpt`s and
`GetBitArrayValue` actions, one document per platform. A build carries many —
Ice Lake, Comet Lake, CNP, TGL, EHL, JSL, LKF, EGS — and `uep_fit_map.py`
takes the generation's own, told by the document's shape because FIT keeps
the resource names to itself:

| generation | document | arrays | marker |
|---|---|---|---|
| 12 | CNP | 4 | `fw_type`, no RPMC option |
| 13 | Ice Lake | 6 | `PttRpmcSupported`, no ISIF setting |
| 14 | Comet Lake | 4 | `PttRpmcSupported`, no ISIF setting |

```bash
python3 Skills/me-eom-structures/scripts/uep_fit_map.py ~/Downloads/1/fit-12.exe \
    --generation 12 --format json > Packages/MEFirmware/MapSources/uep/csme12.json
python3 Skills/me-eom-structures/scripts/uep_fit_map.py ~/Downloads/1/fit-13.0.exe \
    --generation 13 --format json > Packages/MEFirmware/MapSources/uep/csme13.json
python3 Skills/me-eom-structures/scripts/uep_fit_map.py ~/Downloads/1/fit-14.0.exe \
    --generation 14 --format json > Packages/MEFirmware/MapSources/uep/csme14.json
```

The `Uep` class also states the container — signature, CRC-16, reserved, then
the arrays — so the first array is again 8 bytes in (`arrayStart: 8`,
`arraySize: 0x80`). A name the tool repeats in a later array is kept once,
where it first appears; the 256-bit key hash is left out because the reader
takes at most 64 bits. The tool's words come from the configuration classes a
source names (`$OEMandPlatformIDs/OemVendorId` → "OEM Vendor ID") and from its
value classes (`SupportedFpfValues`: 0xC "No", 0xF "Yes"); a bare bit takes
the document's own `<!--NAME-->` comment.

12.0 yields 42 settings (34 in the first array, 8 only later), 13.0 43 (42 +
1) and 14.0 44 (36 + 8). The dumps at hand confirm each: the container's
CRC-16 covers header and arrays — +6…+0x208 on CSME 12, +6…+0x302 on CSME 13
(six arrays) and +6…+0x202 on CSME 14 — `FW_TYPE` reads 3 with its valid bit,
and on the four Boot Guard builds of 13 and of 14 the profile bits at array 0
+0x5C (13) and +0x44 (14) read 0, 0b0111_1000, 0b0110_1001 and 0b0111_1001:
profiles 0, 3, 4 and 5, exactly what each build's record says.

The JSON files are compiled into `UEPMaps.bin`; the version in
`MapSources/uep/manifest.json` changes only when their digest does, and the
same number is the code's mark (`Design/MAP_DATA.md`):

```bash
python3 Skills/me-eom-structures/scripts/map_bin.py build \
    --out Packages/MEFirmware/Sources/MEFirmware/Resources/UEPMaps/UEPMaps.bin \
    --manifest Packages/MEFirmware/MapSources/uep/manifest.json \
    --swift-version-file Packages/MEFirmware/Sources/MEFirmware/Configuration/UEPMapDataVersion.swift \
    --swift-enum-name UEPMapDataVersion \
    Packages/MEFirmware/MapSources/uep/csme12.json … csme18 …
python3 Skills/me-eom-structures/scripts/map_bin.py build --check …same arguments…
```

**The CPU strap message has its own layout and its own place.** CSME 18 does
not keep it in the descriptor's MIP area; it is in the FITC partition's MIP
table (the `smip` nvar), and `strap18_map.py` emits the tool's `CPU_smip`
document for it:

```bash
python3 Skills/me-eom-structures/scripts/strap18_map.py ~/Downloads/1/mfit-18.1.exe > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/CPUStrapMap+CSME18.swift
```

The document lives among the strap XMLs (`DescriptorPluginsCommon/data/straps/`,
packaged in the executable as `mfit_data` blocks): a `serialized_item` per
field with its byte `offset` into the message and its `bit_low`/`bit_high` in
the little-endian dword there, plus the panel's words through `bind_action` —
which is where "Disable Hyperthreading", "All Cores Active" and the rest of
the CPU Straps page come from. The three platform documents at hand place the
35 fields alike; a disagreement is dropped and named, and no default is
emitted (the values are per reference platform, `$rvp`).

Where the image keeps it: the FITC payload is a record table (12-byte
`{FileID, offset, size, flags}` records), and one record — FileID `0x10023E00`
on the dump at hand — is a **MIP descriptor**: `u16 NumberOfDescriptors`,
`u16 SizeOfMip`, then a `{BlockType, BlockOffset, BlockLength, Reserved}` per
block, contiguous. On the HP CSME 18 dump: 4 blocks (PMC_SoC 0x58, a 0x40
block, CSME 0xD0, a terminator), the CPU message header at block 0 + 0x48
(`Reserved`, `Interpretation_Num` bit 16, `CPU_Strap_Length` bits 24–31 = 3)
and the message at 0x4C: `00801000 04002000 D6CE0000`. The last word's high
half is the CRC-16 (CCITT-FALSE over the words after the first, its own field
zeroed) — `0xD6CE` here — and the fields decode to the tool's defaults: All
Cores Active, BIST No, flex ratio 0, boot at P1, compute/small cores all and
2, IA/GT/SA VR addresses 0/1/2.

**CSME 18's descriptor strap section is the SoC soft-strap block.** `FLMAP1`
places and counts it like a PCH strap section (130 words at 0x100 on the dump
at hand), and MFIT 18's `SoC` harness block lays it out — 1184 fields after
merging the three platform documents:

```bash
python3 Skills/me-eom-structures/scripts/pch18_map.py ~/Downloads/1/mfit-18.1.exe \
    --format json > Packages/UEFIImage/MapSources/strap/pch18.json
```

The document is **byte-addressed**: a `serialized_item`'s `offset` is a byte
and `bit_low`/`bit_high` count from that byte's least significant bit, so the
field's place in the section is the bit range `offset*8 + bit_low …
offset*8 + bit_high` — not the dword at `offset`. The script converts that to
the word and bits `DescriptorStrapMap` holds. A field that crosses a 32-bit
word boundary (three 16-bit MPPHY pipe configs, three 32-bit CSME SMT IDs and
four reserved spans) cannot be one `Field` and is left out, counted on stderr;
the three words the 32-bit IDs partly cover therefore hold no field of their
own. Placement is verified against the dump: all **250** fields whose document
states a constant value read exactly that value in the image's section, and the
eSPI clock and GPRD fields the panel's rows use are in the table.

**The MIP table's other containers have their own map.** Beside the CPU
message the table keeps the CSME (DBC), PMC IOE and IOE blocks —
`MipDescNvar`'s children — and `mip18_map.py` emits their layouts:

```bash
python3 Skills/me-eom-structures/scripts/mip18_map.py ~/Downloads/1/mfit-18.1.exe > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/MIPStrapMap+CSME18.swift
```

The blocks' types are the MIP descriptor's: **1** PmcAndCpu — `PMC_SoC_smip`
(253 PMC fields; the block also holds the CPU header and message, which are
the CPU map's), **0** CSME/DBC (`CSME_smip`, 8 bytes), **2** PMC IOE
(`PMC_IOE_smip`, 0x40), **4** IOE (`IOE_smip`), **3** PmcAndCpu_2 (MTL-P and
ARL-P only) — `PMC_SOC_2_smip` (253 fields, 0x48) then `CPU_2_smip`
(42 fields, 0x18) at 0x48, the block 0x60 bytes. The IOE document exists in
two layouts — MTL-M's 0x3C bytes and MTL-P/ARL-P's 0xD0, which place the
shared names at **different offsets** — so the map carries both and the
reader picks one by the block's own length. A field's place is a bit range of
its block (`offset*8 + bit_low … + bit_high`); PMC SoC, PMC IOE and CSME are
dword-aligned, IOE is byte-addressed. 253, 5, 249, 515 and 253 + 42 fields
(IOE's 515 from the two agreeing documents; MTL-M's 133 are the 0x3C
variant).

`PMC_SOC_2_smip` and `CPU_2_smip` bind their fields to another container's
interface text (`ui_controller="$(ui_ref_container):HyperThreadingDisable"`,
the layout's `ui_ref_container`), so the generator resolves those against
`PMC_SoC_smip` and `CPU_smip` respectively. **No image at hand has a
five-block table**: type 3 and the 0x60 length are the tool's struct defaults
(`MipDescriptorHeader5Blocks`: 1, 2, 4, 3, 0) and the two documents' extents,
stated as such — a dump whose block does not match reads nothing for these
two rather than something wrong.

Checked on the dump: the block lengths are exactly the documents' extents,
and every field whose document states one value for every reference platform
reads it — PMC SoC 223/227, PMC IOE 249/249, CSME 5/5, IOE 443/448. The
PMC SoC and IOE mismatches are board values the reference lists do not carry
(the four PMC SoC ones are debug messaging, ISH disable and two Type-C SMBus
addresses — real differences of this board, not misalignment).

**The descriptor's registers are in the same documents.** MFIT 18 lays out
FLMAP0/1/2, FLCOMP, FLIL, FLMSTR, FLDRPLCY and FLUMAP1 as `mfit_data`
bitfields, and `descriptor18_map.py` emits them for the UEFI Structure panel:

```bash
python3 Skills/me-eom-structures/scripts/descriptor18_map.py ~/Downloads/1/mfit-18.1.exe > \
    Packages/UEFIImage/Sources/UEFIImage/DescriptorRegisterMap+CSME18.swift
```

A register is placed absolutely (FLMAP0/1/2 at 0x14, FLDRPLCY at 0x340,
FLUMAP1 at 0xEFC) or at a base the descriptor states (`FCBA << 4` for
FLCOMP/FLIL, `FMBA << 4` for the six FLMSTR words); a field is a bit range of
its register, the tool's name stripped of `Base_Descriptor_SOC_Strap_`, with
its labels and option words. The map is used from Meteor Lake on: FLCOMP's
density and clock bits are that generation's. Checked on the CSME 18 dump —
FLMAP0 `00040003` (FCBA 0x30, FRBA 0x40), FLMAP1 `82100208` (FMBA 0x80, 2
masters, PCH section 0x100/130), FLCOMP `0930F0F6`, FLDRPLCY `20000000`,
FLUMAP1 `C0FF00FF` (VSCC at 0xFF, MIP table at 0xC0).

Note that MFIT names FLMAP0's region-count bits (24–26) reserved: the panel's
own "Regions" row still counts them, and the register table shows the tool's
word.

**The older builds state the same registers in their platform documents**, as
`<Class name="FLMAP1">` bodies of `LayoutEntry` bitfields, one set per
platform. `descriptor_fit_map.py --platform` selects the platform by the
strap include its layout names and keeps only the fields every one of its
documents states identically:

```bash
python3 Skills/me-eom-structures/scripts/descriptor_fit_map.py \
    ~/Downloads/1/fit-15.0.exe --platform tgp_lp --generation tigerPoint \
    --tool 15.0 > \
    Packages/UEFIImage/Sources/UEFIImage/DescriptorRegisterMap+TigerPoint.swift
python3 Skills/me-eom-structures/scripts/descriptor_fit_map.py \
    ~/Downloads/1/fit-12.exe --platform cnp --generation cannonPoint \
    --tool 12.0 > \
    Packages/UEFIImage/Sources/UEFIImage/DescriptorRegisterMap+CannonPoint.swift
```

and the same for FIT 11's `spt` (Sunrise Point) and FIT 13's `ehl`/`jsl`.
A generation's documents can be spread over several builds, so several
executables and several platform tokens may be named —
`--platform cnp_lp_rvp,cnp_h_rvp` takes both halves, and FIT 12–15 together
state all four Cannon Point registers (the CNP build FLMAP1 and FLCOMP, FIT
13's CNP documents FLMAP0, FIT 14's FLMAP2).
**The maps are partial where the builds are**: masters 1, 2 and 4 and the
region registers are in a common document the builds name but do not embed,
so a register a map does not hold stays unnamed rather than taking another
generation's bits. Labels and option words come from the configuration
classes the register's `Action`s bind each field to. Checked against `ifdtool`:
CSME 11's FLMAP1 `42100208` reads PSL 0x42 (66 words), FPSBA 0x100, 2 masters
and FMBA 0x80; CSME 12's FLMAP0 `00040003` states FCBA 0x30/FRBA 0x40 and its
FLMAP2 `00340330` the 3-word section at 0x30; CSME 15's `46100208` reads PSL
70 and FLMAP0 `00040003` states FCBA 0x30/FRBA 0x40.

**The SPHY OEM configuration is a nvar of its own.** `phy_oem_cfg`
(`/home/bup/phy_oem_cfg`, FileID 0x1001F200) carries the PHY tuning block in
the FITC partition, and MFIT 18 lays it out as `SphyNvar`:

```bash
python3 Skills/me-eom-structures/scripts/sphy18_map.py ~/Downloads/1/mfit-18.1.exe > \
    Packages/MEFirmware/Sources/MEFirmware/Configuration/SphyNvarMap+CSME18.swift
```

Fields are `offset*8 + bitfield_low … + bitfield_high`; a `ValidByte`/
`EnableBit` takes the byte at `offset`. The package carries four SPHY
documents (522, 542, 967 fields and an API-table variant) and the nvar's
header does not name which one an image used. The script emits the layout the
CSME 18 dump verifies — **522/522** of its constant values read exactly — and
the map states **anchors**: the common header and `Sub_Section_Entry2_Header_8`
(0x5 here, 0x19 in the 542-field variant). The reader refuses an nvar whose
anchors differ, so another variant answers nothing rather than wrong names.
The panel shows the fields under "SPHY OEM configuration".

## Emitting the descriptor's strap layout

The same executables carry the chipset's own layout of the descriptor's PCH
strap section — a `<LayoutEntry>` per field, with the tool's identifier, the
word and bits it takes and the value the tool builds it with — which is what
names the words in the UEFI Structure panel:

```bash
python3 Skills/me-eom-structures/scripts/strap_map.py \
    <fit-15.0.exe> <fit-14.0.exe> --words 69,70,74,90,101,114,115 \
    --format json > Packages/UEFIImage/MapSources/strap/pch.json
```

The JSON is the source of truth and what a review reads; `map_bin.py` compiles
the JSON files into `StrapMaps.bin`. The version lives in
`MapSources/manifest.json` and changes only when the source JSON changes; the
same number is a constant in `StrapMapDataVersion.swift`, and the reader
refuses a binary that carries another (`Design/MAP_DATA.md`):

```bash
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
python3 Skills/me-eom-structures/scripts/map_bin.py build --check …same arguments…
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
The 114- and 115-word tables are the Alder Point S desktop layouts, which FIT
15 carries only as nameless documents; the check that a nameless one is the
section's is a dump of that length — on `LENV_CSME 16.bin` (115 words,
Consumer H) 1084 of the table's 1201 fields read the tool's default, and its
eSPI clock code is 4, 60 MHz.

**FIT 11's SPT documents use their own spelling** — `PchStrap…` without the
underscore, `bitfield_low` written before `bitfield_high`, and whole-word
`dword` entries for the CPM soft straps and the protected range — and the
script reads them too. Their section length comes from the class's own extent
(every bitfield it lays out and its `Group offset` comments), not from the
last named field: the 139-word desktop table ends with words no `PchStrap…`
field reaches, and its document states no field at all for two of them. The
panel shows such a word as its raw value rather than dropping it.

```bash
python3 Skills/me-eom-structures/scripts/strap_map.py ~/Downloads/1/fit-11.exe \
    --words 66,88,90,139 --prefix sptPch --format json > \
    Packages/UEFIImage/MapSources/strap/spt.json
```

The `sptPch` constants are a set of their own: 90 words is a section in both
sets without being the same section, so Sunrise Point and Lewisburg read this
set (only when their generation is certain) and every other generation the
shared tables. The same applies to the processor section's 3 words:

```bash
python3 Skills/me-eom-structures/scripts/strap_map.py ~/Downloads/1/fit-11.exe \
    --kind cpu --words 3 --prefix sptCpu --format json > \
    Packages/UEFIImage/MapSources/strap/sptcpu.json
```

FIT 11's class is `FMSBA` rather than `CpuStrapsLayout`; its word 0 names
Hyperthreading, the active cores, BIST and the flex ratio, where the newer
3-word table has another layout. The fields a length keeps are now those **at
least half** its documents state identically, so a document that names only
part of one word (FIT 11's common file names one word-0 field where the
platform files name six) does not erase the rest.

The CSME 11 dump at hand (Corporate LP) states 66 words and 3 processor words;
its `PCHSTRP0` `0x00100000` reads Deep Sx support set and every other bit
clear — the same word ifdtool prints — and the processor words read
`CpuStrapCpuMaxFreqBoot` 1 (boot at P1) with the rest at the defaults.

`--kind cpu` emits the processor strap section's tables into `cpu.json`
instead:

```bash
python3 Skills/me-eom-structures/scripts/strap_map.py \
    <fit-15.0.exe> <fit-14.0.exe> <fit-12.exe> --kind cpu \
    --words 1,3,7,10,11,14,15,17,18,20,21,22,25 --format json > \
    Packages/UEFIImage/MapSources/strap/cpu.json
```

**`cpu.json` is the one source not regenerated as it stands.** It was
bootstrapped from the generated processor tables of 2026-10-17: the FIT
builds at hand state a different field set for these lengths (the class
selection and the names the newer `CpuStrapsLayout` documents give them
changed), so a rerun today would not reproduce it. Editing it is a JSON diff
by hand; reconciling the generator with it is a separate task. `sptCpu3` is
an ordinary generated table and is not affected.

Their place and length are `FLMAP2`'s — up to Cannon Point, the only
generations whose descriptor carries the section at all. From Tiger Point on
that word names the strap message's place in the PMC's space instead
(`Design/UEFI/UEFI_IMAGE_FORMAT.md` §2.7), and the panel then shows no
processor strap table. **The length is a weaker key here**: documents of one
length lay a field out differently (`Num_Active_Cores` is three bits in
`cnp_lp_rvp.xml`, four in a nameless newer document of the same three words),
so a processor table keeps only the fields every document of that length
states alike — same name, offset and bits — and the script says how many it
dropped. The lengths at hand are 1, 3, 7, 10, 11, 14, 15, 17, 18, 20, 21, 22
and 25 words; the **11-word** section is the LP one `cnp_lp_rvp.xml` names, and
`CSME 13.BIN` (ICP LP) states it — its words at 0x300 decode with Fast wakeup
and PEG_DEF set, SMT enabled and all cores active.

**The generations before FIT's layout documents** — Ibex Peak, Cougar Point
and Lynx Point — have no layout XML inside their Flash Image Tool Classic
builds: that tool keeps its strap map in code, and its executables carry no
`LayoutEntry` documents (fitc-8 names the 6/7-series straps in its UI and
accepts `/ich_straps`, but states no offsets). What does state the map, bit by
bit, is flashrom's `include/ich_descriptors.h`, whose `ibex` and `cougar`
unions were written from Intel's SPI Programming Guides. `intel_strap_map.py`
reads those structs — names, widths and declaration order — into the tables,
and Intel's 7 Series/C216 SPI Programming Guide (document 475653, Appendix A)
is the public check on the `cougar` union: it names the same fields at the
same bits.

**The tool package's `newfiletmpl.xml` is the other half.** The executable
reads it from its directory — it is not embedded, which is why an exe-only
extraction never saw it — and the ME System Tools packages ship it beside
`fitc.exe`. Per `PchStrapN` it states every field's default value, the words
of every option (`value_list`) and the tool's own label, all absent from the
guide. `--template` adds them to the table; the guide keeps the bits. Two
words exist only in the template: **14** (Lynx Point's PCIe/SATA lane modes)
and **19** (Wildcat Point's SATA/USB3 MPHY power controls). Its fields are
listed most significant first, so they pack from the high end of the section
they fill, each as wide as its option list needs — and the dumps read word
14's low 16 bits back as exactly those lane modes on every board examined.

```bash
python3 Skills/me-eom-structures/scripts/intel_strap_map.py \
    --header <flashrom>/include/ich_descriptors.h \
    --kind ibex --generation ibexPeak --words 16 --variable pch16 \
    --format json > Packages/UEFIImage/MapSources/strap/legacy-ibx.json
python3 Skills/me-eom-structures/scripts/intel_strap_map.py \
    --header <flashrom>/include/ich_descriptors.h \
    --template "<tools>/Flash Image Tool/v8.1.40.1456/newfiletmpl.xml" \
    --kind cougar --generation cougarPoint --words 18 --variable pch18 \
    --format json > Packages/UEFIImage/MapSources/strap/legacy-cpt.json
python3 Skills/me-eom-structures/scripts/intel_strap_map.py \
    --header <flashrom>/include/ich_descriptors.h \
    --template "<tools>/Flash Image Tool/WIN32/newfiletmpl.xml" \
    --kind cougar --carried-forward --generation lynxPoint --words 21 \
    --variable pch21 --format json > \
    Packages/UEFIImage/MapSources/strap/legacy-lpt.json
```

The Cougar Point table is emitted from ME System Tools v8 r3's template and
the Lynx Point one from v10.0 r8's, which carries both template-only words
the dumps at hand could show (v9.5 r6 has word 14 but not 19). Ibex Peak's
template (v7 r2) exists too but its table is still the guide's alone.

The sections are **16 words on Ibex Peak, 18 on Cougar Point/Panther Point and
21 on Lynx Point**, and each table is read only on the generation that states
that length — as SPT's are — so an uncertain generation claims nothing. The
7-series guide's fields carry through Panther Point; the tables' option words
(64/128/256 KB boot block, the SMBus frequencies, the PCIe port configurations
and the rest) are the guide's, and the defaults are the tool's.

**Lynx Point's own guide is not public** (Intel document 487990), so `pch21`
is the Cougar Point field set carried forward over the first 18 of the 21
words: the dumps corroborate the shared bits there (`SMB_EN`, `SML1_EN`,
`Deep_SX_EN` and `ICC_PRO_SEL` read where the 7-series layout puts them). The
template adds word 14's lane modes (low 16 bits, checked on eight dumps) and
word 19's two power controls (low bits, clear on every dump); **words 18 and
20 are in neither source and stay raw**. The `cougar` union's `STRP1` adds up
to 37 bits in flashrom — a reserved tail five bits too wide — and the script
trims that tail to the 32 bits a word is. On the dumps at hand `MacBook Pro 15
2010` states 16 words, `ME 7` and `MacBook Pro 15 2011` 18, and `MacBook Air
13` 21.

**The PMC straps are a table too, keyed by what the MIP area leaves.** On
Cannon Point and later, the MIP table's block type 1 is the PMC section
followed by the CPU strap message; the message's length is `FLMAP2`'s (the
processor section's words up to Cannon Point — the same words in the block —
and the message's length from Tiger Point on). What remains is the PMC
section:

```bash
python3 Skills/me-eom-structures/scripts/strap_map.py \
    <fit-15.0.exe> <fit-14.0.exe> <fit-13.0.exe> <fit-12.exe> --kind PMC \
    --words 7,20,21,22 --format json > \
    Packages/UEFIImage/MapSources/strap/pmc.json
```

The lengths at hand are 7 (CNP H and Comet Point), 20 (Ice Lake LP), 21
(Tiger Point) and 22 (Alder Point). On the five dumps at hand the fields read
the tool's default in 95%, 90%, 93%, 92% and 77% of cases — the check that
the split and the table are the section's; the lower Alder Point figure is a
more customised build, not a different layout.

**From Tiger Point on there is no such section: the straps are a message in
the descriptor's MIP area**, at `0xC00` plus the offset `FLMAP2[2:11]` states,
`FLMAP2[16:23]` words long (§2.7 of `Design/UEFI/UEFI_IMAGE_FORMAT.md`).
MFIT lays it out as its `CpuStrapsLayout` class, and that is what this emits —
keyed by message length, with the tool's own labels and option words and with
**no defaults**, because the documents state values per reference platform:

```bash
python3 Skills/me-eom-structures/scripts/mip_strap_map.py <mfit.exe> \
    --format json > Packages/UEFIImage/MapSources/strap/mip.json
```

The panel then reads the message with the table of its length and shows
"Disable Hyperthreading: No" rather than a bit number. 17 and 20 words are
the lengths MFIT 16.1's documents and the dumps at hand state.

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
