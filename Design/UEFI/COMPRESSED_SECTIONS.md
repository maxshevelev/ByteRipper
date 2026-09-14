# Compressed sections — decompressing them, and what a node from inside one is

This document describes where compressed data appears in a firmware image, how
each algorithm is recognised and decoded, what it takes to add the decoders to
the project, and — the larger half — what a tree node found *inside* a
decompressed buffer is, since it is no longer a range of the file.

The formats and algorithms were checked against UEFITool NE (`NE alpha 76`,
commit `dac91b2`): `common/utility.cpp` (`decompress`, `gzipDecompress`,
`zlibDecompress`, `brotliDecompress`), `common/ffsparser.cpp`
(`parseCompressedSectionHeader`, `parseGuidedSectionHeader`,
`parseCompressedSectionBody`, `parseGuidedSectionBody`), `common/ffs.h`,
`common/LZMA/LzmaDecompress.c` and the LZMA SDK it vendors (version `26.01`).
The ME half was checked against `MEA.py` (the module extraction around
"Store & Decompress LZMA Data"). Line numbers drift; function names do not.

Every range here is half-open, `[start, end)`, like every other range in the
project.

---

## 1. What it is for

`UEFIImage` does not decompress. A compressed section is a leaf that names its
algorithm (`SectionParser.swift`, the comment on `walkSections`). In a typical
AMI, Insyde or EDK2 image the whole DXE volume — the DXE and SMM drivers,
Setup, the CSM, option ROMs, logos — sits inside one LZMA GUID-defined section,
so roughly half of the image is one row in the UEFI Structure tree.

Decompressing gives:

1. **The tree.** Hundreds of files with their names, GUIDs, types, depex and
   PE/TE images where there is one row today.
2. **Boot Guard.** The post-IBB and AMI v1 ranges are placed at the volume that
   holds the first DXE Core (`BOOT_GUARD_PROTECTED_RANGES.md` §3), and the DXE
   Core is almost always inside the compressed volume. Without decompression
   those ranges are known but cannot be placed (§9.2 there).
3. **Checks inside.** File checksums, volume header checksums, TE base checks
   and every diagnostic the parser already makes, for the part of the image
   that is inside a compressed section.
4. **The ME region.** CSME modules are stored uncompressed, Huffman-compressed
   or LZMA-compressed (§2.3). `MEFirmware` reads the compression attribute and
   decodes Huffman only; the same LZMA decoder opens the rest.
5. **Export.** A decompressed body can be saved to a file for another tool.

What it does not give is editing inside a compressed section (§7).

---

## 2. Where compressed data appears

### 2.1. The compression section (type `0x01`)

```c
typedef struct {                 // follows the common section header
    UINT32 UncompressedLength;
    UINT8  CompressionType;
} EFI_COMPRESSION_SECTION;       // 5 bytes; the compressed data follows

#define EFI_NOT_COMPRESSED                 0x00
#define EFI_STANDARD_COMPRESSION           0x01   // Tiano or EFI 1.1, §3.3
#define EFI_CUSTOMIZED_COMPRESSION         0x02   // LZMA, §3.1
#define EFI_CUSTOMIZED_COMPRESSION_LZMAF86 0x86   // LZMA + x86 filter, §3.2
```

`0x00` is walked as sections today and stays that way. The body starts after
the five bytes.

`UncompressedLength` is a claim, not a size to allocate. A decompressed buffer
of a different length is a warning (UEFITool: "decompressed size stored in
header differs from actual") and the buffer is used as decoded.

### 2.2. The GUID-defined section (type `0x02`)

The body starts at `DataOffset` (`UEFI_IMAGE_FORMAT.md` §6.3), which the parser
already honours.

| GUID | Algorithm | Body |
|---|---|---|
| `EE4E5898-3914-4259-9D6E-DC7BD79403CF` | LZMA | §3.1 |
| `0ED85E23-F253-413F-A03C-901987B04397` | LZMA (HP) | §3.1, same decoder |
| `BD9921EA-ED91-404A-8B2F-B4D724747C8C` | LZMA (Microsoft) | §3.1, same decoder |
| `D42AE6BD-1352-4BFB-909A-CA72A6EAE889` | LZMA + x86 filter | §3.2 |
| `A31280AD-481E-41B6-95E8-127F4C984779` | Tiano / EFI 1.1 | §3.3 |
| `1D301FE9-BE79-4353-91C2-D23BC959AE0C` | GZip | §3.4 |
| `CE3233F5-2CD6-4D87-9152-4A238BB6D1C4` | Zlib (AMD) | §3.4, after a 0x100-byte header |
| `3D532050-5CDA-4FD0-879E-0F7F630D5AFB` | Brotli | §3.4, after a 16-byte header |

`991EFAC0-E260-416B-A4B8-3B153072B804` is a second AMD Zlib GUID in
`KnownGUIDs`; UEFITool decompresses only the first. CRC32 and signed sections
transform nothing and are outside this document.

Two details from the reference:

- A compressed GUID-defined section should have `PROCESSING_REQUIRED` (`0x01`)
  set in `Attributes`. UEFITool reports it when the bit is clear, and still
  decompresses.
- For AMD Zlib and Brotli the vendor header sits *inside* `DataOffset`, so the
  compressed stream starts after it: `DataOffset + 0x100` for AMD Zlib (which
  also checks `section size == header + 0x100 + CompressedSize`), and
  `DataOffset + 16` for Brotli.

```c
typedef struct {                   // AMD Zlib, 0x100 bytes
    UINT8  ZeroHeader[0x14];
    UINT32 CompressedSize;
    UINT8  ZeroFooter[0x100 - 4 - 0x14];
} EFI_AMD_ZLIB_SECTION_HEADER;

typedef struct {                   // Brotli, 16 bytes
    UINT64 DecompressedSize;
    UINT64 ScratchBufferSize;
} EFI_BROTLI_SECTION_HEADER;
```

### 2.3. CSME modules (the ME region)

Not a UEFI section. A module's metadata carries `Compression`: `0` none,
`1` Huffman, `2` LZMA. For LZMA, `MEA.py` does three things the decoder does
not know about:

1. **Three stray zero bytes in the header.** When the data starts with
   `36 00 40 00 00` and bytes `0x0E..<0x11` are `00 00 00`, those three bytes
   are removed before decoding (`data[..<0x0E] + data[0x11...]`, after
   Skochinsky's `me_unpack.py`).
2. **Missing trailing padding.** When the decoded length is short of the
   module's declared uncompressed size, the difference is filled with the
   decoded data's last byte.
3. **Which bytes the hash covers.** Most LZMA modules are hashed over the
   stored data *with* the zeros; a few over the decompressed data. MEA tries
   the first and falls back to the second.

`MEA.py` decodes with Python's `lzma.LZMADecompressor` in auto mode, which
accepts the 13-byte "LZMA alone" header of §3.1.

---

## 3. The algorithms

### 3.1. LZMA

The EDK2 layout is the LZMA SDK's "alone" format — a 13-byte header, then the
stream:

```
0x00  UINT8  Properties        lc/lp/pb packed in one byte
0x01  UINT32 DictionarySize
0x05  UINT64 UncompressedSize
0x0D  compressed stream
```

Decoding is `LzmaDecode(dest, &destLen, src + 13, &srcLen, src, 5,
LZMA_FINISH_END, &status, alloc)`. UEFITool accepts `SZ_OK` without looking at
`status`; a port should also require that the whole declared size came out.

**Intel legacy LZMA.** Some Intel images put four extra bytes in front of the
header. UEFITool recognises them only indirectly: when the 64-bit size read at
offset 5 does not fit in 32 bits (or the data is 13 bytes or shorter), it skips
four bytes and reads the header again. A port does the same and names the
result "LZMA (Intel legacy)".

**Limits.** The size comes from untrusted bytes. UEFITool refuses sizes above
`INT32_MAX`. The project caps it lower, in `UEFIParser.Limits`, at a value that
covers a real DXE volume with room to spare; a section that claims more is
reported and stays a leaf.

### 3.2. LZMA with the x86 filter

The same decoding, then the x86 branch converter run backwards over the whole
output: `z7_BranchConvSt_X86_Dec(buffer, size, 0, &state)` with `state = 0` and
a start address of `0` (`Bra86.c`; older SDKs call it `x86_Convert` with
`encoding = 0`).

UEFITool applies the x86 filter unconditionally and marks non-x86 images as a
TODO. An ARM image with this GUID would decode to wrong bytes that still parse
badly; a port reports sections that fail to parse after the filter rather than
guessing another architecture.

### 3.3. Tiano and EFI 1.1

```c
typedef struct {
    UINT32 CompSize;
    UINT32 OrigSize;
} EFI_TIANO_HEADER;              // the stream follows
```

The header is valid when `CompSize + 8 == data size`. The two algorithms share
the header and differ in one field width inside the stream, so the stream alone
does not say which one it is:

1. decode with both (`TianoDecompress`, `EfiDecompress`, EDK2's
   `EfiTianoDecompress.c`), each into `OrigSize` bytes with the scratch size
   `EfiTianoGetInfo` reports;
2. if only one succeeds, that is the algorithm;
3. if both succeed, parse each result as a run of sections and take the first
   that parses — Tiano, then EFI 1.1;
4. if neither parses, report "cannot tell Tiano from EFI 1.1" and keep the
   section a leaf.

UEFITool also refuses `OrigSize > INT32_MAX / 4`.

### 3.4. GZip, Zlib and Brotli

- **GZip** — a gzip stream (zlib's `inflateInit2(15 | 16)`).
- **Zlib (AMD)** — a zlib stream with its two-byte header (`inflateInit2(15)`),
  after the AMD header of §2.2.
- **Brotli** — a raw Brotli stream after the 16-byte header, decoded with
  `BROTLI_DECODER_PARAM_LARGE_WINDOW` enabled.

### 3.5. Diagnostics

New `UEFIDiagnostic` kinds, all warnings except the first:

- decompression failed (algorithm, reason) — the section stays a leaf;
- declared size larger than the limit;
- `UncompressedLength` (or Brotli's `DecompressedSize`) differs from the result;
- `PROCESSING_REQUIRED` clear on a compressed GUID-defined section;
- Tiano and EFI 1.1 could not be told apart;
- an algorithm the project does not decode (§4) — informational, not a defect.

---

## 4. The dependencies

The project's rule has been no third-party code. For decompression that rule is
lifted: every algorithm here is a published format with a reference decoder,
and rewriting them is where the risk would be. `CLAUDE.md` and the comment on
`SectionParser.walkSections` change with the first of them.

| Algorithm | Decoder | Licence | Notes |
|---|---|---|---|
| LZMA, LZMA + x86 | LZMA SDK (Igor Pavlov), C | public domain | Apple's Compression framework does not fit: its `COMPRESSION_LZMA` reads the xz container, not the 13-byte "alone" header. |
| Tiano / EFI 1.1 | EDK2 `EfiTianoDecompress.c`, as vendored by UEFITool | BSD | No system equivalent. |
| Brotli | Google Brotli decoder, C | MIT | UEFITool enables the large-window mode; whether Apple's `COMPRESSION_BROTLI` decodes those streams is unverified, so the vendored decoder is the safe choice. |
| GZip, Zlib | the system `libz` | system | Or the Compression framework's raw DEFLATE after stripping the headers. Decided when a dump needs it. |

Only the decoder half is taken. For LZMA that is `LzmaDec.c`/`.h`, `Bra86.c`,
`Bra.h`, `7zTypes.h`, `Compiler.h`, `Precomp.h` and `CpuArch.h` (with
`CpuArch.c` if the build asks for it). `LzmaEnc.c` and `LzFind.c` go into a
test-only target to build fixtures (§9) and never into the app.

**The package.** One shared package, because two users need it — `UEFIImage`
and `MEFirmware` (the project's rule for anything two units share):

```
Packages/FirmwareCompression/
  Package.swift              header comment: what it is, why a package
  Sources/CLZMA/             the SDK's decoder files, unmodified, with its
                             licence note; publicHeadersPath "include"
  Sources/CTiano/            added with Tiano
  Sources/FirmwareCompression/
                             the Swift API; the only target anyone imports
  Tests/FirmwareCompressionTests/
  Sources/CLZMAEncoder/      LzmaEnc.c + LzFind.c, behind the product since
                             Update in Parent (UPDATE_IN_PARENT.md §5)
```

```swift
public enum FirmwareDecompression {
    public enum Failure: Error, Equatable {
        case truncated, corrupt, tooLarge(declared: UInt64), unsupported
    }
    /// The 13-byte header of §3.1, and the Intel legacy four-byte prefix.
    public static func lzma(_ data: [UInt8], limit: UInt64) throws -> Decoded
    public static func lzmaX86(_ data: [UInt8], limit: UInt64) throws -> Decoded
    public static func tiano(_ data: [UInt8], limit: UInt64) throws -> TianoDecoded
    // …
}

public struct Decoded: Equatable, Sendable {
    public var bytes: [UInt8]
    public var variant: String        // "LZMA", "LZMA (Intel legacy)", …
    public var dictionarySize: UInt32?
}
```

`swift-tools-version: 5.9`, `platforms: [.macOS(.v14)]`, listed in `packages:`
in `project.yml`, and `xcodegen generate` after it is added.

---

## 5. A node from inside a decompressed buffer

### 5.1. The problem

A `UEFINode` today is a place in the file: `header`, `body` and `tail` are file
offsets, and everything that reads a node relies on it.

| Consumer | What it does with the ranges |
|---|---|
| `UEFIPresenter.zones(for:)` | publishes `node.range` and `node.body` as zones drawn over the file |
| `UEFINodeDetail` | shows the ranges, and reads header bytes from the file `ImageReader` at them |
| `UEFIChecksumCheck` | reads bytes at them, and builds repair writes for them |
| `LazyUEFITree.step(containing:)` | descends into whichever child's `range` contains a file offset |
| `LazyUEFITree.invalidate` | collapses the nodes whose ranges overlap an edit |
| `UEFIImage.nodes(containing:)`, `innermostNode(containing:)` | same, by file offset |
| `FITTool` placement and the Boot Guard queries | treat ranges as bytes an edit would touch |

A node decoded from a buffer has offsets into that buffer. Put next to file
offsets they are wrong in the worst way: they are plausible. `step(containing:)`
would descend into a DXE driver whose buffer offset happens to equal the caret's
file offset; a zone would highlight unrelated bytes of the dump; placement would
avoid space that is free.

UEFITool does not have this problem because its model has no file offsets at
all — a node's base is the sum of the offsets up the chain, and inside a
compressed section it means nothing, which is why UEFITool skips address checks
for compressed nodes.

### 5.2. The model

Every node says which bytes its ranges are in:

```swift
public enum ByteSpace: Hashable, Sendable {
    /// The open file.
    case file
    /// The decompressed body of a compressed section. The chain names the
    /// section by where it is, not by `NodeID`, so it survives a re-stamp:
    /// the first element is the outermost compressed section's header offset
    /// in the file, and each next one a nested compressed section's header
    /// offset inside the buffer before it.
    case decompressed(chain: [UInt64])
}
```

and `UEFINode` gains:

```swift
public var space: ByteSpace
/// The node's range in the file — nil for anything inside a compressed
/// section. The name makes a caller that needs file bytes say so.
public var fileRange: Range<UInt64>? { space == .file ? range : nil }
```

`isCompressed` keeps its meaning — true for every node inside a compressed
section — and becomes `space != .file`.

The rules that follow:

1. **Ranges are in the node's own space.** `header`, `body` and `tail` do not
   change type; what changes is that they are only comparable within one space.
2. **Everything that means "bytes of the file" uses `fileRange`.** The consumers
   in §5.1 are migrated one by one, and `range` stops being used for file
   lookups. `UEFIImage.nodes(containing:)` and `innermostNode(containing:)` look
   at file-space nodes only, and so does `step(containing:)`.
3. **A compressed section is the boundary.** It is itself a file-space node
   (its bytes are in the file); its children are in its decompressed space.
4. **The reader follows the space.** `UEFINodeDetail` and the checksum check
   read a node through a reader for its space: the file's, or the cached buffer
   of §6.2.

### 5.3. What the panels do with such a node

- **The tree.** A node inside wears the decompressed rail, and the section
  holding it the compressed badge and, while its row is open, the start of
  that rail
  (`Design/ROW_MARKS.md` §5.1).
- **Zones.** A node inside publishes the zone of its outermost compressed
  section — the bytes that actually hold it — named after both
  (`"MyDriver (in LZMA section)"`), and that zone is the focus. Picking that
  zone in the dump brings back the compressed section, not the node, since
  that is all the file can say.
- **Reveal at caret.** Stops at the compressed section that covers the caret.
  A byte of the file inside a compressed stream does not correspond to any one
  decompressed byte.
- **Detail.** Ranges are written as ranges *in the decompressed body of*
  a named section, the "Address" line stays hidden (it already is for
  compressed nodes), and the flags say "compressed".
- **Checksums.** Computed and reported for nodes inside, because a bad checksum
  there is a real defect. "Fix Checksum" is not offered: the fix is a write
  into a buffer that is not the file (§7).
- **Diagnostics.** A diagnostic's offset is a file offset. One found inside is
  reported at the outermost compressed section's header, with the offset in
  the buffer in its message.

---

## 6. The lazy tree

### 6.1. Expanding a compressed section

A compressed section stops being a leaf. The parser leaves it closed with
`isExpandable = true`, like a volume or a region, and
`TreeMaterialization.children(of:)` gains a case for it:

1. read the section's compressed bytes from the file (or from the parent
   buffer, for a nested one);
2. decode (§3), under the size limit;
3. build a `Parser` over an `ImageReader` of the decoded bytes — `[UInt8]` and
   `Data` are already `ByteSource`s — and run the same `walkSections` on them at
   `node.childDepth`;
4. stamp every resulting node with the child space.

The parser needs no second implementation: it already reads through
`ImageReader`, and a buffer is one more source.

A failed decode leaves the section a leaf with its diagnostic and without the
disclosure triangle.

### 6.2. The buffer cache

A decoded DXE volume is megabytes. `LazyUEFITree` keeps decoded buffers keyed
by their `ByteSpace` chain, and:

- drops the least recently used ones past a memory budget, decoding again on
  the next read that needs one;
- drops a buffer, and everything decoded from it, when an edit overlaps the
  outermost compressed section's `fileRange` — `invalidate` already collapses
  that node, and the cache follows it;
- decodes off the main actor, the way every expansion already runs, and
  coalesces two requests for the same buffer onto one decode.

`UEFIParser.parse(_:)`, which materializes everything for tests and the oracle
comparison, decodes every compressed section it meets, under the same limit.

### 6.3. Who opens compressed sections without a row being opened

- **The Boot Guard step** looking for the first DXE Core
  (`BOOT_GUARD_PROTECTED_RANGES.md` §3): it opens compressed sections inside
  uncompressed volumes until it finds one, and places the range at the outermost
  file-space volume on the chain.
- **Nothing else by default.** An open image does not decode its DXE volume
  until something asks for it.

---

## 7. What stays out: editing

Nothing writes into a decompressed space.

- `ToolTransaction` writes are file ranges, and a node without a `fileRange` has
  nothing to offer one.
- "Fix Checksum" is hidden for such nodes (§5.3).
- The FIT tool never considers space inside a compressed section.

Replacing a module inside a compressed volume is a different feature: decode,
change, encode again, and then the section, the file and the volume around it
change size, which is a volume rebuild (UEFITool's `ffsbuilder.cpp`) with every
checksum on the way. A re-encoded stream is not byte-identical to the vendor's,
and the DXE volume is usually covered by a vendor or post-IBB hash, so the
result may not boot. It needs its own document if it is ever wanted.

---

## 8. Other users of the decoder

### 8.1. ME Analyzer

`MEFirmware` gets the §2.3 path next to its Huffman one: remove the stray zeros,
decode, pad, and validate the size — and the hash, compressed first and
decompressed second — the same way it validates a Huffman module's size today.
Any analysis that reads a module body (today only the Huffman `kernel` for the
SKU) can then read LZMA modules too.

### 8.2. Export

`ToolHost.exportFile(_:suggestedName:)` already exists. A compressed section,
or a node inside one, gets "Export Decompressed Body…" in the tree's context
menu, and beside it "Open Decompressed Body in New Tab" ("… Bytes …" for a node
inside). A compressed section still closed in the tree offers both too — the
row already says it is compressed — and choosing one decodes the body then,
without opening the row. That one goes through `ToolHost.openInNewTab(_:named:)`: the app opens
the bytes as an untitled copy in a sibling tab, the way Open Zone in a New Tab
does, named `<dump stem>_<node>.bin`, and without the window's bookmarks, whose
offsets are the dump's.

### 8.3. Search

Finding bytes inside decompressed data (a Setup string, a version) is a
reasonable later feature and out of scope here.

---

## 9. Tests

In `FirmwareCompressionTests`:

- LZMA round trips through the test-only encoder, with and without the x86
  filter, and a small stored vector from a real image for each;
- the Intel legacy prefix;
- a truncated stream, a corrupt stream, and a header claiming more than the
  limit;
- the CSME quirk: stray zeros removed, missing padding filled;
- Tiano and EFI 1.1: each alone, and a buffer both accept.

In `UEFIImageTests`, with `TestImage.compressionSection` and
`TestImage.guidedSection` given compressed bodies:

- an LZMA section expands into sections, files and a nested volume, every node
  in the child space;
- a nested compressed section gets a two-element chain;
- `nodes(containing:)` and `materialize(containing:)` never return a node from
  inside, even one whose buffer offsets cover the asked offset;
- a failed decode stays a leaf with its diagnostic;
- an `UncompressedLength` mismatch and a missing `PROCESSING_REQUIRED` are
  reported;
- an edit over the compressed section collapses it and drops its buffer, and an
  edit elsewhere keeps both;
- the DXE Core found inside places the Boot Guard range at the outer volume.

In the UEFI tool-module's tests: an inner node's zones are the compressed
section's, its detail names the space, and "Fix Checksum" is not offered.

---

## 10. Order of work

**Status, 2026-09-13.** Steps 1–7 are in; step 8 is not, since no dump at hand
has needed Brotli, GZip or Zlib. Where the code differs from the text above:

- The decoders sit in `CLZMA` and `CTiano`, with their encoders beside them in
  `CLZMAEncoder` and `CTianoEncoder` — test support at first, behind the
  product since Update in Parent needed them (`UPDATE_IN_PARENT.md` §5). A
  `FirmwareCompressionTestSupport` product wraps them for the `UEFIImage`,
  `UEFITool` and `MEFirmware` tests.
- `FirmwareDecompression.tiano` returns both readings; `UEFIImage` picks one by
  walking each as sections, and keeps Tiano when neither walks cleanly (no
  separate "cannot tell" diagnostic).
- The diagnostics are `decompressionFailed`, `decompressedTooLarge`,
  `decompressedSizeMismatch` and `processingRequiredNotSet`; the informational
  "not decoded" one was left out — the section's name already says its
  algorithm. A diagnostic inside a buffer carries `inside`
  (`UEFIDiagnostic.InnerLocation`).
- A lazy tree reads every space through `SpaceReaders`; the UEFI panel's
  detail, checksum pass and export use it.
- `MEFirmware` reports LZMA modules that do not decompress, or whose hash does
  not match, as Issue id 19.
- No fixture comes from a real image: every compressed test input is built by
  the reference encoders. §11's open questions stand.

1. `FirmwareCompression` with LZMA and LZMA + x86, and its tests.
2. `ByteSpace`, `fileRange`, and the migration of every consumer in §5.1 —
   with compressed sections still leaves, so nothing visible changes and the
   existing suites say whether the migration held.
3. Expanding compressed sections in the lazy tree, with the buffer cache.
4. The UEFI tool-module: zones, detail, reveal and checksums for inner nodes.
5. Export.
6. `MEFirmware` LZMA modules.
7. Tiano.
8. Brotli, GZip, Zlib — when a dump in hand needs one.

---

## 11. Open questions

- The decompressed-size limit and the cache's memory budget, measured on the
  largest dumps at hand.
- Whether the Boot Guard step should decode on open, or only when the Boot
  Guard marking is switched on.
- Whether Apple's Compression framework decodes EDK2's large-window Brotli
  streams, which would remove one vendored decoder.
- What an LZMA + x86 section in a non-x86 image should do beyond failing to
  parse.

---

## 12. Constants, collected

```c
#define EFI_SECTION_COMPRESSION             0x01
#define EFI_SECTION_GUID_DEFINED            0x02
#define EFI_GUIDED_SECTION_PROCESSING_REQUIRED 0x01

#define EFI_NOT_COMPRESSED                  0x00
#define EFI_STANDARD_COMPRESSION            0x01
#define EFI_CUSTOMIZED_COMPRESSION          0x02
#define EFI_CUSTOMIZED_COMPRESSION_LZMAF86  0x86

#define LZMA_PROPS_SIZE                     5
#define LZMA_HEADER_SIZE                    13     // props + UINT64 size
#define LZMA_INTEL_LEGACY_PREFIX            4
#define EFI_TIANO_HEADER_SIZE               8
#define EFI_AMD_ZLIB_SECTION_HEADER_SIZE    0x100
#define EFI_BROTLI_SECTION_HEADER_SIZE      16

// GUID-defined compression
// EE4E5898-3914-4259-9D6E-DC7BD79403CF   LZMA
// 0ED85E23-F253-413F-A03C-901987B04397   LZMA (HP)
// BD9921EA-ED91-404A-8B2F-B4D724747C8C   LZMA (Microsoft)
// D42AE6BD-1352-4BFB-909A-CA72A6EAE889   LZMA + x86
// A31280AD-481E-41B6-95E8-127F4C984779   Tiano
// 1D301FE9-BE79-4353-91C2-D23BC959AE0C   GZip
// CE3233F5-2CD6-4D87-9152-4A238BB6D1C4   Zlib (AMD)
// 3D532050-5CDA-4FD0-879E-0F7F630D5AFB   Brotli

// CSME module compression (module metadata)
#define CSE_MODULE_COMPRESSION_NONE         0
#define CSE_MODULE_COMPRESSION_HUFFMAN      1
#define CSE_MODULE_COMPRESSION_LZMA         2
// LZMA module quirk: starts 36 00 40 00 00, bytes 0x0E..<0x11 are zero → removed
```

---

## 13. Sources

- UEFITool NE, `common/utility.cpp` — `decompress` (Tiano/EFI 1.1, LZMA with the
  Intel legacy fallback, LZMA + x86), `gzipDecompress`, `zlibDecompress`,
  `brotliDecompress`.
- UEFITool NE, `common/ffsparser.cpp` — the compression and GUID-defined section
  headers and bodies, the Tiano/EFI 1.1 disambiguation by pre-parsing.
- UEFITool NE, `common/ffs.h` — the compression types and section structures.
- UEFITool NE, `common/LZMA/LzmaDecompress.c` and `common/LZMA/SDK/C` — the EDK2
  wrapper and LZMA SDK 26.01.
- UEFITool NE, `common/Tiano/EfiTianoDecompress.c`, `common/brotli`.
- MEAnalyzer, `MEA.py` — CSME module compression types and the LZMA module
  quirks.
- `UEFI_IMAGE_FORMAT.md` §6.2–§6.3 — the section formats as the parser reads
  them today.
- `BOOT_GUARD_PROTECTED_RANGES.md` §3, §9.2 — the DXE root volume.
