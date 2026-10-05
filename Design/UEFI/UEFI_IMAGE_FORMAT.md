# The format of a UEFI firmware image — a description for writing a parser

This document describes the structure of a firmware image conforming to the UEFI
PI, in enough detail to write a parser from scratch. Every structure and
algorithm was checked against the reference implementation UEFITool NE
(`common/ffsparser.cpp`, `common/ffs.h`, `common/descriptor.h`, branch
`new_engine`, version A76).

---

## 0. Conventions

| Property | Value |
|---|---|
| Byte order | little-endian everywhere, without exception |
| Structure packing | tight, `#pragma pack(1)`, no alignment holes |
| Unused space | filled with `emptyByte`: `0xFF` at erase polarity 1, `0x00` at 0 |
| The base GUID type | `EFI_GUID` = `{UINT32 Data1; UINT16 Data2; UINT16 Data3; UINT8 Data4[8];}`, 16 bytes |

Helper operations needed throughout:

```
ALIGN4(x)  = (x + 3)  & ~3
ALIGN8(x)  = (x + 7)  & ~7
ALIGN16(x) = (x + 15) & ~15

uint24ToUint32(p) = p[0] | (p[1] << 8) | (p[2] << 16)

calculateSum8(buf, len)       = the sum of the bytes modulo 256
calculateChecksum8(buf, len)  = (0x100 - calculateSum8(buf, len)) & 0xFF
calculateChecksum16(buf, len) = the same for UINT16, len must be even
```

The "checksum8" is built so that the sum of every byte together with the
checksum field comes out at zero. The same rule holds for the FIT, for FFS files
and for microcode.

### The data model to use

The reference parser builds a tree in which every node holds:

- `type` / `subtype` — what kind of element this is,
- `offset` — the offset relative to the parent,
- `base` — the absolute offset from the start of the image (computed),
- `header`, `body`, `tail` — three non-overlapping slices of bytes,
- `fixed` — a "must not be moved when rebuilding" flag,
- `compressed` — whether the element lies inside a compressed container,
- `parsingData` — housekeeping inherited by children (erase polarity, the FFS
  version, the volume's alignment, the file's GUID).

The split into `header`/`body`/`tail` is fundamental: almost every level of
nesting is "a header plus a body", and the body of the next level down is parsed
recursively. `tail` is used only by FFSv1 files with `FFS_ATTRIB_TAIL_PRESENT`.

Parsing runs in two passes:

1. **The first pass** builds the tree from the root down, purely by offsets.
2. **The second pass** does everything that needs absolute addresses: working
   out `addressDiff`, parsing the reset vector, finding and parsing the FIT,
   checking the Boot Guard protected ranges, checking the bases of TE images.
   The second pass is possible only if a Volume Top File was found and it does
   not lie inside a compressed element.

---

## 1. The top level: what kind of image this is

The algorithm, over the whole input buffer:

```
1. If the start of the buffer is a known capsule signature → strip the capsule
   header and carry on with the body.
2. If FLASH_DESCRIPTOR_SIGNATURE (0x0FF0A55A) sits at offset 0x00 or 0x10
   → this is an Intel image with a flash descriptor.
3. Otherwise → a "generic image": the whole buffer is taken as one raw area
   (the BIOS region) and scanned heuristically (see §4).
```

Offset 0x10 is checked because the first 16 bytes of a descriptor are a
`ReservedVector`, filled with `0xFF` on x86 — while on some ARM images a real
ARM reset vector sits there.

### 1.1. Capsules

```c
typedef struct {
    EFI_GUID CapsuleGuid;
    UINT32   HeaderSize;      // the body begins at this offset
    UINT32   Flags;
    UINT32   CapsuleImageSize;
} EFI_CAPSULE_HEADER;

typedef struct {                 // Toshiba
    EFI_GUID CapsuleGuid;
    UINT32   HeaderSize;
    UINT32   FullSize;
    UINT32   Flags;
} TOSHIBA_CAPSULE_HEADER;

typedef struct {                 // AMI Aptio
    EFI_CAPSULE_HEADER CapsuleHeader;
    UINT16 RomImageOffset;       // from the start of the capsule header to the body
    UINT16 RomLayoutOffset;
} APTIO_CAPSULE_HEADER;
```

The flags: `SETUP = 0x00000001`, `PERSIST_ACROSS_RESET = 0x00010000`,
`POPULATE_SYSTEM_TABLE = 0x00020000`.

The capsule GUIDs that are recognised:

| GUID | Kind |
|---|---|
| `3B6686BD-0D76-4030-B70E-B5519E2FC5A0` | the standard EFI capsule |
| `6DCBD5ED-E82D-4C44-BDA1-7194199AD92A` | the standard FMP capsule |
| `539182B9-ABB5-4391-B69A-E3A943F72FCC` | Intel |
| `E20BAFD3-9914-4F4F-9537-3129E090EB3C` | Lenovo |
| `25B5FE76-8243-4A5C-A9BD-7EE3246198B5` | Lenovo (second) |
| `3BE07062-1D51-45D2-832B-F093257ED461` | Toshiba |
| `4A3CA68B-7723-48FB-803D-578CC1FEC44D` | AMI Aptio signed |
| `14EEBB90-890A-43DB-AED1-5D3C4588A418` | AMI Aptio unsigned |

For a signed Aptio capsule the body's size comes from `RomImageOffset`; between
the header and the body lie a `FW_CERTIFICATE` and `ROM_AREA[]`, which can be
skipped for the purposes of parsing the image. If `CapsuleImageSize` is smaller
than the actual size of the buffer, the tail is rubbish behind the capsule, and
it is worth making a node of its own rather than dropping it silently.

---

## 2. The Intel flash descriptor

The descriptor occupies the first `0x1000` bytes of the image.

```c
typedef struct {
    UINT8  ReservedVector[16];
    UINT32 Signature;            // 0x0FF0A55A
} FLASH_DESCRIPTOR_HEADER;
```

### 2.1. The descriptor map (FLMAP)

Directly behind the header, at offset `0x14`:

```c
typedef struct {
    // FLMAP0
    UINT32 ComponentBase      : 8;   // bits [11:4] of the address
    UINT32 NumberOfFlashChips : 2;   // zero-based
    UINT32                    : 6;
    UINT32 RegionBase         : 8;
    UINT32 NumberOfRegions    : 3;   // reserved in a v2 descriptor
    UINT32                    : 5;
    // FLMAP1
    UINT32 MasterBase         : 8;
    UINT32 NumberOfMasters    : 2;
    UINT32                    : 6;
    UINT32 PchStrapsBase      : 8;
    UINT32 NumberOfPchStraps  : 8;   // one-based, in UINT32s
    // FLMAP2
    UINT32 ProcStrapsBase     : 8;
    UINT32 NumberOfProcStraps : 8;
    UINT32                    : 16;
    // FLMAP3
    UINT32 DescriptorVersion;        // reserved until Coffee Lake
} FLASH_DESCRIPTOR_MAP;
```

**Important:** every `*Base` field holds bits `[11:4]` of a real offset. The real
offset is `Base << 4`. The largest valid base is `0xE0`; anything greater means
a broken descriptor.

`DescriptorVersion` (from Coffee Lake onwards) is read as:

```c
typedef struct {
    UINT32 Reserved : 14;
    UINT32 Minor    : 7;
    UINT32 Major    : 11;
} FLASH_DESCRIPTOR_VERSION;
```

The only known valid version is Major=1, Minor=0. The field does **not** tell
a v1 descriptor from a v2 one: a Skylake board (`CSME 11`) leaves it
`0xFFFFFFFF`, a Cougar Point one (`ME 7`) writes `0x25` there, and Tiger Point
and later write zero. What decides how the rest reads is the chipset
generation, told from the layout (§2.5).

### 2.2. The region section

It lives at `RegionBase << 4`. Every region is a pair of `UINT16` base/limit
values holding **the top 16 bits** of the real 32-bit addresses:

```
offset = Base  << 12
limit  = (Limit << 12) | 0xFFF
size   = limit - offset + 1
```

A region is absent if `Limit == 0` (or if `Base > Limit`).

```c
typedef struct {
    UINT16 DescriptorBase, DescriptorLimit;   // the descriptor itself
    UINT16 BiosBase,       BiosLimit;         // BIOS
    UINT16 MeBase,         MeLimit;           // Management Engine
    UINT16 GbeBase,        GbeLimit;          // Gigabit Ethernet
    UINT16 PdrBase,        PdrLimit;          // Platform Data
    UINT16 DevExp1Base,    DevExp1Limit;      // Device Expansion 1
    UINT16 Bios2Base,      Bios2Limit;        // Secondary BIOS
    UINT16 MicrocodeBase,  MicrocodeLimit;    // CPU microcode
    UINT16 EcBase,         EcLimit;           // Embedded Controller
    UINT16 DevExp2Base,    DevExp2Limit;      // Device Expansion 2
    UINT16 IeBase,         IeLimit;           // Innovation Engine
    UINT16 Tgbe1Base,      Tgbe1Limit;        // 10GbE 1
    UINT16 Tgbe2Base,      Tgbe2Limit;        // 10GbE 2
    UINT16 Reserved1Base,  Reserved1Limit;
    UINT16 Reserved2Base,  Reserved2Limit;
    UINT16 PttBase,        PttLimit;          // Platform Trust Technology
} FLASH_DESCRIPTOR_REGION_SECTION;
```

How many pairs are valid depends on the generation (§2.5): 5 up to Cougar
Point and Bay Trail (Descriptor, BIOS, ME, GbE, PDR), 7 on Lynx and Wildcat
Point, 6 on Apollo and Gemini Lake, 10 on Sunrise Point, all 16 from Cannon
Point on. On an older descriptor the bytes after the fifth pair are the master
section: read as regions they are areas that are not there, which is what
`ME 7` once got thirteen false diagnostics from. A pair of `0xFFFF` / `0xFFFF`
is erased bytes and no region, as UEFITool reads it.

The correct algorithm for parsing an Intel image:

1. Collect the regions that are present as `{offset, length, type}`.
2. Sort them by `offset`.
3. Check for overlaps — overlapping regions mean a broken descriptor.
4. Add the gaps between regions as "padding" elements.
5. Parse each region with its own parser; the BIOS region and Device Expansion 1
   are parsed as raw areas (§4), while ME/GbE/PDR are opaque blobs with a
   version extracted from them.

### 2.3. The masters section

At `MasterBase << 4`. There are two formats — before Skylake and from Skylake
onwards:

```c
typedef struct {                            // v1
    UINT16 BiosId; UINT8 BiosRead, BiosWrite;
    UINT16 MeId;   UINT8 MeRead,   MeWrite;
    UINT16 GbeId;  UINT8 GbeRead,  GbeWrite;
} FLASH_DESCRIPTOR_MASTER_SECTION;

typedef struct {                            // v2, Skylake+
    UINT32 : 8; UINT32 BiosRead : 12; UINT32 BiosWrite : 12;
    UINT32 : 8; UINT32 MeRead   : 12; UINT32 MeWrite   : 12;
    UINT32 : 8; UINT32 GbeRead  : 12; UINT32 GbeWrite  : 12;
    UINT32 : 32;
    UINT32 : 8; UINT32 EcRead   : 12; UINT32 EcWrite   : 12;
} FLASH_DESCRIPTOR_MASTER_SECTION_V2;
```

The access bits in v1: `DESC=0x01, BIOS=0x02, ME=0x04, GBE=0x08, PDR=0x10,
EC=0x20`.

### 2.4. The rest of the descriptor

- `FLASH_DESCRIPTOR_UPPER_MAP` at the fixed offset `0x0EFC`:
  `{UINT8 VsccTableBase; UINT8 VsccTableSize; UINT16 ReservedZero;}`.
  The base is again bits `[11:4]`; the size is in `UINT32`s.
- The VSCC table: an array of `{UINT8 VendorId; UINT8 DeviceId0;
  UINT8 DeviceId1; UINT8 ReservedZero; UINT32 VsccRegisterValue;}`.
- The OEM section: fixed at `0x0F00`, size `0x100`.
- The component section, at `ComponentBase << 4`:
  `{UINT32 FLCOMP; UINT32 FLILL; UINT32 FLPB;}`. `FLCOMP` holds each chip's
  density — three bits a chip up to Cougar Point, four from Lynx Point on;
  `512 KiB << code`, `0xF` for an unused second chip — and the SPI clocks:
  bits 27–29 read ID and status, 24–26 write and erase, 21–23 fast read,
  bit 20 whether fast reads are on. A clock code's meaning is the
  generation's (§2.5). `FLILL` is four opcodes the chipset refuses to send;
  from Sunrise Point on `FLPB` is four more (`FLILL1`), before it the
  partition boundary. How many chips there are is `NumberOfFlashChips + 1`
  from the map. Bits 17–19 are the read clock on older generations and were
  repurposed later (an eSPI clock to ifdtool, a read clock to flashrom), and
  bit 30 is dual output on some generations only: neither is shown.

### 2.5. The chipset generation

Nothing in a descriptor names the generation it was written for, and the
version field does not either (§2.1). It is told from where the descriptor
places its sections and how long it makes them — flashrom's rules for a dump
(`guess_ich_chipset_from_content` in `ich_descriptors.c`), the only
generation-by-generation description at hand:

- `ICCRIBA` (`FLMAP2` bits 16–23) zero: ICH8, ICH9, ICH10 or Ibex Peak by the
  PCH strap length; Apollo or Gemini Lake when `FLMAP2` is zero; Emmitsburg by
  a strap length of `0x50`.
- Otherwise, no MIP table (`FLUMAP1` bits 24–31 zero): with `ICCRIBA < 0x31`
  and `FMSBA < 0x30`, Bay Trail, Cougar Point or Lynx Point by the strap
  lengths; then Lewisburg by six masters, else Sunrise Point.
- Otherwise: Cannon Point by `ICCRIBA == 0x34`; from Tiger Point on, the CPU
  strap length and offset in `FLMAP2` (`CSSL`, `CSSO`) name Tiger Point,
  Alder Point, Elkhart, Jasper, Meteor, Panther, Wildcat and Nova Lake.
  flashrom names Tiger Point by an offset of `0x68`; the Tiger Point H dumps
  at hand (`1.bin`, `2.rom`) write `0x6C`, so ByteRipper takes a length of
  `0x11` for Tiger Point unless the offset is Alder Point's `0x5C`.
- What no rule names is read as Tiger Point and marked assumed, as flashrom
  assumes the 500 series.

Generations sharing a layout are one case: 6 and 7 series, 8 and 9, 100 and
200, 300 and 400, 600 and 700. On the thirteen dumps with a descriptor the
generation agrees with the chipset MEAnalyzer reads from the ME region, the
regions with flashrom's `ich_descriptors_tool` and coreboot's `ifdtool -d`,
and the chip densities with the dump's length — `SPI_ALL_192Mbit` is
8 MB + 16 MB.

### 2.6. The PCH straps

At `PchStrapsBase << 4`, `NumberOfPchStraps` `UINT32`s (`PCHSTRP0`,
`PCHSTRP1`, …): settings the chipset reads for itself at power-on, before any
firmware runs. Their layout is the chipset's and is not published past the
oldest generations. It is not even one layout per generation: the mobile and
desktop parts of one generation make the section different lengths, and put
the same field in different words —

| generation | mobile (LP/P) | desktop (H/S) |
|---|---|---|
| Cannon Point | 69 | 90 |
| Tiger Point | 70 | 101 |
| Alder Point | 70 | 115 |

— so a layout would have to be keyed by generation *and* length.

ByteRipper reads the words as numbers, and as what they mean only where the
meaning is checked: the bit that soft-disables the ME, where ifdtool and
me_cleaner agree on it, and on one layout the eSPI clock and GPR0 (below).

| generations | name | word | bit |
|---|---|---|---|
| ICH8 – ICH10 | `ICH_MeDisable` | `PCHSTRP0` | 0 |
| Ibex Peak – Wildcat Point | `AltMeDisable` | `PCHSTRP10` | 7 |
| Sunrise Point on, Apollo and Gemini Lake, Lewisburg | HAP | `PCHSTRP0` | 16 |

Bay Trail (TXE) and Emmitsburg have none: neither tool names one. On ICH8 –
ICH10 ifdtool also sets two bits in the processor straps; the PCH one is the
one shown.

Two more fields are read on the one layout ifdtool's offsets were checked
against — Tiger and Alder Point mobile, 70 words:

- **The eSPI clock**, bits 3–5 of `PCHSTRP22`: the clock of the eSPI bus to the
  EC. ifdtool's 500-series table: 0 = 20, 1 = 24, 2 = 25, 3 = 48, 4 = 60 MHz;
  any other code is shown as unknown.
- **GPR0**, the whole of `PCHSTRP21`: the GPRD value the SPI controller loads
  its global protected range from — `start : 15, read enable : 1, end : 15,
  write enable : 1`, start and end in 4 KiB units of the flash's linear
  addresses, the end inclusive. With neither enable bit the range is off. A
  range refuses the host whatever the masters' masks allow; coreboot sets it
  over the ME region up to the end of its FITC (`ifdtool --gpr0-enable`).

ifdtool also places GPR0 in word `0x12` on Jasper Lake, `0x40` on Meteor Lake,
`0x76` on Panther Lake and `0x3C` on Nova Lake, with the eSPI clock in words 65
and 119 on Meteor and Panther Lake. No dump at hand checks any of them, so
none is read. On Cannon Point GPR0 is not in the descriptor at all but in the
ME region's FITC.

On the desktop layouts the same words are other fields. On a Tiger Point H dump
(`1.bin`, length 101) word 22 gives an eSPI clock code nobody defines, and on an
Alder Point S one (`SPI_EF4019`, length 115) word 21 gives a "GPR0" of
`0x22222222`. Neither field is shown there until the desktop layouts are known.

On the seven mobile dumps the clock and GPR0 (off on all of them) agree with
ifdtool, and so do the two copies `ifdtool --gpr0-enable` was run on
(`clean_me`: `0x1000 – 0x29BFFF`; `CSME 15`: `0x103000 – 0x31CFFF`, both
writes refused). ifdtool also needs `-p` to read any descriptor
from Sunrise Point on as one: without it, it takes the layout for version 1
and reports `AltMeDisable` from the wrong word.

---

## 3. The firmware volume (FV)

### 3.1. The volume header

```c
typedef struct {
    UINT8    ZeroVector[16];
    EFI_GUID FileSystemGuid;
    UINT64   FvLength;
    UINT32   Signature;        // '_FVH' = 0x4856465F, at offset 0x28
    UINT32   Attributes;
    UINT16   HeaderLength;
    UINT16   Checksum;
    UINT16   ExtHeaderOffset;  // reserved in Revision 1
    UINT8    Reserved;
    UINT8    Revision;         // 1 or 2
    // EFI_FV_BLOCK_MAP_ENTRY FvBlockMap[];
} EFI_FIRMWARE_VOLUME_HEADER;   // 0x38 bytes up to the block map

typedef struct {
    UINT32 NumBlocks;
    UINT32 Length;
} EFI_FV_BLOCK_MAP_ENTRY;       // terminated by a {0, 0} pair
```

The key detail for finding volumes: the `_FVH` signature is at the fixed offset
`EFI_FV_SIGNATURE_OFFSET = 0x28` from the start of the header. The search is for
the signature, and stepping back `0x28` gives the candidate header.

**The checks on a candidate** (all of them required, or there will be false
positives):

- `FvLength >= sizeof(header) + 2 * sizeof(EFI_FV_BLOCK_MAP_ENTRY)` and
  `< 0xFFFFFFFF`;
- `Revision` is 1 or 2;
- `HeaderLength >= sizeof(EFI_FIRMWARE_VOLUME_HEADER)` and `ALIGN8(HeaderLength)`
  does not run past the end of the data;
- the alternative size computed from the block map (`Σ NumBlocks * Length`) is
  compared with `FvLength`; a discrepancy is a sign of damage, but not a reason
  to throw the volume away — the reference parser tries both sizes in that case.

### 3.2. The extended header

If `Revision > 1` and `ExtHeaderOffset != 0`:

```c
typedef struct {
    EFI_GUID FvName;
    UINT32   ExtHeaderSize;
} EFI_FIRMWARE_VOLUME_EXT_HEADER;

typedef struct {                       // a chain of entries inside the ext header
    UINT16 ExtEntrySize;
    UINT16 ExtEntryType;               // 0x0000 = END
} EFI_FIRMWARE_VOLUME_EXT_ENTRY;
```

The entry types: `END = 0x0000`, `OEM_TYPE = 0x0001` (`UINT32 TypeMask` plus
`EFI_GUID Types[]`), `GUID_TYPE = 0x0002` (`EFI_GUID FormatType` plus data).

The resulting size of the volume header:

```
if (Revision > 1 && ExtHeaderOffset)
    headerSize = ExtHeaderOffset + extHeader->ExtHeaderSize;
else
    headerSize = HeaderLength;
headerSize = ALIGN8(headerSize);       // the ext header may end unaligned
```

### 3.3. The header checksum

A `checksum16` over the first `HeaderLength` bytes with the `Checksum` field
zeroed; the result must match the stored value. Note: the sum is taken over
`HeaderLength` and not over `headerSize` — the extended header is not part of
it.

### 3.4. Working out the volume's file system

From `FileSystemGuid`:

| GUID | Meaning |
|---|---|
| `7A9354D9-0468-444A-81CE-0BF617D890DF` | FFSv1 (`EFI_FIRMWARE_FILE_SYSTEM_GUID`) |
| `8C8CE578-8A3D-4F1C-9935-896185C32DD3` | FFSv2 |
| `5473C07A-3DCB-4DCA-BD6F-1E9689E7349A` | FFSv3 |
| `04ADEEAD-61FF-4D31-B6BA-64F8BF901F5A` | Apple immutable FV (FFSv2) |
| `BD001B8C-6A71-487B-A14F-0C2A2DCF7A5D` | Apple authentication FV (FFSv2) |
| `153D2197-29BD-44DC-AC59-887F70E41A6B` | Apple microcode volume, header fixed at `0x100` |
| `E3B980A9-5FE3-48E5-9B92-2798385A9027` | Apple reserved volume (MacBook 2010/2011): a header, then erased bytes; read as free space while erased, otherwise unknown |
| `AD3FFFFF-D28B-44C4-9F13-9EA98A97F9F0` | Intel FS (FFSv2) |
| `D6A1CD70-4B33-4994-A6EA-375F2CCC5437` | Intel FS 2 (FFSv2) |
| `4F494156-AED6-4D64-A537-B8A5557BCEEC` | Sony FS (FFSv2) |
| `372B56DF-CC9F-4817-AB97-0A10A92CEAA5` | HP FS (FFSv2) |
| `FFF12B8D-7696-4C8B-A985-2747075B4F50` | NVRAM main store (VSS) |
| `00504624-8A59-4EEB-BD0F-6B36E96128E0` | NVRAM additional store |

The `FFSv2Volumes` / `FFSv3Volumes` lists in the implementation hold every GUID
treated as the corresponding version of FFS. A volume with an unknown GUID is
not parsed as FFS — its body is kept as opaque data.

The Apple microcode volume's body is a run of microcode images and no FFS
(`walkMicrocodeVolumeBody`): read from the fixed `0x100`, one image after
another, until the rest is all `0x00` or all `0xFF`, or until bytes whose header
does not read as a microcode; the rest is one padding node. That is UEFITool's
`parseMicrocodeVolumeBody`, and on a MacBook dump with two such volumes the
two readings agree node for node.

### 3.5. Attributes and alignment

`EFI_FVB_ERASE_POLARITY = 0x00000800` decides `emptyByte`: set → `0xFF`, clear →
`0x00`. The value is inherited by every child.

The volume's alignment:

- **Revision 1**: the alignment bits `EFI_FVB_ALIGNMENT_2 … _64K` in
  `Attributes[31:16]` are valid only when `EFI_FVB_ALIGNMENT_CAP = 0x00008000`
  is set. In practice nobody keeps them correct, and there is no point checking.
- **Revision 2**: `alignment = 1 << ((Attributes & EFI_FVB2_ALIGNMENT) >> 16)`,
  where `EFI_FVB2_ALIGNMENT = 0x001F0000`. The range runs from `ALIGNMENT_1` (0)
  to `ALIGNMENT_2G` (0x1F). On top of that, `EFI_FVB2_WEAK_ALIGNMENT =
  0x80000000` relaxes the alignment requirement for the files inside. The
  default, where the attributes say nothing, is `0x10000` (64 KiB).

Checking a volume's alignment only makes sense for an uncompressed volume: a
compressed one is unpacked into memory at whatever address the decompressor
picks.

### 3.6. Apple CRC32 and UsedSpace in the ZeroVector

Some vendors use the reserved `ZeroVector`:

- bytes `[8..12)` — a CRC32 of the volume's body (from `HeaderLength` to the
  end). If the value is non-zero and the CRC matches, this is an Apple CRC32;
- bytes `[12..16)` — `UsedSpace`, the offset of the end of the used area from
  the start of the volume. Taken as valid if it matches the free-space boundary
  that was found.

---

## 4. Raw areas and the heuristic search

The BIOS region, Device Expansion, the body of a padding element and a "generic
image" are all parsed the same way: by scanning linearly for known signatures.

The `findNextRawAreaItem` algorithm — byte by byte (not four bytes at a time!),
checking a `UINT32` at the current offset:

```
for offset from start to size-4:
    dword = read_le32(data + offset)

    if dword == 0x00000001:                    // an Intel microcode candidate
        requires restSize >= sizeof(INTEL_MICROCODE_HEADER) (0x30)
        requires intelMicrocodeHeaderValid(header)
        requires TotalSize != 0
        → microcode found, size = TotalSize

    if dword == 0x4856465F ('_FVH'):           // a volume candidate
        requires offset >= 0x28
        check the volume header per §3.1
        compute the alternative size from the block map
        → volume found, size = FvLength, altSize = the block map's sum

    if dword == 0x5F494F5F ('_IO_'), 0x24504324 and so on → other stores
```

Everything between the elements that are found becomes padding. Padding made
entirely of `emptyByte` is marked "empty" — which matters when the image is
rebuilt later.

Raw areas are also searched for NVRAM stores, AMD microcode and BPDT/CPD (see
§7, §8).

Beyond the reference, the scan also takes the start of a picture — `FF D8 FF
E0` or `E1` (JPEG), `89 50 4E 47` (PNG), `GIF8` (GIF), and `BM` (BMP) in the
dword's low half — as a candidate (§9).

---

## 5. FFS files

### 5.1. The headers

```c
typedef union {
    struct { UINT8 Header; UINT8 File; } Checksum;
    UINT16 TailReference;   // Revision 1
    UINT16 Checksum16;      // Revision 2
} EFI_FFS_INTEGRITY_CHECK;

typedef struct {                       // the base header, 0x18 bytes
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // UINT24, the full file size with its header
    UINT8                   State;
} EFI_FFS_FILE_HEADER;

typedef struct {                       // an FFSv3 large file, 0x20 bytes
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // 0xFFFFFF or 0x000000
    UINT8                   State;
    UINT64                  ExtendedSize;
} EFI_FFS_FILE_HEADER2;

typedef struct {                       // a Lenovo large file in FFSv2, 0x1C bytes
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // 0x000000
    UINT8                   State;
    UINT32                  ExtendedSize;
} EFI_FFS_FILE_HEADER2_LENOVO;
```

### 5.2. Working out a file's size

```
if ffsVersion == 2:
    size = uint24(Size)
    if volumeRevision == 2 and (Attributes & FFS_ATTRIB_LARGE_FILE):
        size = header2Lenovo->ExtendedSize      // a non-standard Lenovo extension
if ffsVersion == 3:
    if (Attributes & FFS_ATTRIB_LARGE_FILE):
        size = header2->ExtendedSize
    else:
        size = uint24(Size)
```

`Size` is the **full** size of the file, its header included. A size of `0` means
the volume cannot be parsed any further.

### 5.3. The attributes

```
FFS_ATTRIB_TAIL_PRESENT    0x01   // Revision 1 only
FFS_ATTRIB_RECOVERY        0x02   // Revision 1 only
FFS_ATTRIB_LARGE_FILE      0x01   // FFSv3 only (and Lenovo, in FFSv2 Rev 2)
FFS_ATTRIB_DATA_ALIGNMENT2 0x02   // Revision 2, UEFI PI 1.6+
FFS_ATTRIB_FIXED           0x04
FFS_ATTRIB_DATA_ALIGNMENT  0x38   // 3 bits of an index into the alignment table
FFS_ATTRIB_CHECKSUM        0x40
```

Note the collision: bit `0x01` means `TAIL_PRESENT` in Revision 1 volumes and
`LARGE_FILE` in FFSv3; bit `0x02` means `RECOVERY` or `DATA_ALIGNMENT2`. Which
reading applies depends on the volume's version, not on the file's.

The alignment of a file's body:

```
idx = (Attributes & FFS_ATTRIB_DATA_ALIGNMENT) >> 3;
if (Attributes & FFS_ATTRIB_DATA_ALIGNMENT2) and volumeRevision == 2:
    alignment = 1 << ffsAlignment2Table[idx];   // {17,18,19,20,21,22,23,24}
else:
    alignment = 1 << ffsAlignmentTable[idx];    // {0,4,7,9,10,12,15,16}
```

That is, the base table gives 1, 16, 128, 512, 1K, 4K, 32K and 64K bytes, and
the extended one from 128K to 16M.

### 5.4. The checksums

```
// the header: the sum of every byte of the header, less the two IntegrityCheck
// fields and State
calculatedHeader = 0x100 - (sum8(header) - IC.Checksum.Header
                                          - IC.Checksum.File
                                          - State);

// the body
if (Attributes & FFS_ATTRIB_CHECKSUM):
    calculatedData = checksum8(body)          // with an empty body this is a format error
else if volumeRevision == 1:
    calculatedData = FFS_FIXED_CHECKSUM  = 0x5A
else:
    calculatedData = FFS_FIXED_CHECKSUM2 = 0xAA
```

The body is only checked for files with a non-empty body.

### 5.5. The file's state

```
EFI_FILE_HEADER_CONSTRUCTION 0x01
EFI_FILE_HEADER_VALID        0x02
EFI_FILE_DATA_VALID          0x04
EFI_FILE_MARKED_FOR_UPDATE   0x08
EFI_FILE_DELETED             0x10
EFI_FILE_HEADER_INVALID      0x20
EFI_FILE_ERASE_POLARITY      0x80
```

The state bits are written in ascending order and are stored **inverted**
when the erase polarity is 1: a bit is set by clearing it, so a file with its
header and data valid stores `0xF8`. A file's `emptyByte` comes from its own
`State & EFI_FILE_ERASE_POLARITY` rather than from the volume — which is what
makes mixed cases readable.

A file whose state marks its header invalid — `HEADER_INVALID` set, or
`HEADER_VALID` not set — under the volume's erase polarity **and** under its
own polarity bit owes no checksum: the firmware does not take it. ByteRipper
reports it once as `fileHeaderMarkedInvalid`, with its state, and checks
neither sum; the panel shows them as not checked and offers no repair
(`FileState.marksHeaderInvalid`). This departs from the reference, which checks
the sums of every file. The one such file at hand is HP's `AAF32C78-…` in the
"HP FS" volume of `SPI_EF4019_256Mbit`: state `0x00` in a polarity 1 volume,
every bit written, body four zero bytes, and two stale sums that UEFIExtract
reports too. Invalid under one reading only is a file written under the other
polarity, and is checked: `1.bin`'s `D6078613-…` stores `0x07` in a polarity 1
volume — valid under its own bit — and keeps its body checksum warning.

### 5.6. File types

```
0x00 ALL (not allowed in an image)   0x0B FIRMWARE_VOLUME_IMAGE
0x01 RAW                              0x0C COMBINED_MM_DXE
0x02 FREEFORM                         0x0D MM_CORE
0x03 SECURITY_CORE                    0x0E MM_STANDALONE
0x04 PEI_CORE                         0x0F MM_CORE_STANDALONE
0x05 DXE_CORE                         0xC0..0xDF OEM
0x06 PEIM                             0xE0..0xEF DEBUG
0x07 DRIVER                           0xF0 PAD
0x08 COMBINED_PEIM_DRIVER             0xF0..0xFF FFS-specific
0x09 APPLICATION
0x0A MM (formerly SMM)
```

A type greater than `0x0F` and not equal to `0xF0` should be treated as unknown.

### 5.7. Special files

| GUID | Meaning |
|---|---|
| `1BA0062E-C779-4582-8566-336AE8F78F09` | **Volume Top File (VTF)** |
| `D6A2CB7F-6A18-4E2F-B43B-9920A733700A` | EDK2 DXE Core |
| `5AE3F37E-4EAE-41AE-8240-35465B5E81EB` | AMI DXE Core |
| `1B45CC0A-156A-428A-AF62-49864DA0E6E6` | PEI apriori |
| `FC510EE7-FFDC-11D4-BD41-0080C73C8881` | DXE apriori |
| `E4536585-7909-4A60-B5C6-ECDEA6EBFB54` | AMI padding file |
| `389CC6F2-1EA8-467B-AB8A-78E769AE2A15` | Phoenix vendor hash file |
| `CBC91F44-A4BC-4A5B-8696-703451D0B053` | AMI vendor hash file |
| `20BC8AC9-94D1-4208-AB28-5D673FD73487` | AMD compressed raw file |
| `DE3E049C-A218-4891-8658-5FC0FA84C788` | AMD microcode in TE/PE |
| `05CA01FC-…` … `05CA020B-…` | AMI ROM Hole 0..15 |

**The Volume Top File is critical.** The last byte of the last VTF in the image
is mapped at the physical address `0xFFFFFFFF`. From which:

```
addressDiff = 0xFFFFFFFF - base(lastVtf) - fullSize(lastVtf) + 1
physical_address = file_offset + addressDiff
```

Without a VTF the absolute addresses cannot be worked out at all, and the whole
second pass (FIT, reset vector, protected ranges) is skipped. The default value
`addressDiff = 0x100000000` means "the addresses are unknown".

Inside the VTF, at fixed addresses, lies the reset vector:

```c
typedef struct {
    UINT8  ApEntryVector[8];   // 0xFFFFFFD0
    UINT8  Reserved0[8];
    UINT32 PeiCoreEntryPoint;  // 0xFFFFFFE0
    UINT8  Reserved1[12];
    UINT8  ResetVector[8];     // 0xFFFFFFF0
    UINT32 ApStartupSegment;   // 0xFFFFFFF8
    UINT32 BootFvBaseAddress;  // 0xFFFFFFFC
} X86_RESET_VECTOR_DATA;
```

The value `0x12345678` in these fields means "not filled in" (EDK2 leaves a
placeholder).

**A raw file's body** (type `0x01`, and `0x00`, which is never a real type
and is read the same way) follows UEFITool's `parseFileBody`. After the NVAR
store files: an AMI ROM hole (`05CA01FC-0FC1-11DC-9011-00173153EBA8` up to
`05CA020B-…`) stays whole and is fixed; a Phoenix hash file is left to the
protected ranges; anything else is probed, quietly, as a run of sections —
each section's size at least a header and within the body, its type's own
header there (5 bytes for compression, 20 for GUID-defined, 16 for freeform,
2 for version, 4 for a postcode), a GUID-defined section's `DataOffset` within
it, the next one four-aligned, unknown types allowed — and walked as sections
when it reads as them. Otherwise the body is a raw area (§4), which finds the
microcode of the store the FIT points into, volumes and the rest; a raw area
that finds nothing leaves the file a leaf, as the reference leaves it. On the
Lenovo dump with 22 raw files, every one has the children UEFIExtract gives it.

**A pad file's body** (type `0xF0`) is read the way UEFITool's
`parsePadFileBody` reads it. All erase byte: nothing. Otherwise the erased
bytes up to the first written one are free space — rounded down to a multiple
of eight, and only when there are at least eight — and the rest is one node:
the **Startup AP data** when it opens with EDK2's
`RECOVERY_STARTUP_AP_DATA_X86_128K` (`EA D0 FF 00 F0`, `jmp far F000:FFD0`,
then zeros and `27 2D`), which GenFv writes into the pad file in front of the
VTF and which is fixed; anything else is **Non-UEFI data**, reported as a
warning. The file is then shown as a Startup AP data or a non-empty padding
file. On the Lenovo dumps at hand the data in two such pad files is a Boot
Guard key manifest (`__KEYM__`), which UEFITool reports the same way.

### 5.8. Walking a volume's body

```
fileOffset = 0
while fileOffset < the size of the volume's body:
    fileSize = getFileSize(...)
    if fileSize == 0 → stop parsing

    if the first sizeof(EFI_FFS_FILE_HEADER) bytes are all emptyByte:
        // free space has been reached
        if the rest is not entirely emptyByte:
            find the first non-empty byte i
            align i down to 8: if i != ALIGN8(i) → i = ALIGN8(i) - 8
            [0, i)  → free space
            [i, …)  → "non-UEFI data", parse heuristically
        else:
            the whole rest → free space
        stop

    if what is left is not enough for the header or for fileSize:
        the rest → non-UEFI data, stop

    parse the file
    fileOffset = ALIGN8(fileOffset + fileSize)
```

The next file is always aligned to 8 bytes, whatever the version of FFS.

A header whose size is more than the volume has left is not a file cut short
but the start of data of some other kind: the rest of the volume is one
`nonUEFIData` node, searched as non-UEFI data always is, with one
`nonUEFIDataInVolume` warning (`walkVolumeBody`, through
`declaredFileSize`). Until 2026-10-05 the parser read such a header as a file
anyway — on `W25Q256JV.orig.bin` a "file" of type `0x46` at `0x1B01580` with a
truncated body, two checksum mismatches and an unknown type; UEFIExtract makes
`0x1B01580`–`0x1D10000` non-UEFI data, and so does the parser now.

---

## 6. Sections

The body of a file of any type other than `RAW` and `PAD` is a sequence of
sections.

```c
typedef struct {
    UINT8 Size[3];             // UINT24, the full size of the section with its header
    UINT8 Type;
} EFI_COMMON_SECTION_HEADER;   // 4 bytes

typedef struct {
    UINT8  Size[3];            // == 0xFFFFFF, the marker for the extended header
    UINT8  Type;
    UINT32 ExtendedSize;
} EFI_COMMON_SECTION_HEADER2;  // 8 bytes
```

The extended header applies only in FFSv3 volumes: `Size == EFI_SECTION2_IS_USED
(0xFFFFFF)` → read `ExtendedSize`.

Sections inside a file are aligned to 4 bytes (`ALIGN4`).

A section whose size is zero, smaller than its header, or more than the body
has left ends the walk: the rest of the body is one padding node named
`Non-UEFI data`, with one `nonUEFIDataInSections` warning — the reference's
"non-UEFI data found in sections area". Until 2026-10-05 the parser kept such a
section, cut to the body, with `truncated(.sectionBody)` and whatever its type
byte said (`zeroSize` and `sizeMismatch` stopped the walk with no node at
all). On the thirty dumps at hand this happens five times, every one where
UEFIExtract says it: on `Asus/SPI_C86018_128Mbit_GD25LB128DW.bin`,
`CSME 16.1.bin` and `orig_30072026.BIN` the body is a WAV (§9) whose `RIFF`
read as a section of type `0x46`; on `DELL Optiplex 5070 Working.bin` a section
two bytes long.

### 6.1. Section types

**Encapsulating** (they hold other sections):

| Type | Name |
|---|---|
| `0x01` | `COMPRESSION` |
| `0x02` | `GUID_DEFINED` |
| `0x03` | `DISPOSABLE` |

**Leaf**:

| Type | Name | Type | Name |
|---|---|---|---|
| `0x10` | `PE32` | `0x17` | `FIRMWARE_VOLUME_IMAGE` |
| `0x11` | `PIC` | `0x18` | `FREEFORM_SUBTYPE_GUID` |
| `0x12` | `TE` | `0x19` | `RAW` |
| `0x13` | `DXE_DEPEX` | `0x1B` | `PEI_DEPEX` |
| `0x14` | `VERSION` | `0x1C` | `MM_DEPEX` |
| `0x15` | `USER_INTERFACE` | `0x20` | Insyde postcode (vendor) |
| `0x16` | `COMPATIBILITY16` | `0xF0` | Phoenix SCT postcode (vendor) |

### 6.2. The compression section (0x01)

```c
typedef struct {
    UINT32 UncompressedLength;
    UINT8  CompressionType;
} EFI_COMPRESSION_SECTION;
```

`CompressionType`: `0x00` — not compressed, `0x01` — Tiano/EFI 1.1 (the
EfiTianoDecompress algorithm), `0x02` — customized, `0x86` — LZMA with an x86
filter.

For type `0x01` both variants have to be tried — EFI 1.1 and Tiano: they differ
only in the width of a field and are told apart by which decompression succeeds.

### 6.3. The GUID-defined section (0x02)

```c
typedef struct {
    EFI_GUID SectionDefinitionGuid;
    UINT16   DataOffset;       // from the start of the section to the data
    UINT16   Attributes;
} EFI_GUID_DEFINED_SECTION;
```

The attributes: `PROCESSING_REQUIRED = 0x01`, `AUTH_STATUS_VALID = 0x02`.

The known GUIDs:

| GUID | Processing |
|---|---|
| `FC1BCDB0-7D31-49AA-936A-A4600D9DD083` | CRC32 (the data is not compressed, only checked) |
| `A31280AD-481E-41B6-95E8-127F4C984779` | Tiano |
| `EE4E5898-3914-4259-9D6E-DC7BD79403CF` | LZMA |
| `0ED85E23-F253-413F-A03C-901987B04397` | LZMA (HP) |
| `BD9921EA-ED91-404A-8B2F-B4D724747C8C` | LZMA (Microsoft) |
| `D42AE6BD-1352-4BFB-909A-CA72A6EAE889` | LZMA + x86 filter |
| `1D301FE9-BE79-4353-91C2-D23BC959AE0C` | GZip |
| `CE3233F5-2CD6-4D87-9152-4A238BB6D1C4` | Zlib (AMD) |
| `991EFAC0-E260-416B-A4B8-3B153072B804` | Zlib (AMD, second) |
| `3D532050-5CDA-4FD0-879E-0F7F630D5AFB` | Brotli |
| `0F9D89E8-9259-4F76-A5AF-0C89E34023DF` | Firmware contents signed |

The headers of the particular packers:

```c
typedef struct {                   // AMD Zlib
    UINT8  ZeroHeader[0x14];
    UINT32 CompressedSize;
    UINT8  ZeroFooter[0x100 - 4 - 0x14];
} EFI_AMD_ZLIB_SECTION_HEADER;

typedef struct {                   // Brotli
    UINT64 DecompressedSize;
    UINT64 ScratchBufferSize;
} EFI_BROTLI_SECTION_HEADER;
```

For signed sections (`FIRMWARE_CONTENTS_SIGNED`) the data is preceded by a
`WIN_CERTIFICATE_UEFI_GUID`:

```c
typedef struct { UINT32 Length; UINT16 Revision; UINT16 CertificateType; } WIN_CERTIFICATE;
typedef struct { WIN_CERTIFICATE Header; EFI_GUID CertType; } WIN_CERTIFICATE_UEFI_GUID;
typedef struct { EFI_GUID HashType; UINT8 PublicKey[256]; UINT8 Signature[256]; }
        EFI_CERT_BLOCK_RSA2048_SHA256;
```

`WIN_CERT_TYPE_EFI_GUID = 0x0EF1`, and `CertType` for RSA2048/SHA256 is
`A7717414-C616-4977-9420-844712A735BF`.

### 6.4. The other sections

```c
typedef struct { UINT16 BuildNumber; } EFI_VERSION_SECTION;        // then a UCS-2 string
typedef struct { EFI_GUID SubTypeGuid; } EFI_FREEFORM_SUBTYPE_GUID_SECTION;
typedef struct { UINT32 Postcode; } POSTCODE_SECTION;
```

`USER_INTERFACE` (0x15) — the body is entirely a UCS-2 string with a terminating
zero.

A `FIRMWARE_VOLUME_IMAGE` section (0x17) holds a nested volume — recursion back
to §3.

### 6.5. Depex sections

The body is bytecode of one-byte opcodes:

```
0x00 BEFORE (DXE only, first and only)
0x01 AFTER  (DXE only, first and only)
0x02 PUSH   + EFI_GUID (a 16-byte operand)
0x03 AND    0x04 OR     0x05 NOT
0x06 TRUE   0x07 FALSE  0x08 END
0x09 SOR    (DXE only, the first opcode)
```

---

## 7. Microcode

### 7.1. Intel

```c
typedef struct {
    UINT32 HeaderType;         // 1
    UINT32 UpdateRevision;
    UINT16 DateYear;           // BCD
    UINT8  DateDay;            // BCD
    UINT8  DateMonth;          // BCD
    UINT32 ProcessorSignature;
    UINT32 Checksum;           // the sum of every DWORD of the image == 0
    UINT32 LoaderRevision;     // 1
    UINT32 PlatformIds;
    UINT32 DataSize;           // 0 means 2000 bytes
    UINT32 TotalSize;
    UINT32 MetadataSize;       // reserved
    UINT32 UpdateRevisionMin;
    UINT32 Reserved;
} INTEL_MICROCODE_HEADER;      // 0x30 bytes
```

The validity criteria (`intelMicrocodeHeaderValid`) — all of them required:

- `DataSize % 4 == 0` and `DataSize <= 0xFFFFFF`;
- `TotalSize >= DataSize` and `TotalSize <= 0xFFFFFF`;
- `DateDay` — valid BCD in the ranges `01–09, 10–19, 20–29, 30–31`;
- `DateMonth` — valid BCD `01–09, 10–12`;
- `DateYear` — BCD in `1990–1999, 2000–2009, 2010–2019, 2020–2029, 2030–2039,
  2040–2049`;
- `HeaderType == 1`;
- `LoaderRevision == 1`.

When scanning, `TotalSize != 0` is required as well.

The extended signature table, if `TotalSize > 0x30 + DataSize`:

```c
typedef struct { UINT32 EntryCount; UINT32 Checksum; UINT8 Reserved[12]; }
        INTEL_MICROCODE_EXTENDED_HEADER;
typedef struct { UINT32 ProcessorSignature; UINT32 PlatformIds; UINT32 Checksum; }
        INTEL_MICROCODE_EXTENDED_HEADER_ENTRY;
```

An empty microcode slot has `FF FF FF FF` as its first 4 bytes. This is a legal
state: the FIT specification explicitly allows entries that point at empty slots.

### 7.2. AMD

Parsed separately (`amd_microcode.h`); the search runs both over raw areas and
inside TE/PE files with the GUID `DE3E049C-A218-4891-8658-5FC0FA84C788`.

```c
typedef struct {
    UINT16 DateYear;            // BCD: 0x2023
    UINT8  DateDay;             // BCD
    UINT8  DateMonth;           // BCD
    UINT32 UpdateRevision;
    UINT16 LoaderID;            // 0x80xx
    UINT8  DataSize;
    UINT8  InitializationFlag;
    UINT32 DataChecksum;
    UINT16 NorthBridgeVEN_ID;   // 0 or 0x1022
    UINT16 NorthBridgeDEV_ID;
    UINT16 SouthBridgeVEN_ID;   // 0 or 0x1022
    UINT16 SouthBridgeDEV_ID;
    UINT16 ProcessorSignature;  // 0xA500 → CPUID 00A50F00
    UINT8  NorthBridgeREV_ID;
    UINT8  SouthBridgeREV_ID;
    UINT8  BiosApiRevision;     // 0 or 1
    UINT8  LoadControl;         // up to 0x0F, or 0xAA
    UINT8  Reserved[2];
} AMD_MICROCODE_HEADER;         // 0x20 bytes
```

No signature: a header is one when every field is a value AMD writes — the
date BCD (day 01–31, month 01–12, year 2001–2029), `LoaderID >> 8 == 0x80`, both
vendor ids `0` or `0x1022`, `BiosApiRevision` 0 or 1, `LoadControl` at most
`0x0F` or `0xAA` — and in a raw area, as the reference wants, `0x44` more bytes
follow with the dword at `0x40` not zero. The data size is `DataSize` for a
loader below `0x8005` and `(InitializationFlag << 8 | DataSize) * 0x10` from
it; `0x20` makes a patch of `0x3C0`, `0x10` one of `0x200`, any other non-zero
size is the length. At zero only the family says it — the CPUID's high byte:
`0x50` `0x620`, `0x58` `0x567`, `0x60`–`0x67` `0xA20`, `0x68`–`0x69` `0x980`,
`0x70`/`0x73` `0xD60`, `0x80`–`0x83` and `0x85`–`0x8A` `0xC80`, `0xA0`–`0xA7`
and `0xAA` `0x15C0`, `0xB4` `0x3820`; a family not in the table is no patch.
Three patches AMD dated wrongly are read with the reference's correction
(`00800F11`/`08001105` year 2016 → 2017, `00300F10`/`03000027` month 13 → 12,
`00730F01`/`07030106` 09-02 → 02-09).

**Implemented** (`AMDMicrocode.swift`): the raw-area half. Every stretch of
padding the scan left, and every Insyde map region and padding row read into
one, is searched byte by byte — the loader's high byte the first test — and
each patch found becomes an `amdMicrocode` node inside it, the stretch keeping
its place, range and name as for every structure read out of padding (§9). The
node is fixed, named `AMD microcode <CPUID>, revision <rev>`, and classified as
UEFITool's `AmdMicrocode` (`0x69`). Beyond the reference, which has no regions,
a patch in a map region is found: on `SPI_EF6018_128Mbit.*` the one patch lies
in the region the map calls `Unknown`, `0x53F000`–`0x5AA000`, which opens on
the PSP's `$BL2` directory.

Checked on 2026-10-05: seven patches on the three AMD boards at hand, each at
the offset and of the size UEFIExtract gives, and none on the other
twenty-seven dumps — `0x565C00` (`00A50F00`, `0x15C0`) on the Lenovo board,
`0x2B6500`, `0x2B7200`, `0x2B7F00` (`00810F81`, `00810F80`, `00820F01`,
`0xC80` each) on `W25Q64JW-IQ.orig.bin`, `0x676C00`, `0x88BC00`, `0x88C900`
(`00A50F00`, `00860F81`, `00860F01`) on the Asus board. Each is an entry of
type `0x66` in the PSP's BIOS level-2 directory, whose size is the table's.
**Not implemented**: the search inside TE/PE files of the `DE3E049C-…` file —
no dump at hand has one, the decompressed volumes included.

---

## 8. IFWI: BPDT and CPD

Applies to images with a Converged Security Engine (Apollo Lake and newer).

```c
#define BPDT_GREEN_SIGNATURE  0x000055AA
#define BPDT_YELLOW_SIGNATURE 0x00AA55AA

typedef struct {
    UINT32 Signature;
    UINT16 NumEntries;
    UINT8  HeaderVersion;      // 1 or 2
    UINT8  RedundancyFlag;     // reserved in version 1
    UINT32 Checksum;
    UINT32 IfwiVersion;
    UINT16 FitcMajor, FitcMinor, FitcHotfix, FitcBuild;
} BPDT_HEADER;

typedef struct {
    UINT32 Type : 16;
    UINT32 SplitSubPartitionFirstPart  : 1;
    UINT32 SplitSubPartitionSecondPart : 1;
    UINT32 CodeSubPartition            : 1;
    UINT32 UmaCacheable                : 1;
    UINT32 Reserved : 12;
    UINT32 Offset;
    UINT32 Size;
} BPDT_ENTRY;
```

The partition types: `0 SMIP, 1 RBEP, 2 FTPR, 3 UCOD, 4 IBBP, 5 S_BPDT, 6 OBBP,
7 NFTP, 8 ISHC, 9 DLMP, 10 UEBP, 11 UTOK, 14 PMCP, 17 UEP, 18 WCOD, 19 LOCL,
20 OEMP, 21 FITC, 32 PCHC` and onwards (the full list is in `ffs.h`).

Type `5 (S_BPDT)` is a nested BPDT and is parsed recursively.

```c
#define CPD_SIGNATURE 0x44504324   // "$CPD"

typedef struct {                   // rev 1
    UINT32 Signature; UINT32 NumEntries;
    UINT8 HeaderVersion;           // 1
    UINT8 EntryVersion; UINT8 HeaderLength; UINT8 HeaderChecksum;
    UINT8 ShortName[4];
} CPD_REV1_HEADER;

typedef struct {                   // rev 2
    UINT32 Signature; UINT32 NumEntries;
    UINT8 HeaderVersion;           // 2
    UINT8 EntryVersion; UINT8 HeaderLength; UINT8 Reserved;
    UINT8 ShortName[4]; UINT32 Checksum;
} CPD_REV2_HEADER;

typedef struct {
    UINT8 EntryName[12];
    struct { UINT32 Offset : 25; UINT32 HuffmanCompressed : 1; UINT32 Reserved : 6; } Offset;
    UINT32 Length;
    UINT32 Reserved;
} CPD_ENTRY;
```

Inside the CPD partitions lie manifests (`CPD_MANIFEST_HEADER`) and extensions
(`CPD_EXTENTION_HEADER {UINT32 Type; UINT32 Length;}`) — around 40 types, of
which the practically important ones are `15 SIGNED_PACKAGE_INFO`,
`10 MODULE_ATTRIBUTES` (which carries `CompressionType`: 0 — none, 1 — Huffman,
2 — LZMA), `19 BOOT_POLICY`, `14 KEY_MANIFEST`, `22 IFWI_PARTITION_MANIFEST`.

---

## 9. NVRAM

Variable stores are found by searching heuristically for signatures inside raw
areas and volumes with an NVRAM GUID. The formats supported (the details are in
`common/nvram.h` and the kaitai descriptions in `common/ksy/`):

| Format | Signature / marker |
|---|---|
| EDK2 VSS / VSS2 | `$VSS` / a GUID header |
| EDK2 FTW | `EFI_FAULT_TOLERANT_WORKING_BLOCK_HEADER` |
| AMI NVAR | `NVAR` |
| Apple SYSF/Fsys | `Fsys` / `Gaid` |
| Phoenix EVSA | `EVSA` |
| Phoenix FlashMap | `_FLASH_MAP` |
| Insyde FDC / FDM | `$FDC` / `HFDM` (0x4D444648) |
| Dell DVAR | `DVAR` (0x52415644) |
| MS SLIC | a marker / a public key |

For a general-purpose parser it is sensible to pick NVRAM stores out as opaque
elements first and parse them on demand.

**AMI NVAR** is not found by a signature search but by where it lives
(`NvarParser.swift`): the body of a raw file with the store GUID
(`CEF5B9A3-…`), the PEI defaults GUID (`77D3DC50-…`) or the BB defaults GUID
(`AF516361-…`); the raw section of the external defaults file (`9221315B-…`);
and any other raw section whose body opens `NVAR`, tried quietly. The store has
no header: entries back to back, free space, and a GUID table at the end whose
length is the highest index an entry names. Entries sit directly under the file
or section, with the header, data and extended header as `header`, `body` and
`tail`. Two departures from the reference: an entry that does not read keeps
the entries before it and turns the rest into padding, where the reference
drops the whole store; and a data-only entry looks for its chain among all the
entries before it, including the first, which the reference's backward loop
skips.

**Dell DVAR** is an element of the raw-area scan (`DvarParser.swift`): `DVAR`,
then a size and a flags byte, each stored as its complement (`0xFFFFFFFF - n`,
`0xFF - n`) like every field after it. A candidate is a store only when its size
fits what is left and its entries read to the end; anything less leaves no
node and no diagnostic, since the four bytes turn up in Dell's own code — four
times on the dump at hand, in two drivers and their Top Swap copies. Entries
follow back to back until one opens on `0xFF`: state, flags, type, attributes
and a namespace id; the namespace's GUID when the flags declare one
(`NameId | NamespaceGuid`, `0x06`); the name id and data size, 8 or 16 bits
each by the type (`0x00`, `0x04`, `0x05`); the data. A NameId entry takes its
namespace's GUID from whichever entry declared that id first, anywhere in the
store, and is `Invalid` unless stored (`0x05`); a declaration is shown valid
whatever its state, as the reference does, though the value it carries is
superseded like any other — `NvramStoreFill` and `NvramVariableHistory` go by
the state alone. An entry of an unknown state, flags or type ends the walk: the
rest is padding and `unknownDvarEntry`; a namespace no entry declares is
`dvarNamespaceMissing`. A row is named by its name id, `0x40`, or by what Setup
calls it (below), then ` = ` and its value up to eight bytes, little-endian, or a longer one's
size in parentheses. On the two
Dell dumps with stores — one store of `0x1F000` in the BIOS region's raw area,
two of `0x7000` in a volume's non-UEFI data — every store and entry matches
UEFIExtract by offset, size and subtype: 3 304 and 1 916 rows.

**What Setup calls a DVAR variable** (`DellSetupForms.swift`) is read from the
firmware's own HII, which UEFIExtract does not do. Dell's Setup driver
(`DellSetupFormSets`) carries its pages as EDK2 compiles them: each form
package, and the run of string packages, behind a 32-bit length. A string
package is found by its header — type `0x04`, `HdrSize == StringInfoOffset`, a
printable language tag — and kept only when its blocks read to an end block; a
form package by type `0x02` opening on `EFI_IFR_FORM_SET_OP`, kept only when
its opcodes run exactly to its end with every scope closed. Each question kept
in DVAR is followed, at its own level and right after its scope closes, by
`EFI_IFR_GUID_OP` with Dell's GUID `A5D58BCF-EB5C-44FC-9122-CA4369B9ABE6`,
subtype `0x1D`, then the namespace's GUID and a 32-bit name id; any other
opcode in between unties it (the other subtypes, `0x19`–`0x20`, are not read).
The prompt, help, page title and option texts come from `en-US`; the
`x-UEFI` strings, at the same ids, are the keywords — the attribute names of
Dell's configuration tools — and name the row, less a `[SuppressIf:…]`
condition some carry. `LazyUEFITree.resolveDvarSettings` reads them over a
copy of the tree like the protected ranges: every volume's files first, and the
compressed sections only when a DVAR store turned up, since the driver sits in
the LZMA DXE volume. On the dump with the `0x1F000` store: 17 form packages,
263 questions tied, 110 of the 225 current variables named — the rest are in
namespaces no page asks about (time stamps, counters, an event log). Every
checkbox's value is 0 or 1 and every list's value is one of its options. The
other dump's DXE volume does not decode, for UEFIExtract either, so it has no
names.

**Phoenix EVSA.** The store's signature is the bytes `EVSA`,
`NVRAM_EVSA_STORE_SIGNATURE = 0x41535645` read little-endian. Besides the
NVRAM volume, Phoenix keeps an EVSA store — the Secure Boot defaults among
others — in the raw section of a file with the GUID
`FFS_PHOENIX_RAW_SECTION_EVSA_GUID` (`DAB78572-…`), whose body reads as an
NVRAM volume's does. On a Lenovo dump with both, the 30 entries read as
UEFIExtract reads them.

**A `$VSS` store with no size** is measured rather than refused, beyond the
reference. Insyde leaves the size field of the board's live variable store at
`0xFFFFFFFF`, the "no size" marker — the flash device map's `Variables` region
says how big it is — and UEFITool, refusing the marker, shows the store as
padding. Outside an FDC (where the FDC's body gives the size), a plain `$VSS`
store with the marker that opens on a variable is read by its own structure:
variables while the `0x55AA` marker holds, then the erase byte, and the store
ends where the erased run does, or at the body's end. On the one Lenovo dump
with such a store this lands exactly on the `Variables` region's end, where the
FTW store begins. A store whose variables are damaged has nothing but that run
to bound it, where a sized store has its size; an Apple `$SVS` / `$NSS` store
with the marker is still refused.

**The regions of an Insyde flash device map** are read beyond the reference
(`FlashDeviceMapParser.swift`). The map lays out the whole image, and several of
the ranges it names sit outside every volume with no signature of their own —
the EC firmware, the BIOS version table, the SMBIOS update, the MSDM table,
Lenovo's EEPROM and password regions, the default variables — so UEFITool
shows them as padding. When a raw-area scan finds a flash device map, each range
one of its entries names that lies wholly inside a stretch of padding the same
scan left becomes a `flashDeviceMapRegion` node, named by its region type the
way UEFITool names the entries, fixed, as a row inside that padding
(`Parser.placingInPadding`): the padding keeps its place, range and name —
it is what the structures around it make it — and the bytes between the
regions are padding rows beside them. Erased padding with rows in it is
listed even when empty padding is not. A range
that is already something else — a volume, the NVRAM volume's stores, the map
itself — is left to what read it. Entries are placed in address order, so of
two that overlap the first is placed and the other stays out; a board that
carries the map twice names each range once. The map's addresses are placed
with `FdBaseAddress + RegionOffset − addressDiff` — the arithmetic of the
protected ranges — and since the second pass has not run yet, `addressDiff`
comes from a Volume Top File at the image's tail; with none there, the ranges
stay padding. The tail is the BIOS region's end when the image opens on a
descriptor, and the file's otherwise (`Parser.addressSpaceTop`): a
programmer can append bytes of its own — `0xC00` erased bytes after
`Original_Bios_25.05.2025.bin`, `0x110` of a footer after `orig_30072026.BIN`
— and those are no part of the address space. On an AMD board the flash ends in no
VTF at all — the PSP loads the BIOS — and each map is then placed by its own
entry of type `FLASH_MAP` (`F078C1A0-…`): that entry's address less the
store's offset, taken only when it is a whole number of 4 KiB blocks, since a
copy of the map inside a file keeps the original's entries
(`FlashDeviceMap.addressDiff(of:reader:)`). On `SPI_EF6018_128Mbit.*` that
places the EC Firmware regions at `0x0` (`0x200` bytes, which hold
`0x21000`, `0x31000` and `0x3D000` among other words), `0x200` (a `PHCM`
image) and `0x21000` (an `ITE8380` in a 192 KiB slot), and the Lenovo
regions. The board has two controllers sharing the flash, both ITE's: the EC
and an IT8176FN-56A keyboard controller (from the bench, not from the
images). The `PHCM` image is ARM Thumb code built from `md_i2c.c`,
`dev_pca9557.c`, `f_smtbty.c`. Whose code it is is not known: the keyboard
controller may keep its firmware in a flash of its own, and not in this one
at all. The details of the map, and of
each entry, list every entry's region — type, address, start in the file,
size, and the node that is exactly that range — including those inside a
volume, which are not cut out of anything. A region classifies as UEFITool's `Padding`, with the empty or
non-empty subtype, since that is what the reference calls the bytes; only its
name says what the map makes of them.

A region of type `VAR_DEFAULT` (`D9DDACA2-…`) holds **Insyde Variable
Defaults**: the firmware's default variables, as a run of `$VSS` stores back to
back. It is walked as an NVRAM volume body, and the stores and the erased rest
are its children; an erased one has none. A second `VAR_DEFAULT` entry usually
names the FDC store, already read inside the NVRAM volume, and has nothing to
add. The word at offset 10 of these stores' headers is `0` or `1`, store by
store, and what it means is not known. Every other region is a leaf.

A region of type `BVDT` (`32415DFC-…`) holds Insyde's **BIOS Version Data
Table**, which the details panel reads (`InsydeBVDT.swift`). No specification
is published; the layout is what the six Insyde dumps at hand agree on:

| Offset | Content |
|---|---|
| `0x00` | `$BVDT$` |
| `0x06` | `00 00 00 24 00 00 00` on every dump; not known |
| `0x0D` | `$`, then the BIOS version, NUL-padded to `0x26` (`J2CN57WW`) |
| `0x26` | `$`, then the product name, NUL-padded to `0x40` (`Legion 570 Series Intel`) |
| `0x40` | `$`, then the InsydeH2O kernel version, NUL-padded to `0x66` (`05.43.44`) |
| `0x66` | erased up to `0x12F` |
| `0x12F` | `$`-tagged records — `$BME$`, `$_MSC_VER=`, `$RDATE`, `$ESRT`, `$QUIRK` — ending with `$ENDOFBVDT` |

The records, each found by its tag before `$ENDOFBVDT`:

- `$RDATE` — three BCD bytes, year (`20YY`), month, day. That it is the release
  date is an inference — on every dump it fits the BIOS version — and the help
  says so.
- `$_MSC_VER=` — a 16-bit number, the value of Microsoft's compiler macro of
  that name: 1600 (Visual Studio 2010) on four boards, 1900 (2015) on two.
- `$ESRT` — a 32-bit version, then a GUID: the board's entry in the EFI System
  Resource Table. The GUID is the firmware class — `94F9614C-…` on
  `all.orig.bin` is the hardware ID `UEFI\RES_{…}` that Lenovo's "System
  Firmware" update packages for that board target. The version's low byte is
  the BIOS build number on four of the five boards (`J2CN57WW` → `0x70224057`);
  `CSME 12`'s (`XMGCF500P0402` → `0x57004002`) does not follow it. Four of the
  six end the record with `8B 01 00 00`, which is not read.
- `$BME$` — up to three pairs of a 32-bit offset into the BIOS region and a
  32-bit size, a `$` after each but the last; a slot of size `0xFFFFFFFF` is not
  in use. On every dump the first is the BVDT region itself and the second one
  FFSv2 volume exactly, whose only file is `1FAE4D78-…`, EDK2's
  `MicrocodeUpdates`; `CSME 12` has a third, its second EC Firmware region;
  `Original_Bios_25.05.2025.bin` and `GD25B127D.orig.bin` (one Lenovo board)
  have a third that is their EC Firmware region. `SPI_EF6018`'s second slot
  has a size of zero. What the list is for is not known; the panel places the
  ranges in the file, names what lies exactly there, and a click on one
  outlines it in the dump.
- `$QUIRK`, on `CSME 16` only, is not read.

A string whose `$` is missing, or that holds no printable text, is not shown.

**EC firmware** is read where it is found (`ECFirmware.swift`, `ITEFirmware.swift`).
Two vendors' images are recognised, each on a 4 KiB boundary:

- **ITE**: at `+0x40` (the 8051 parts) or `+0x80` from the image's start a
  signature block — six `A5` bytes, two bytes that vary, `85 12`, two bytes
  that vary, `AA`, one byte that varies, `55 55` — and after it up to sixteen
  bytes of text: `ITE8380-EC-V1.43`, `ITE EC-V13.6`, `IT891x-Dock-v2.1`,
  `ITE5507-SB-V0.67`, `ITE8226-EC-V0.00`, `ITE EC-V14.0`, `ITE EC-V-8586` on the
  dumps at hand. The second varying pair is `5A 5A` on seven of the ten images;
  the two `ITE EC-V14.0` and the `ITE EC-V-8586` carry other values there,
  different on each dump, and what the pair holds is not known. The string is the firmware author's,
  not the chip's marking, and the help says so.
- **`PHCM`**: the header (`MCHP` reversed) Microchip's MEC boot ROM reads.
  The row is called `PHCM image`, not after Microchip: `SPI_EF6018_128Mbit.*`
  carries one on a board whose controllers are both ITE's.
  Its fields are not decoded, and nothing in the image names chip or version.

Three places are looked at: a stretch of non-empty padding the raw-area scan
left, an EC Firmware region of the Insyde map, and the descriptor's EC region,
read when the descriptor is (a look at each 4 KiB boundary, not a scan). A
block holding one image, at its start, is named after it — `EC firmware (…)`,
`EC Firmware (…)`, `EC region (…)`; padding only when the image opens it.
Padding that holds an ITE image further in keeps its range and its name, and
gets the image as a row inside it (`Parser.cuttingECFirmware`): padding before
the first image, a padding block from it to the end of the last, read as
above, and padding after. The padding is what the structures around it make
it; the EC firmware is one part of it, and what else it holds is to be read
into rows beside it.
An AMD board's first padding is like this — `W25Q64JW-IQ.orig.bin` keeps the
PSP's directories and blobs from `0x0`, then `ITE8380-EC-V0.00` at `0x2C8000`.
Only ITE is trusted away from a start: a `PHCM` dword is four bytes. The
node keeps that image's length in `namedImageLength`, and the panel puts its
size in KiB beside the image's name. An EC Firmware region of the Insyde map
that holds that one image is as long as its entry says: the entry is the
firmware's own statement of the slot, and the erased tail is part of the image — `EC Firmware (ITE EC-V13.6,
128 KB)` in `CSME 12`, whose last written byte would make it 96. A block the
map does not name — padding, the descriptor's EC region — is measured as a row
is, below, and so are the images of a region holding several: the entry gives
the region's size, not any one image's (`LENV_CSME 16`'s 512 KB region holds
16, 192 and 192 KB). When
the block holds more than that one image at its start, each image becomes an
`ecImage` node named after itself, classified as UEFITool's padding like the
map regions, and what lies between them stays padding; the block then names
none of them — `EC firmware`, `EC Firmware`, `EC region` — since its rows do. No known header gives an image's length: an image whose
bytes begin with the whole of an earlier image of the same vendor is a copy of
it, as long as it, and carries `ECImage.copySubtype`; any other image runs to
its last written byte before the next image, rounded up to 4 KiB. The copy rule
is what keeps the 16 KiB log at the end of the Dell XPS EC region out of the
second MEC image; the last-byte rule is what keeps an ITE8380 image whole,
which has 40 KiB of erased bytes inside and data at the end of its slot. On the
dumps at hand: `CSME 16`'s EC region is `ITE5507-SB`, `ITE8380-EC` and a copy;
the Dell's EC region is a 4 KiB block of data, a MEC image, another MEC image
and its copy, then the log. ENE images are not recognised yet (#5).

**What the FIT names** is read out of padding (`FITComponents.swift`): the
table itself, the Startup ACM (type 2), the Boot Guard Key Manifest (`0x0B`)
and Boot Policy (`0x0C`). The CPU finds them by address, and a vendor is free to
keep them outside every volume — the HP ZBook Fury 16 G9 dump keeps all four in
1.3 MB of padding, `CSME 11` all four in padding between two volumes, `CSME 16`
the manifests and the table in a pad file's body. UEFITool shows those bytes as
padding. Each structure the FIT names that lies wholly inside a stretch of
non-empty padding becomes a `fitComponent` node, its subtype the FIT type,
fixed, a row inside that padding as the map's regions are — the raw-area
scan's padding, a raw
file's body read as a raw area, and the non-UEFI data of a pad file, whose row
and warning stay as the reference has them, with the structures as its
children. The length is the structure's own: the table's row count; the ACM's
`ModuleSize` in dwords, once its type (`2`) and vendor (`0x8086`) check; a
manifest's `KEY_AND_SIGNATURE` at the end — after the one hash of a v1 Key
Manifest, at the offset the header gives in a v2 one or a v2 Boot Policy, and
after the elements of a v1 Boot Policy, stepped over by what `__IBBS__` and
`__PMDA__` are known to hold, up to `__PMSG__`. On the seven dumps that carry
manifests the FIT's own size field gives the same length in bytes, but the spec
does not promise it, so it is not used. Like the map's regions this runs before
the second pass, with `addressDiff` from a Volume Top File at the image's tail
— the BIOS region's end, as for the map, so `orig_30072026.BIN` with its
`0x110` appended bytes is read too. When the image carries a Top Swap copy (§11) the copy's FIT names
the top block's addresses, so the same structures are looked for in the copy,
moved down by the block's size. The details show what UEFITool's FIT tab shows
of each header: the table's rows; the ACM's module subtype, header version,
chipset ID, BCD date and SVN; a manifest's structure version, revision or KM
version, SVN, and the Key Manifest's ID.

**Pictures** — JPEG, PNG, GIF and BMP — are read in two places
(`Picture.swift`): as an element of the raw-area scan, and as the body of a raw
section the NVAR probe turned down. None of the four states its length in one
place, so each is read through to its end, and a read that cannot get there is
no picture:

- **JPEG**: `FF D8 FF`, then an `APP0` opening with `JFIF\0` or an `APP1` with
  `Exif\0`; the segments walked — a marker after any fill bytes, `TEM` and
  `RSTn` alone, every other segment by its big-endian length, the coded data
  after a start of scan up to the next marker that is neither `FF 00` nor a
  restart — to the end marker. The size is the start-of-frame's.
- **PNG**: the eight-byte signature and `IHDR` (length 13) first, which gives the
  size; chunks — big-endian length, type, data, CRC — to `IEND`.
- **GIF**: `GIF87a` or `GIF89a`, the screen descriptor (the size) and its colour
  table; extensions and images — an image's descriptor, local table and LZW
  code size — each followed by sub-blocks ending in a zero, to the trailer `3B`.
- **BMP**: `BM`, the declared size, both reserved words zero, a DIB header of 12,
  40, 52, 56, 64, 108 or 124 bytes, one plane, 1–32 bits per pixel, compression
  0–6, the pixel offset past the headers and inside the size, and — uncompressed
  — room in the size for every row, padded to four bytes. The declared size is
  the length.

A side over `0x4000` pixels or a walk past 16 MiB is not a picture. The node is
a `picture`, its subtype the `Picture.Format`, named by format and size in
pixels (`BMP 300×300`), classified as UEFITool's padding; in a raw section it
is the section's child, with padding after it for any bytes the picture does
not cover. Only in a raw section's body is a BMP taken that declares more than
the body holds: it is the picture whether or not it is whole, so the node ends
with the body and the details report the declared size. One Dell logo is such a
BMP, `0x34` bytes short.

On the thirteen dumps every picture found in a raw section is the section's
whole body, and the raw-area scan finds one outside a section on one dump only:
the HP ZBook Fury 16 G9's 800×480 JPEG, `0x194E000`–`0x1976FB0`, in the padding
after its FFSv3 volume. Counts run from one BMP (`CSME 11`) to 138 pictures
(`ME 7.bin`, mostly PNG icons in compressed volumes); every one of them decodes
in AppKit to the size read here. A GIF in a Phoenix variable (`CSME 11`) is
not looked for: it sits after the variable's name, not at the start of
anything the parser reads.

**Sounds** — a WAV file — are read where a body stops reading as sections
(§6): at the start of that Non-UEFI data (`Sound.swift`). `RIFF`, a size that
fits, `WAVE`, then chunks — id, little-endian size, data padded to even — read
until both a `fmt ` chunk of at least 16 bytes and a `data` chunk are found;
the length is the RIFF size plus eight. The node is a `sound`, a row inside
the Non-UEFI data, named by sample rate and channels in the language running
(`WAV, 44100 Hz, stereo`), classified as UEFITool's padding. The details give
the encoding, rate, bits, channels and duration, and the panel plays it
(`SoundPlayerView`, AVFoundation). Found on three dumps, each the whole body of
the Freeform file `118C6187-B0D3-4FD4-8B21-A4AE732416AB` in a compressed
volume: `Asus/SPI_C86018_128Mbit_GD25LB128DW.bin`, `CSME 16.1.bin` and
`orig_30072026.BIN` — 44.1 kHz, 16-bit, stereo, about 4 s, by all appearances
ASUS's POST sound.

**How full a store is** is counted off the nodes the parser already made
(`NvramStoreFill.swift`), for any node with variable entries among its
children — a VSS, VSS2, SysF or EVSA store, and the file, raw section or entry
an NVAR store is the body of. The store's size is its body; free is what its
free-space children cover; in use is the rest. An entry is current unless its
subtype marks it: an NVAR `Link` is superseded, and any other marked entry —
VSS, SysF or EVSA `Invalid`, NVAR `Invalid` or `Invalid link` — is superseded
when a current entry with the same name and vendor GUID is in the store, and
deleted otherwise. VSS marks a replaced and a deleted variable alike, and the
tree calls a marked VSS entry `Invalid` as UEFITool does, so for this the name
is read from the bytes: from the start of a `$VSS` variable's body, and from
the end of a VSS2 variable's header, after the standard or the authenticated
fields (the parser's own rule decides which). On `all.orig.bin` the live store
is 95 % in use with 102 current entries, 828 superseded and 3 deleted.

The Insyde Flash Device Map deserves a mention of its own, since it lays out the
whole image:

```c
typedef struct {
    UINT32 Signature;          // 'HFDM' = 0x4D444648
    UINT32 Size;
    UINT32 DataOffset;
    UINT32 EntrySize;
    UINT8  EntryFormat;
    UINT8  Revision;
    UINT8  ExtensionCount;
    UINT8  Checksum;
    UINT64 FdBaseAddress;
} INSYDE_FLASH_DEVICE_MAP_HEADER;

typedef struct {
    EFI_GUID RegionTypeGuid;
    UINT8    RegionId[16];
    UINT64   RegionOffset;
    UINT64   RegionSize;
    UINT32   Attributes;       // 0x01 modifiable, 0x02 ignored
    // UINT8 Hash[]; the size depends on EntryFormat/EntrySize
} INSYDE_FLASH_DEVICE_MAP_ENTRY;
```

---

**A variable's history.** Until a reclaim, a store keeps the earlier copies of a variable as well
(`NvramVariableHistory`). A copy belongs to a variable by name and GUID, within
one store. A VSS entry carries both whether marked or not; a marked one's name
is read from the bytes, since the tree calls it `Invalid`. A `$VSS` entry's
value starts after the name, as long as the header's name size says; a VSS2
entry's body is its value. An NVAR variable is a chain — the head names it,
data-only links take the name of the entry whose `next` points at them, the
last link is current — or a run of whole entries, each superseded one with its
valid bit cleared and its GUID, name and extended header still in it; those are
read as if valid (`readNvarEntry(asIfValid:)`), which the walk itself does
not do, as the reference does not. A variable with no current copy was deleted
as its last copy. On every dump at hand every entry is told whose copy it is;
`all.orig.bin` keeps seven `BootOrder`s and three `Setup`s,
`MemoryOverwriteRequestControl` up to 317 copies (one per boot). EVSA and
SysF entries are not read for this yet. `supersededCopies` maps every copy a later
one replaced to the copy that stands — the current one, or a deleted
variable's last — and the panel's tree lists only the standing copies unless
asked for the rest: 425 rows instead of 4 460 on the Dell dump with a DVAR
store, 252 instead of 1 080 on `all.orig.bin`.

## 10. The second pass

Runs after the tree has been built, and needs a VTF that was found and is not
compressed.

1. **Working out `addressDiff`** — see §5.7.
2. **The reset vector** — parsing `X86_RESET_VECTOR_DATA` in the VTF's body.
3. **The FIT** — see the separate document `FIT_TABLE_FORMAT.md`.
4. **The Boot Guard protected ranges.** The vendor hash files:

```c
typedef struct { UINT8 Hash[32]; UINT32 Base; UINT32 Size; }
        PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY;

typedef struct { UINT64 Signature; UINT32 NumEntries; }   // '$HASHTBL'
        PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_PHOENIX;

typedef struct { UINT8 Hash[32]; UINT32 Size; }           // AMI v1, base from the flash map
        PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V1;

typedef struct { PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY Hash0, Hash1; }
        PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V2;

typedef struct {
    UINT8  Hash[32];
    UINT32 FvMainSegmentBase[3];
    UINT32 FvMainSegmentSize[3];
    UINT32 NestedFvBase, NestedFvSize;
    UINT8  Reserved[48];
} PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V3;
```

The ranges listed in these files, together with the IBB described in the Boot
Policy, make up the list of areas that Boot Guard will break if they are
changed. The whole of it — the Boot Policy manifest, the Insyde Flash Device
Map, how each list's addresses become offsets, the hash checks and the marking
of the tree — is in `BOOT_GUARD_PROTECTED_RANGES.md`.

5. **Checking the bases of TE images** — the `StrippedSize` field of a TE section
   sometimes holds an adjusted base; comparing it with the actual address reveals
   images that a vendor's tool has relocated.

---

## 11. Practical notes

**Limit the recursion depth.** Volume → file → section → volume → … Real images
nest about a dozen rows deep, but a corrupt one can recurse for ever. Set a hard
limit. The limit here (`UEFIParser.Limits.maxDepth`) counts the parser's own
recursion, which a nested volume costs about three of — the volume, its files,
the section holding the next one. A Dell XPS 13 9315 image keeps DXE drivers
inside a volume inside a compressed section inside a volume inside a GUID-defined
section: twelve rows, past the 16 the limit once was, which cut eight branches
off with a false "nesting is too deep". It is 32.

**Find the Top Swap copy.** A chipset with Top Swap set maps the block directly
below the BIOS region's top block at the top of memory, so a board can start
from a second copy of its boot block (`TopSwap.swift`). The block's size is a
strap whose place in the descriptor moves between PCH generations, so the copy
is recognised by what it must hold: one block lower, a FIT pointer with the same
value and a `_FIT_` table at the same distance — tried for every power of two
from 64 KiB to 16 MiB. It is found with the protected ranges, since it needs the
addresses and goes through the same FIT, and the two copies are compared there,
off the main thread: four dumps at hand carry one, a 4 MiB block each, and all
four copies match. The structure panel marks the copy's outermost rows — those
inside the block whose parent is not — "(Top Swap copy)", says in the details
of both blocks' outermost rows where the other copy is and whether they match,
and sends the copy's `?` to the Top Swap entry. The FIT tool-module edits both
copies through the same type.

**Bounds-check at every step.** Every size field is read from untrusted data.
Before any `mid(offset, size)`, check `offset + size <= buffer.size()` allowing
for overflow (add in a 64-bit type, or compare by subtracting).

**Zero sizes.** `FvLength == 0`, `fileSize == 0`, `sectionSize == 0`,
`fitHeader->Size == 0` — all of these mean a broken structure and must stop the
parse of that level, or the result is an infinite loop.

**Broken images are the norm.** Firmware from a flash dump almost always
contains at least one structure that does not match the specification. A parser
has to collect diagnostic messages and carry on rather than fall over the first
problem. The reference implementation uses a "flag plus message" pair
everywhere, never an immediate exit.

**Padding is an element too.** Everything that was not parsed has to end up in
the tree as padding, with its bytes kept. Otherwise rebuilding the image becomes
impossible.

**What must not be moved when rebuilding.** These have to be marked "fixed":

- elements with `FFS_ATTRIB_FIXED`;
- the element containing the FIT, and every element the FIT refers to;
- the VTF;
- areas covered by Boot Guard protected ranges;
- the regions listed in the flash descriptor and in the Insyde Flash Device Map.

**Compressed elements.** Absolute addresses are meaningless for elements inside
compressed containers: the decompressor will place them wherever it likes.
Alignment checks and the FIT's address checks are therefore not performed for
them.
