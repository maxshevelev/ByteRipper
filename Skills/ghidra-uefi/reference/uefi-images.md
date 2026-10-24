# Where a module is, and what its bytes are

This is the short contract behind the skill: the structures the tree walks, the
fields the scripts read, and the address facts that decide what Ghidra sees.
The long, evidence-backed version — every vendor quirk, every dump it was
checked on — is `Design/UEFI/UEFI_IMAGE_FORMAT.md` (§3 volumes, §5 files, §6
sections, §10 addresses). When this page and that one disagree, that one is
right.

## Regions

A flash image is a chain of regions described by the flash descriptor: BIOS,
ME, GbE, EC, and vendor regions between them. The UEFI Structure tree shows the
Intel layout; the module work starts in the **BIOS region**. Bounds come from
the descriptor, so nothing is searched for at the top level.

## Firmware volumes

A volume header starts 0x28 bytes before the `_FVH` signature:

```c
typedef struct {
    UINT8    ZeroVector[16];      // 0x00
    EFI_GUID FileSystemGuid;      // 0x10  decides FFSv1/2/3
    UINT64   FvLength;            // 0x20
    UINT32   Signature;           // 0x28  '_FVH'
    UINT32   Attributes;          // 0x2C  bit 11 = erase polarity
    UINT16   HeaderLength;        // 0x30
    UINT16   Checksum;            // 0x32
    UINT16   ExtHeaderOffset;     // 0x34  revision > 1
    UINT8    Reserved;            // 0x36
    UINT8    Revision;            // 0x37  1 or 2
    // EFI_FV_BLOCK_MAP_ENTRY[]   0x38, {0,0}-terminated
} EFI_FIRMWARE_VOLUME_HEADER;
```

- The file-system GUID says which FFS dialect the body uses:
  `7A9354D9-…` FFSv1, `8C8CE578-…` (and the Apple/Intel/Sony/HP aliases) FFSv2,
  `5473C07A-…` FFSv3.
- `HeaderLength` is the header up to the block map; the extended header, when
  present, ends at `ExtHeaderOffset + ExtHeaderSize`, rounded to 8.
- The first file starts at `ALIGN8(volume + headerSize)`.

## FFS files

```c
typedef struct {
    EFI_GUID Name;                // 0x00
    UINT8    HeaderChecksum;      // 0x10
    UINT8    FileChecksum;        // 0x11
    UINT8    Type;                // 0x12
    UINT8    Attributes;          // 0x13
    UINT8    Size[3];             // 0x14  UINT24, header included
    UINT8    State;               // 0x17
} EFI_FFS_FILE_HEADER;            // 0x18
```

- The next file is `ALIGN8(file + size)`; `size == 0` ends the volume.
- `Attributes & 0x01` is `LARGE_FILE`: FFSv3 reads `UINT64 ExtendedSize` at
  `+0x18` (header 0x20); FFSv2 volumes with revision 2 may carry Lenovo's
  `UINT32` at `+0x18` (header 0x1C).
- Type `0x06` is a PEIM, `0x07` a DXE driver, `0x05` the DXE core, `0x04` the
  PEI core, `0x09` an application, `0x0B` a volume image. `0xF0` is padding.
- A file's body is either a section stream (types other than `RAW`/`PAD`, and
  often those too when they were probed) or raw data that may begin with an
  image.

## Sections

```c
typedef struct {
    UINT8 Size[3];                // full size, header included
    UINT8 Type;                   // 0x01 compression, 0x02 GUID-defined, 0x03 disposable
} EFI_COMMON_SECTION_HEADER;      // 4

typedef struct {
    UINT8  Size[3];               // 0xFFFFFF marks the extended form
    UINT8  Type;
    UINT32 ExtendedSize;
} EFI_COMMON_SECTION_HEADER2;     // 8
```

Sections are 4-byte aligned. Leaves that matter here: `0x10` PE32, `0x12` TE,
`0x15` user-interface name, `0x17` a nested volume image, `0x19` raw.

### Compression (`0x01`)

```c
typedef struct {
    UINT32 UncompressedLength;
    UINT8  CompressionType;       // 0 = none, 1 = EFI/Tiano, 2 = custom
} EFI_COMPRESSION_SECTION;
```

Type 0 holds uncompressed sections; type 1 is the Tiano/EFI 1.1 algorithm
(EDK2's `EfiDecompress`/`TianoDecompress`) and has no stdlib decoder. ByteRipper
implements it; `module_scan.py` reports such a section as closed and stops.

### GUID-defined (`0x02`)

```c
typedef struct {
    EFI_GUID SectionDefinitionGuid;   // +0x04 from the section start
    UINT16   DataOffset;              // from the section start
    UINT16   Attributes;
} EFI_GUID_DEFINED_SECTION;
```

| GUID | meaning |
|---|---|
| `FC1BCDB0-7D31-49AA-936A-A4600D9DD083` | CRC32 — data not compressed |
| `A31280AD-481E-41B6-95E8-127F4C984779` | Tiano |
| `EE4E5898-3914-4259-9D6E-DC7BD79403CF` | LZMA |
| `0ED85E23-F253-413F-A03C-901987B04397` | LZMA (HP) |
| `BD9921EA-ED91-404A-8B2F-B4D724747C8C` | LZMA (Microsoft) |
| `D42AE6BD-1352-4BFB-909A-CA72A6EAE889` | LZMA + x86 filter |
| `1D301FE9-BE79-4353-91C2-D23BC959AE0C` | GZip |
| `CE3233F5-2CD6-4D87-9152-4A238BB6D1C4`, `991EFAC0-…` | Zlib (AMD) |
| `3D532050-5CDA-4FD0-879E-0F7F630D5AFB` | Brotli |

LZMA is an LZMA-alone stream and `lzma.decompress(..., FORMAT_ALONE)` opens it.
The x86-filter variant needs a raw-LZMA decode plus a BCJ pass and is left to
the app.

## The two image formats

**PE32/PE32+** — the ordinary Windows layout: `MZ`, `e_lfanew` at 0x3C,
`PE\0\0`, a COFF header, an optional header with 16 data directories (or as
many as the image claims), and section headers. DXE drivers are usually this.

**TE** — the image EDK2 builds for size:

```c
typedef struct {
    UINT16 Signature;             // 0x5A56, "VZ"
    UINT16 Machine;
    UINT8  NumberOfSections;
    UINT8  Subsystem;
    UINT16 StrippedSize;          // how many bytes the PE headers were
    UINT32 AddressOfEntryPoint;   // RVA
    UINT32 BaseOfCode;
    UINT64 ImageBase;
    EFI_IMAGE_DATA_DIRECTORY DataDirectory[2];  // base reloc, debug
} EFI_TE_IMAGE_HEADER;            // 0x28
```

A TE file is the original PE with its first `StrippedSize` bytes removed and a
40-byte TE header put in front. Section headers follow the TE header and keep
the **original PE file offsets** in `PointerToRawData`; the bytes are at

```
TE_offset = PointerToRawData - StrippedSize + 40
```

from the start of the TE file. That is the relation `te_to_pe.py` inverts when
it rebuilds a PE: the header region is restored to `StrippedSize` bytes (or
larger, and then every pointer shifts by the same delta) and the payload is
placed after it, so the original offsets become valid again.

Ghidra's PE loader requires `MZ` and rejects `VZ`, so a TE must be converted
before it is imported.

## Addresses

- A PE image's `ImageBase` is the address its code expects. In an XIP PEI
  module that is often the physical address the FV is mapped at, e.g.
  `0xFFC50558`; the analysis then uses the firmware's own addresses.
- Compressed modules are copied to RAM, so their `ImageBase` is usually 0 and
  their RVAs are module offsets. Any load base is arbitrary; a stand-in
  (`--image-base`) only changes the numbers, not the code.
- Absolute addresses for a whole image come from the Volume Top File: the last
  byte of the last VTF is mapped at `0xFFFFFFFF`, so
  `addressDiff = 0xFFFFFFFF - base(lastVTF) - size(lastVTF) + 1` and
  `physical = file_offset + addressDiff`. Without a VTF the tree cannot tie
  offsets to addresses. `Design/UEFI/UEFI_IMAGE_FORMAT.md` §5.7 and §10.

## What the tree tells an agent

- `uefi_find` matches `name` (part of the label), `guid` (a file's GUID) and
  `type` (`"Section"`, `"File"`, `"Volume"`, …). A module section's label is
  `PE32 image` or `TE image`; the label after "in" is the file's name.
- `in_compressed: true` means the node has no file address; its bytes come from
  the section named in `compressed_in`, and `uefi_node_data` reads them from the
  decompressed buffer. This is why extraction goes through the app.
- `part: body` of a PE32/TE section is exactly the image Ghidra wants;
  `part: all` adds the 4-byte section header.
