# Boot Guard and vendor protected ranges — where they come from and what they protect

This document describes the areas of a firmware image that something checks
against a hash at boot, where each list of them is stored, how an address in
those lists becomes an offset in the file, and how UEFITool marks the tree with
them. It ends with how the project takes the same thing on.

The structures and algorithms were checked against UEFITool NE (`NE alpha 76`,
commit `dac91b2`): `common/ffsparser.cpp` (`checkProtectedRanges`,
`markProtectedRangeRecursive`, `parseVendorHashFile`, the raw-area scan),
`common/fitparser.cpp` (`parseFitEntryBootGuardBootPolicy`), `common/ffs.h`,
`common/treemodel.cpp` and the Kaitai descriptions in `common/ksy/`. Line numbers
drift between versions; the function names do not.

All the C structures below are packed (`#pragma pack(1)` in `ffs.h`), little
endian. Every range in this document is half-open, `[start, end)`, like every
other range in the project.

---

## 1. What it is for

A protected range is a run of bytes whose hash is written down somewhere else
and checked before the code in it runs. Change one byte inside it and the check
fails. Depending on who checks, the result is a platform that does not start at
all, one that drops into recovery, or one that starts and logs it.

There are two families, and the difference matters to anyone editing:

- **Intel Boot Guard.** The ranges are described in the Boot Policy Manifest,
  which is signed by the OEM and reached through the FIT. The processor and the
  Startup ACM check them *before the first instruction of the BIOS runs*. On a
  platform with Boot Guard enforced, a mismatch in the IBB is a board that does
  not start.
- **Vendor hashes.** Phoenix, AMI and Insyde keep their own lists, and code the
  firmware itself runs — usually in PEI, checking the DXE volume — does the
  checking. Microsoft's PMDA element lives inside the Boot Policy but is the
  same kind of thing: a list for the firmware to verify, not for the ACM.

What an editor must take from this: a byte inside a protected range is not free
to change, whatever the tree around it says. This is the check the FIT tool's
microcode placement cannot make today (`Design/TODO.md`).

---

## 2. The model

UEFITool keeps one flat list, filled from every source in §4 and §5, and walks
it once the whole image is parsed.

```c
typedef struct PROTECTED_RANGE_ {
    UINT32     Offset;       // an offset in the file once §3 has been applied
    UINT32     Size;
    UINT16     AlgorithmId;  // TCG algorithm id, §4.4
    UINT8      Type;
    UByteArray Hash;         // expected digest; empty for the IBB, §6.1
} PROTECTED_RANGE;
```

| Type | Value | Source | Checked by |
|---|---|---|---|
| `INTEL_BOOT_GUARD_IBB` | `0x01` | Boot Policy, IBB segments | ACM |
| `INTEL_BOOT_GUARD_POST_IBB` | `0x02` | Boot Policy, `PostIbbHash` | firmware |
| `INTEL_BOOT_GUARD_OBB` | `0x03` | Boot Policy v2, `ObbDigest` | firmware |
| `VENDOR_HASH_PHOENIX` | `0x04` | Phoenix hash file | firmware |
| `VENDOR_HASH_AMI_V1` | `0x05` | AMI hash file, 36-byte body | firmware |
| `VENDOR_HASH_AMI_V2` | `0x06` | AMI hash file, 80-byte body | firmware |
| `VENDOR_HASH_AMI_V3` | `0x07` | AMI hash file, 112-byte body | firmware |
| `VENDOR_HASH_MICROSOFT_PMDA` | `0x08` | Boot Policy, `__PMDA__` element | firmware |
| `VENDOR_HASH_INSYDE` | `0x09` | Insyde Flash Device Map | firmware |

Every source skips an entry whose base is `0xFFFFFFFF`, or whose size is `0` or
`0xFFFFFFFF` — an erased or unused slot, not a range.

---

## 3. From the address in a list to an offset in the file

The lists do not agree on what their numbers mean. Four conventions are in use.

**Physical address.** Most of them: IBB segments, PMDA entries, AMI v2 and v3,
Insyde. Converted the way the FIT's addresses are:

```
offset = address - addressDiff
addressDiff = 0x100000000 - (end of the last Volume Top File)
```

`addressDiff` comes from the VTF (`UEFI_IMAGE_FORMAT.md` §5.7), which
`UEFIImage` already works out. Without a VTF there is no conversion, and the
ranges that need one are unknown rather than guessed. UEFITool warns ("suspicious
protected range offset") when an IBB address is below `addressDiff` and then
uses the address unconverted; a port should instead report it and drop the
range, because it does not lie in this image.

**Relative to the protected-regions base.** Phoenix. The base is the offset of
the first element found in the BIOS region's raw area — its first volume. For an
image with no flash descriptor it is the image base, `0`.

```
offset = protectedRegionsBase + entry.Base
```

**The DXE root volume.** AMI v1 and the Boot Policy's post-IBB hash carry no
address at all. The range starts at the *outermost* volume that contains the
first DXE Core file — a file named `D6A2CB7F-6A18-4E2F-B43B-9920A733700A`
(DXE Core) or `5AE3F37E-4EAE-41AE-8240-35465B5E81EB` (AMI DXE Core). Outermost:
UEFITool walks up through every ancestor volume and takes the last one found,
so a DXE Core in a volume nested inside a compressed section still names the
uncompressed volume at the top.

```
offset = start of that volume
size   = AMI v1: entry.Size          post-IBB: the whole volume
```

**FDM base plus region offset.** Insyde, §5.3: the physical address is built
from two fields, then converted as above.

---

## 4. Intel Boot Guard: the Boot Policy Manifest

### 4.1. Finding it

Through the FIT (`FIT_TABLE_FORMAT.md`): the entry of type `0x0C`,
`INTEL_FIT_TYPE_BOOT_GUARD_BOOT_POLICY`. Its `Address` is physical; converted
by §3, it is where the manifest starts. The manifest carries no size of its own
that can be trusted before it is parsed, so it is read until its element list
ends, never past the end of the image.

The first eight bytes are `__ACBP__` (`0x5F5F504243415F5F`). The byte after
them tells the version:

- `Version < 0x20` — **v1**, §4.2;
- `Version >= 0x20` — **v2**, §4.3.

The Key Manifest (FIT type `0x0B`, `__KEYM__`) holds no ranges. Its one link to
this document is the cross-check in `FIT_TABLE_FORMAT.md` §7.4, which is out of
scope here.

### 4.2. v1

```
BPM header (0x10 bytes)
0x00  UINT64 StructureId        "__ACBP__"
0x08  UINT8  Version            < 0x20
0x09  UINT8  Reserved0
0x0A  UINT8  BpmRevision
0x0B  UINT8  BpSvn
0x0C  UINT8  AcmSvn
0x0D  UINT8  Reserved1
0x0E  UINT16 NemDataSize
0x10  elements…
```

An element is a nine-byte header followed by a body whose layout depends on the
id:

```
0x00  UINT64 StructureId
0x08  UINT8  Version
```

The ids are `__IBBS__`, `__PMDA__` and `__PMSG__`. **A v1 element has no size
field**, so an unknown id cannot be stepped over: the parse of the manifest
stops there. `__PMSG__` (the key and signature) is always last and ends the list.

A v1 hash is fixed at SHA-256 size:

```
HASH_V1 (0x24 bytes)
0x00  UINT16 HashAlgorithmId
0x02  UINT16 Size
0x04  UINT8  Hash[32]
```

**`__IBBS__` body**, from the end of the element header:

```
0x00  UINT8   Reserved[3]
0x03  UINT32  Flags
0x07  UINT64  MchBar
0x0F  UINT64  VtdBar
0x17  UINT32  DmaProtectionBase0
0x1B  UINT32  DmaProtectionLimit0
0x1F  UINT64  DmaProtectionBase1
0x27  UINT64  DmaProtectionLimit1
0x2F  HASH_V1 PostIbbHash
0x53  UINT32  IbbEntryPoint
0x57  HASH_V1 IbbHash
0x7B  UINT8   NumIbbSegments
0x7C  IBB_SEGMENT IbbSegments[NumIbbSegments]
```

```
IBB_SEGMENT (0x0C bytes) — the same in v1 and v2
0x00  UINT16 Reserved
0x02  UINT16 Flags          0 = IBB, 1 = non-IBB
0x04  UINT32 Base           physical address
0x08  UINT32 Size
```

**`__PMDA__` body:**

```
0x00  UINT16 TotalSize
0x02  UINT32 Version        1 or 2
0x06  UINT32 NumEntries
0x0A  entries…
```

```
PMDA entry, version 1 (0x28 bytes)     PMDA entry, version 2 (0x2C bytes)
0x00  UINT32 Base                      0x00  UINT32  Base
0x04  UINT32 Size                      0x04  UINT32  Size
0x08  UINT8  Hash[32]   SHA-256        0x08  HASH_V1 Hash
```

### 4.3. v2

```
BPM header (0x14 bytes)
0x00  UINT64 StructureId        "__ACBP__"
0x08  UINT8  Version            >= 0x20
0x09  UINT8  HeaderSpecific
0x0A  UINT16 TotalSize          0x14
0x0C  UINT16 KeySignatureOffset
0x0E  UINT8  BpmRevision
0x0F  UINT8  BpSvn
0x10  UINT8  AcmSvn
0x11  UINT8  Reserved
0x12  UINT16 NemDataSize
0x14  elements…
```

A v2 element header carries its size, so unknown elements (`__TXTS__`,
`__PFRS__`, `__PCDS__`, whatever comes next) are stepped over:

```
0x00  UINT64 StructureId
0x08  UINT8  Version
0x09  UINT8  HeaderSpecific
0x0A  UINT16 TotalSize          of the whole element, header included
```

The list ends at an element with `TotalSize == 0`, or at `__PMSG__`. The key
signature follows the list; UEFITool reads it there and does not consult
`KeySignatureOffset`, which a port can use as a cross-check.

A v2 hash has a variable length:

```
HASH_V2
0x00  UINT16 HashAlgorithmId
0x02  UINT16 Size
0x04  UINT8  Hash[Size]
```

**`__IBBS__` body** — fixed up to the first hash, sequential after it:

```
0x00  UINT8   Reserved0
0x01  UINT8   SetNumber
0x02  UINT8   Reserved1
0x03  UINT8   PbetValue
0x04  UINT32  Flags
0x08  UINT64  MchBar
0x10  UINT64  VtdBar
0x18  UINT32  DmaProtectionBase0
0x1C  UINT32  DmaProtectionLimit0
0x20  UINT64  DmaProtectionBase1
0x28  UINT64  DmaProtectionLimit1
0x30  HASH_V2 PostIbbDigest
      UINT32  IbbEntryPoint
      UINT16  IbbDigestsSize
      UINT16  NumIbbDigests
      HASH_V2 IbbDigests[NumIbbDigests]
      HASH_V2 ObbDigest
      UINT8   Reserved2[3]
      UINT8   NumIbbSegments
      IBB_SEGMENT IbbSegments[NumIbbSegments]
```

**`__PMDA__` body:**

```
0x00  UINT16 Reserved
0x02  UINT16 TotalSize
0x04  UINT32 Version            3
0x08  UINT32 NumEntries
0x0C  entries…
```

```
PMDA entry, version 3
0x00  UINT32  EntryId           four characters
0x04  UINT32  Base
0x08  UINT32  Size
0x0C  UINT16  TotalEntrySize
0x0E  UINT16  Version
0x10  HASH_V2 Hash
```

### 4.4. Hash algorithm ids

TCG ids, as the manifests store them:

| Id | Algorithm | Digest size |
|---|---|---|
| `0x0004` | SHA-1 | 20 |
| `0x000B` | SHA-256 | 32 |
| `0x000C` | SHA-384 | 48 |
| `0x000D` | SHA-512 | 64 |
| `0x0010` | NULL | 0 |
| `0x0012` | SM3 | 32 |

### 4.5. The ranges a manifest produces

- **IBB** — every IBB segment with `Flags == 0` and a valid base and size (§2):
  `[Base − addressDiff, + Size)`. Segments with `Flags == 1` are non-IBB and
  produce nothing. The segments of one manifest together make up one IBB; their
  expected digests are `IbbHash` (v1) or `IbbDigests` (v2), §6.1.
- **Post-IBB** — when `PostIbbHash` / `PostIbbDigest` is not uniform (neither
  all `0x00` nor all `0xFF`): one range whose position is the DXE root volume
  (§3), with that digest.
- **OBB** — v2 only, when `ObbDigest` is not uniform. UEFITool adds it to the
  list and then neither places, marks nor checks it: nothing in the manifest
  says where the OBB is. A port records that the manifest names an OBB digest
  and stops there.
- **PMDA** — every entry with a valid base and size: `[Base − addressDiff,
  + Size)`, with the entry's own digest (SHA-256 for PMDA v1).

---

## 5. Vendor hash files

### 5.1. Phoenix

An FFS file named `389CC6F2-1EA8-467B-AB8A-78E769AE2A15`. The table is the
**file's body** — no section around it.

```c
#define BG_VENDOR_HASH_FILE_SIGNATURE_PHOENIX 0x4C42544853414824ULL  // "$HASHTBL"

typedef struct {                        // 0x0C bytes
    UINT64 Signature;
    UINT32 NumEntries;
} PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_PHOENIX;

typedef struct {                        // 0x28 bytes
    UINT8  Hash[32];                    // SHA-256
    UINT32 Base;                        // relative, §3
    UINT32 Size;
} PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY;
```

The body has to hold `0x0C + NumEntries × 0x28` bytes; a shorter one is a
corrupt file and produces nothing. Each valid entry is a range at
`protectedRegionsBase + Base`.

### 5.2. AMI

An FFS file named `CBC91F44-A4BC-4A5B-8696-703451D0B053`. The table is the body
of a **raw section** inside it, and its version is told by that body's size and
nothing else:

| Body size | Version |
|---|---|
| `0x24` (36) | v1 |
| `0x50` (80) | v2 |
| `0x70` (112) | v3 |
| anything else | unknown or corrupt — no ranges |

```c
typedef struct {                        // v1, 0x24 bytes
    UINT8  Hash[32];                    // SHA-256
    UINT32 Size;                        // base: the DXE root volume, §3
} PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V1;

typedef struct {                        // v2, 0x50 bytes
    PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY Hash0;   // Base is physical
    PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY Hash1;
} PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V2;

typedef struct {                        // v3, 0x70 bytes
    UINT8  Hash[32];                    // one SHA-256 over all of them, §6.2
    UINT32 FvMainSegmentBase[3];        // physical
    UINT32 FvMainSegmentSize[3];
    UINT32 NestedFvBase;                // physical
    UINT32 NestedFvSize;
    UINT8  Reserved[48];
} PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V3;
```

- **v1** — one range, at the DXE root volume, `Size` long.
- **v2** — up to two ranges, each with its own hash.
- **v3** — up to four ranges (three FvMain segments and the nested volume), in
  that order, sharing one hash.

### 5.3. Insyde H2O Flash Device Map

Not an FFS file: a store found by the **raw-area scan**, like a volume or a
microcode, by the signature `HFDM` (`0x4D444648`) at the start of a candidate.

```c
typedef struct {                        // 0x1C bytes
    UINT32 Signature;                   // "HFDM"
    UINT32 Size;                        // of the whole store
    UINT32 DataOffset;                  // from the store's start to the entries
    UINT32 EntrySize;
    UINT8  EntryFormat;
    UINT8  Revision;
    UINT8  ExtensionCount;
    UINT8  Checksum;                    // checksum8 of this header, Checksum = 0
    UINT64 FdBaseAddress;
    // INSYDE_FLASH_DEVICE_MAP_EXTENSION Extensions[ExtensionCount];
} INSYDE_FLASH_DEVICE_MAP_HEADER;

typedef struct {                        // 0x04 bytes
    UINT16 EntryOffset;
    UINT16 EntryCount;
} INSYDE_FLASH_DEVICE_MAP_EXTENSION;

typedef struct {                        // 0x54 bytes in the one known format
    EFI_GUID RegionTypeGuid;
    UINT8    RegionId[16];
    UINT64   RegionOffset;
    UINT64   RegionSize;
    UINT32   Attributes;
    UINT8    Hash[32];                  // SHA-256
} INSYDE_FLASH_DEVICE_MAP_ENTRY;

#define INSYDE_FLASH_DEVICE_MAP_ENTRY_ATTRIBUTE_MODIFIABLE 0x00000001  // hash not checked
#define INSYDE_FLASH_DEVICE_MAP_ENTRY_ATTRIBUTE_IGNORED    0x00000002  // entry not valid
```

A candidate is a store when `Size` fits in what is left of the raw area and
`Revision <= 4`; a higher revision is reported and skipped. The header checksum
is reported, not required.

The entries are read only when `EntrySize == 0x54` and `EntryFormat == 0`, from
`DataOffset` to `Size`, one `EntrySize` at a time. Any other format is reported
as unknown and the store stays a leaf.

An entry becomes a range when `MODIFIABLE` is clear:

```
address = (UINT32)FdBaseAddress + (UINT32)RegionOffset
offset  = address - addressDiff
size    = (UINT32)RegionSize
```

UEFITool looks at `MODIFIABLE` only; an entry with `IGNORED` set and
`MODIFIABLE` clear still becomes a range. A port should follow that until a real
image says otherwise, and say so in a comment.

The whole store is fixed when the image is rebuilt
(`UEFI_IMAGE_FORMAT.md` §11), whatever its entries say.

---

## 6. Checking the hashes

Runs after every source above has been read.

### 6.1. The IBB

UEFITool concatenates the bytes of every IBB range, in list order, and
computes SHA-1, SHA-256, SHA-384, SHA-512 and SM3 of the result. It **prints**
them in its security information and compares them with nothing.

The comparison it leaves out is the one worth having: the concatenation hashed
with `IbbHash`'s algorithm (v1) or with each of `IbbDigests`' algorithms (v2)
is expected to equal the stored digest. Because the reference implementation
never makes that comparison, a port should present a mismatch as a warning, not
as a verdict, until it has been confirmed against dumps from boards known to
boot.

### 6.2. Everything else

| Type | Hashed bytes | Algorithm |
|---|---|---|
| Post-IBB | the DXE root volume, whole | the digest's own id |
| PMDA | the entry's range | the entry's own id (SHA-256 for v1) |
| Phoenix | the entry's range | SHA-256 |
| AMI v1 | `Size` bytes from the DXE root volume | SHA-256 |
| AMI v2 | each entry's range, separately | SHA-256 |
| AMI v3 | the up-to-four ranges concatenated, in file order | SHA-256 |
| Insyde | the entry's range | SHA-256 |

A mismatch is reported against the node at the range's start: "hash mismatch,
opened image may refuse to boot". An unknown algorithm id is reported and the
range is still marked.

A range that runs past the end of the image is not an error in UEFITool — it
catches the out-of-bounds read and silently skips the range. A port bounds-checks
first and reports it.

---

## 7. Marking the tree

### 7.1. What UEFITool does

For every range, in list order, the whole tree is walked
(`markProtectedRangeRecursive`), and each node's `[base, base + fullSize)` is
compared with the range:

```
if node and its parent are both compressed:
    node.marking = parent.marking            // its address means nothing
else if node ∩ range is not empty:
    if range contains node:
        node.marking = (range.Type == IBB) ? BootGuardFullyInRange
                                           : VendorFullyInRange
    else:
        node.marking = PartiallyInRange
recurse into the children
```

```c
enum BootGuardMarking {
    None = 0,
    PartiallyInRange,        // yellow   (dark: darkYellow)
    BootGuardFullyInRange,   // red      (dark: darkRed)
    VendorFullyInRange       // cyan     (dark: darkCyan)
};
```

The marking is drawn as the row's background, and the View menu's
"BootGuard markings" item turns it off. It is display only: UEFITool does not
set a node fixed because a range covers it.

How to read the colours:

- **Red** — every byte of the node is inside the IBB. Any change breaks the
  hash the ACM checks.
- **Cyan** — every byte is inside a firmware-checked range: post-IBB, PMDA or a
  vendor list. A change breaks a hash the firmware checks.
- **Yellow** — the node overlaps a range without being inside it: nearly always
  a container (a region, a volume, a file) holding protected and unprotected
  parts, or a node straddling a range's edge. Whether an edit inside it breaks
  anything depends on which bytes it touches. Yellow is not an error.

### 7.2. Where the reference gets it wrong

Two consequences of marking range by range, each pass overwriting the last:

1. **The last range wins.** A node fully inside the IBB, then touched at its
   edge by a later vendor range, ends up yellow. A red node can be repainted
   cyan by a later range that also contains it.
2. **Adjacent ranges do not add up.** IBB segments are often contiguous. A
   volume spanning two of them exactly is fully protected, yet each range on its
   own only partly contains it, so it is marked yellow.

### 7.3. The rule for this project

Mark against the **union** of the ranges, strongest first:

1. `ibb` — the node lies entirely within the union of the IBB ranges;
2. `protected` — it lies entirely within the union of all ranges;
3. `partial` — it intersects any range;
4. none.

Compressed nodes take their nearest uncompressed ancestor's marking, as in
UEFITool. The result depends only on the set of ranges, not on their order, and
a tree that is expanded later marks the same way as one expanded up front.

---

## 8. What the image cannot tell

Whether Boot Guard is enforced is not in the BIOS region. A board with a Key
Manifest and a Boot Policy may run with Boot Guard off; the profile — off,
verified, measured, or both — is provisioned into the PCH's field-programmable
fuses through the ME. Neither UEFITool nor `MEFirmware` reads it.

So the marking says what *would* break if the protection is active, and the
panels say it in those words. Reading the profile from the ME region is a
separate piece of work for the ME Analyzer tool-module.

---

## 9. The plan for this project

### 9.1. `UEFIImage`

A new step in the second pass, after `addressDiff` and the reset vector
(`SecondPass.swift`), producing:

```swift
public struct ProtectedRange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ibb, postIbb, pmda
        case phoenix, amiV1, amiV2, amiV3, insyde
    }
    public var kind: Kind
    /// Half-open, in file offsets. Nil when the list names the range but the
    /// image cannot place it — no VTF, or no visible DXE root volume (§9.2).
    public var range: Range<UInt64>?
    public var algorithm: UInt16
    public var expected: [UInt8]
    /// Where the list that named it was found, for the detail and for
    /// diagnostics.
    public var source: Range<UInt64>
}
```

and on `UEFIImage`:

- `protectedRanges: [ProtectedRange]`;
- `obbDigest` noted when a v2 manifest names one (§4.5);
- a query `protection(of range: Range<UInt64>) -> Protection?` implementing
  §7.3, so neither panel repeats it.

The reading itself:

1. **The Boot Policy**, through the FIT pointer at `0xFFFFFFC0`: walk the
   entries for type `0x0C` and nothing else. The table's validation and editing
   stay in `FITTool` (`TOOL_MODULES_PLAN.md`); finding one entry is a read,
   and both tool-modules need what it leads to, which is the rule for putting
   code in a shared package. Then §4.2 or §4.3.
2. **The vendor hash files**, by GUID among the uncompressed files (§5.1,
   §5.2).
3. **The Insyde FDM**, as a new signature in `scanRawArea` (`UEFIParser.swift`)
   producing its own node kind, with its entries as children (§5.3).
4. **The hashes** (§6), with CryptoKit — `Insecure.SHA1`, `SHA256`, `SHA384`,
   `SHA512`. SM3 is not in the system libraries and the project takes no
   third-party code: an SM3 digest is reported as unsupported, and the range is
   still marked.

New diagnostics: a hash mismatch (per kind, warning for the IBB, §6.1); a range
outside the image; an unsupported algorithm; an unknown AMI hash file size; an
unknown FDM format or revision; a truncated manifest, hash file or FDM. Every
structure here is read from untrusted bytes, so every field is bounds-checked
before use (`UEFI_IMAGE_FORMAT.md` §11).

`UEFINode.isFixed` promises "anything a Boot Guard range covers". Nodes are
materialized lazily, after the second pass, so the promise is kept through the
query rather than by writing the flag into nodes that do not exist yet; the
comment on `isFixed` changes to say so.

### 9.2. Two constraints from the lazy, undecompressed tree

- **Finding the files.** The vendor hash files live in volumes, and
  `LazyUEFITree` does not list a volume's files until asked. The step has to
  materialize every uncompressed volume's file list (not its sections), plus the
  one raw section of an AMI hash file. That is work every open image pays, so it
  runs off the main actor with the rest of `resolveAddresses`, and it is
  measured on a large dump before it is accepted.
- **The DXE root volume.** The first DXE Core usually sits inside an LZMA
  section, which `UEFIImage` does not open (`Design/TODO.md`). Where it cannot
  be seen, a post-IBB or AMI v1 range is recorded with `range == nil` and a
  diagnostic, and the panels say the range exists but cannot be placed. No
  guessing at "the biggest volume" or "the volume after PEI".

### 9.3. The UEFI Structure tool-module

- The outline draws the marking as a row background: tints from `AppPalette`
  that read in both appearances. Background, not text colour — red text is
  the project's "modified, unsaved" state.
- The detail gains a "Protected by" block naming each range that touches the
  node: kind, file range, where the list is, and the hash verdict.
- A switch for the marking, off the panel's menu, remembered like the panel's
  other settings.
- The panel's summary says when an image names protected ranges at all, and
  the §8 caveat.

### 9.4. The FIT tool-module

- The microcode placement search takes `protectedRanges` and skips any
  candidate that intersects one (`FIT_TABLE_FORMAT.md` §9.2, step 1).
- A replace or remove that would write inside a range is refused or warned
  about — which of the two is a decision for that change, not for this
  document.
- The "Boot Guard ranges are not checked" caveat after every edit goes, and is
  replaced by what the check found.

### 9.5. Zones

`ZoneKind` reserves "protected by Boot Guard". Once the ranges exist, the UEFI
tool-module can publish them as zones of their own kind, so the dump shows them
even with the panel closed.

### 9.6. Tests

In `UEFIImageTests`, on built images rather than real dumps:

- a v1 and a v2 manifest reached through a FIT entry, each with IBB and non-IBB
  segments, a post-IBB digest and PMDA entries;
- a v1 manifest with an unknown element (the parse stops) and a v2 one (it is
  stepped over);
- a Phoenix file, AMI v1, v2 and v3 bodies, and an AMI body of another size;
- an FDM with modifiable, non-modifiable and ignored entries, and one with an
  unknown entry format;
- address conversion: a range below `addressDiff`, one past the end, an image
  with no VTF;
- matching and mismatching hashes for each kind, and an SM3 digest;
- the marking rule: a node across two adjacent IBB segments is `ibb`; an order
  change in the list changes nothing; a node inside a compressed section takes
  its ancestor's marking.

### 9.7. Open questions

- The IBB digest comparison (§6.1): confirm against boards known to boot before
  a mismatch is shown as anything stronger than a warning.
- The OBB: whether anything in a v2 image says where it is.
- The cost of materializing every volume's file list on open (§9.2).
- What the FIT tool does when the only free space is inside a range: refuse, or
  write and say what it broke.

---

## 10. Constants, collected

```c
#define BOOT_POLICY_STRUCTURE_ID   0x5F5F504243415F5FULL  // "__ACBP__"
#define BOOT_POLICY_IBBS_ID        0x5F5F534242495F5FULL  // "__IBBS__"
#define BOOT_POLICY_PMDA_ID        0x5F5F41444D505F5FULL  // "__PMDA__"
#define BOOT_POLICY_PMSG_ID        0x5F5F47534D505F5FULL  // "__PMSG__"
#define BOOT_POLICY_TXTS_ID        0x5F5F535458545F5FULL  // "__TXTS__", v2
#define BOOT_POLICY_PFRS_ID        0x5F5F535246505F5FULL  // "__PFRS__", v2
#define BOOT_POLICY_PCDS_ID        0x5F5F534443505F5FULL  // "__PCDS__", v2
#define BOOT_POLICY_V2_MIN_VERSION 0x20

#define IBB_SEGMENT_TYPE_IBB       0
#define IBB_SEGMENT_TYPE_NON_IBB   1

#define TCG_HASH_ALGORITHM_ID_SHA1   0x0004
#define TCG_HASH_ALGORITHM_ID_SHA256 0x000B
#define TCG_HASH_ALGORITHM_ID_SHA384 0x000C
#define TCG_HASH_ALGORITHM_ID_SHA512 0x000D
#define TCG_HASH_ALGORITHM_ID_NULL   0x0010
#define TCG_HASH_ALGORITHM_ID_SM3    0x0012

// 389CC6F2-1EA8-467B-AB8A-78E769AE2A15
#define PROTECTED_RANGE_VENDOR_HASH_FILE_GUID_PHOENIX
#define BG_VENDOR_HASH_FILE_SIGNATURE_PHOENIX 0x4C42544853414824ULL  // "$HASHTBL"
// CBC91F44-A4BC-4A5B-8696-703451D0B053
#define PROTECTED_RANGE_VENDOR_HASH_FILE_GUID_AMI

#define INSYDE_FLASH_DEVICE_MAP_SIGNATURE             0x4D444648  // "HFDM"
#define INSYDE_FLASH_DEVICE_MAP_MAX_REVISION          4
#define INSYDE_FLASH_DEVICE_MAP_ENTRY_SIZE            0x54
#define INSYDE_FLASH_DEVICE_MAP_ENTRY_FORMAT          0
#define INSYDE_FLASH_DEVICE_MAP_ENTRY_ATTRIBUTE_MODIFIABLE 0x00000001
#define INSYDE_FLASH_DEVICE_MAP_ENTRY_ATTRIBUTE_IGNORED    0x00000002

// The DXE Core, for the DXE root volume (§3)
// D6A2CB7F-6A18-4E2F-B43B-9920A733700A   DXE Core
// 5AE3F37E-4EAE-41AE-8240-35465B5E81EB   AMI DXE Core
```

---

## 11. Sources

- UEFITool NE, `common/ffsparser.h` — `PROTECTED_RANGE` and the range types.
- UEFITool NE, `common/ffsparser.cpp` — `checkProtectedRanges`,
  `markProtectedRangeRecursive`, `parseVendorHashFile`, the Insyde FDM in the
  raw-area scan and in `parseRawArea`, and the DXE Core detection in
  `parseFileHeader`.
- UEFITool NE, `common/fitparser.cpp` — `parseFitEntryBootGuardBootPolicy`, the
  source of the IBB, post-IBB, OBB and PMDA ranges.
- UEFITool NE, `common/ffs.h` — the vendor hash file and FDM structures.
- UEFITool NE, `common/ksy/intel_acbp_v1.ksy`, `intel_acbp_v2.ksy`,
  `insyde_fdm.ksy` — the Boot Policy and FDM layouts.
- UEFITool NE, `common/treemodel.h`, `common/treemodel.cpp` — `BootGuardMarking`
  and its colours.
- `FIT_TABLE_FORMAT.md` — finding the Boot Policy through the FIT, and the
  placement rules this document feeds.
- `UEFI_IMAGE_FORMAT.md` — `addressDiff` (§5.7), the second pass (§10), what must
  stay fixed (§11).
