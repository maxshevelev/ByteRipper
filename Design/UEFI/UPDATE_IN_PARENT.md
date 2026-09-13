# Linked tabs and Update in Parent — putting an edited part back into its file

A zone, or what a compressed section decompressed to, can be opened in a tab of
its own. Today that tab is an untitled copy that has forgotten where it came
from. This document makes it remember, and adds the way back: after editing the
part, **Update in Parent** writes it into the file it came out of, with every
size, checksum and compressed stream on the way recomputed.

The hard part is a part whose length changed — which, for a decompressed body,
is nearly always: the body has to be compressed again, and our encoder does not
reproduce the vendor's stream byte for byte. §5–§7 work out what that means for
a section, a file, a volume and a region, starting from how the old UEFITool —
the last version that could edit — did it (§1).

References: `COMPRESSED_SECTIONS.md` (spaces, buffers, the open-in-tab command,
§8.2), `UEFI_IMAGE_FORMAT.md` (the structures), `BOOT_GUARD_PROTECTED_RANGES.md`
(what an edit must not touch), `FIT_TABLE_FORMAT.md` (FIT pointers), and the
`old_engine` branch of the UEFITool repository, `ffsengine.cpp`.

---

## 1. How the old UEFITool rebuilt an image

The old engine did not patch bytes in place. Every edit — insert, replace,
remove, rebuild — marked tree items with an action, and saving reconstructed the
image top down (`reconstruct` → `reconstructIntelImage` / `reconstructRegion` →
`reconstructVolume` → `reconstructFile` → `reconstructSection`). The current
engine of UEFITool dropped editing altogether.

| Level | What it did about size |
| --- | --- |
| Intel image, region, padding | Size must be identical to the byte; bigger or smaller is an error ("reconstructed region size … is bigger/smaller then original") |
| Volume in a region (a root volume) | Cannot grow ("root volume can't be grown"); the final size must equal the original ("volume size can't be changed") |
| Volume inside a file or a section | May grow: `growVolume` rounds the new size up to the block length, allows at most two block map entries, rewrites `NumBlocks`, `FvLength` and the header checksum |
| Files in a volume | Laid out again from the start, aligned to 8; a file's alignment attribute is met by constructing a pad file before it; the rest of the body filled with the empty byte of the erase polarity |
| Volume Top File | Always pinned to the volume's end; the gap before it filled with a pad file; "no space left to insert VTF, need N bytes" when it does not fit |
| Non-UEFI data after free space | Kept at its offset; "no space left to insert non-UEFI data" when the files reach it |
| File | Size rewritten (24-bit, or `ExtendedSize` with `LARGE_FILE` in FFSv3; over 16 MiB without it is an error); header checksum; data checksum when `FFS_ATTRIB_CHECKSUM`, the fixed value otherwise; the FFSv1 tail; `State` normalized |
| Section | Size rewritten (extended when it was); a compression section's `UncompressedLength` and type; the body compressed again with the same algorithm and dictionary size, the x86 BCJ filter applied for LZMA x86; a GUID-defined CRC32 section's CRC when `AUTH_STATUS_VALID`; a warning for a signed section |
| Compression check | EFI 1.1 and Tiano tried with the legacy encoder first and decoded back to compare; LZMA trusted |
| PEI code stored uncompressed | PE32 and TE sections of PEI files rebased to their new address, the PEI Core entry point patched in the VTF; nothing rebased inside a compressed section (loaded into memory) |
| Apple | `AppleCRC32` and `AppleFSO` in the ZeroVector recomputed |

**What to take.** The size and checksum rules of every structure; the VTF pinned
to the end; non-UEFI data kept in place; growth of a volume nested in a section
through its block map; re-deriving compression parameters from the original
section; decoding the new stream back before trusting it.

**What not to take.**

- Empty pad files dropped on every rebuild — which moves everything after them —
  and non-empty ones dropped too (a `continue` under a TODO: a bug).
- Files in `DELETED` or `HEADER_INVALID` states removed on any rebuild, which the
  user never asked for.
- The whole volume laid out again when one file at its end changed.
- Rebasing by heuristic, which its own comments call unreliable. This project
  refuses a move that needs a rebase instead (§6.4).

---

## 2. The link

### 2.1. What a tab remembers

A tab opened from a part of another document carries an **origin**:

- **The parent** — the open document it came from, by identity, not by URL: the
  parent may itself be an untitled tab (a zone of a decompressed body).
- **The place in the parent:**
  - a zone: its file range, its name, and who published it (the tool-module's
    identifier and the zone's id, so a UEFI node zone can be rebuilt by the
    module that understands it — §4);
  - a decompressed body: the section chain (`ByteSpace.decompressed(chain:)`)
    and the node path, and whether it is the whole buffer or one node's bytes.
- **What the bytes are** — the structure at offset 0 of the tab, as the parent's
  tree knew it: an image (the default), a volume, an FFS file (with its volume's
  revision and erase polarity), one section, or a run of sections (with the FFS
  revision whose rules apply — FFSv3 inside a decompressed buffer). A tool-module
  opened on the tab reads the root as that, not by scanning for signatures: the
  body of a Tiano or LZMA section is a run of sections, and a signature scan of it
  finds nothing but padding. The hint survives a broken link — the bytes are
  still what they were — and goes when the tab's content is replaced wholesale.
- **A fingerprint** of the parent's source bytes at the moment of extraction — a
  hash of the zone's range, or of the outermost compressed section's bytes in
  the file. It is what tells, later, whether the parent changed under the tab.
- **The baseline** — the tab's own content at extraction, or at the last update:
  what "has changes to put back" is measured against.

The origin lives in memory, with the documents. It is not written anywhere and
does not survive quitting: a tab saved to disk is a file, and a file has no
parent.

### 2.2. The header

- A `link` symbol and "from bios.rom" in the pane header, after the name.
- A click on it brings the parent's tab to the front and reveals the source
  there: the zone selected, or the compressed section revealed in the dump and
  selected in the UEFI tree.
- **Broken.** The symbol greys out and the tooltip says why when the parent is
  closed, or the fingerprint no longer matches (the source was edited or the
  parent re-read from disk). A link whose parent is closed offers no update;
  one whose source changed asks before overwriting it (§3). Either way the tab
  stays a perfectly good untitled document.
- The name of the parent follows the parent: a Save As of the parent renames it
  in the child's header.

### 2.3. Nesting

A zone taken out of a decompressed tab links to that tab, not to the dump. An
update goes one level up; the tab above then has changes of its own and is
updated into its parent the same way. Each step is checked, named, and undone
on its own; nothing reaches the dump behind the reader's back.

### 2.4. Saving the child

Save and Save As work as on any untitled document and do not touch the link: a
reader may keep a copy of the module on disk and still put it back. Saving does
not count as updating — the baseline moves only on an update.

---

## 3. Update in Parent

In the File menu next to Save and Save As, and in the pane header's menu.
Enabled when the tab has an origin, the link is not broken, and the content
differs from the baseline.

1. **Check the parent.** The fingerprint is compared with the parent's source
   bytes now. A mismatch stops with a choice: overwrite what changed in the
   parent, or cancel. (A parent changed only elsewhere does not trip it: the
   fingerprint covers the source, not the file.)
2. **Build** the parent's new bytes off the main actor: for a plain zone the tab
   itself (§4.1); for a structured origin the plan of §6.
3. **Verify** (§8).
4. **Apply** to the parent as **one undo step**, named "Update from <tab>". The
   parent becomes dirty; nothing is written to disk.
5. **Move the baseline** of the tab to its content, and the fingerprint to the
   parent's new source bytes.

A refusal says what would have been needed, in numbers: "The volume has 0x1200
bytes free; the file grew by 0x2840." Nothing is changed.

The dump's size never changes (§7), so every update is an overwrite of the
parent — which is all `ToolHost.apply` and the pane's tool writes can do.

---

## 4. Who builds the new bytes

### 4.1. A plain zone

A zone no tool-module rebuilds (a FIT table, a microcode, a range someone
published): **the same length only**, written over the zone's range. Any other
length is refused — the app does not know what the bytes after the zone mean.

### 4.2. A structured origin

The app owns the link, the header and the command. What an origin *means* is a
tool-module's business, so a tool-module can say it rebuilds origins of a kind:

```swift
/// A tool-module that can put a part back into its parent.
public protocol ToolRebuilder {
    /// Whether this origin is one this module rebuilds.
    func canRebuild(_ origin: ToolOrigin) -> Bool
    /// The writes that put `bytes` back, or why not. Off the main actor,
    /// over a snapshot of the parent.
    func rebuild(_ bytes: [UInt8], at origin: ToolOrigin,
                 in parent: any ToolContentReader) async -> ToolRebuild
}

public enum ToolRebuild {
    case writes(ToolTransaction, warnings: [String])
    case refused(String)
}
```

The UEFI Structure module rebuilds a decompressed body, a node's bytes from
inside one, and a zone that is a UEFI node — a file or a volume. The work itself
is pure and lives in `UEFIImage` (§6); the module only adapts it.

---

## 5. Compressing again

- **Encoders.** `FirmwareCompression` gains the encoders: LZMA (LzmaEnc from the
  same LZMA SDK 26.01 the decoder comes from), the x86 BCJ encode direction, and
  EDK2's Tiano and EFI 1.1 compressors. They are in the package's test targets
  today; they move behind the product. `CLAUDE.md`'s exception grows from
  decoders to "decoders and encoders for published formats".
- **Parameters** come from the section being replaced: the algorithm and GUID,
  the LZMA dictionary size (`FirmwareDecompression.Decoded.dictionarySize`), the
  x86 filter, and which of Tiano and EFI 1.1 decoded (`Decoded.variant`). The
  Intel legacy 4-byte prefix is written back when the original had one.
- **Roundtrip.** Every new stream is decoded and compared with the input before
  it is used, for every algorithm — the old engine skipped this for LZMA.
- **The size changes.** Expect it always. A decompressed body updated without a
  single byte edited still comes back a different length.

---

## 6. The layout plan

### 6.1. Propagation

An update starts at the changed node and climbs until a level absorbs the size
difference or refuses it:

```
decompressed body  → the compressed section (compressed again)
section            → its parent section or file (sizes, 4-byte alignment)
file               → its volume (8-byte alignment, the move of §6.3)
volume in a section→ the section holding it (the volume may grow, §6.5)
volume in a region → must keep its size (§7)
```

Nested compressed sections are compressed from the innermost outward.

### 6.2. What is recomputed at each level

| Structure | Fields |
| --- | --- |
| Section | size (24-bit, or 0xFFFFFF plus `ExtendedSize` when it was extended or no longer fits); compression section `UncompressedLength`; GUID-defined CRC32 when `AUTH_STATUS_VALID`; the stream itself (§5) |
| File | size (24-bit, or `ExtendedSize` with `LARGE_FILE` in FFSv3); header checksum; data checksum or the fixed value; FFSv1 tail; `State` left as it was |
| Volume | header checksum; `FvLength` and the block map when a nested volume grows; Apple CRC32 and FSO when present |
| Region, image | nothing (no checksums) — but see §6.4 on what else references the bytes |

`UEFIChecksumCheck` already computes the volume header, file header, file body
and microcode checksums; the plan reuses it rather than a second copy.

### 6.3. Moving files inside a volume

Move as little as possible — unlike the old engine:

- Everything **before** the changed file stays byte for byte.
- Files **after** it shift by the difference, each keeping its alignment
  attribute; a pad file immediately in front of an aligned file is resized to
  keep it aligned, and a new one is made where none was.
- **Shrinking** grows the free space at the end of the volume; the freed bytes
  are the empty byte of the erase polarity.
- **Growing** takes room in this order:
  1. the free space at the end of the volume (`.freeSpace`); in a volume with a
     VTF, the gap or pad file in front of the VTF, which stays pinned to the
     end;
  2. empty pad files after the changed file, when removing them keeps every
     later file's alignment;
  3. otherwise a refusal with the numbers.
- **Non-UEFI data** keeps its offset; only the free space before it can be used.
- Files in `DELETED` or `HEADER_INVALID` states are moved like any other file,
  never removed.

### 6.4. What refuses a move

- **Code executed in place.** A volume stored uncompressed with SEC, PEI Core,
  PEIM or combined PEIM/driver files runs from flash at absolute addresses —
  typically the volume with the VTF. A move of any such file is refused rather
  than rebased. A volume inside a compressed section is loaded into memory and
  moves freely: that is the DXE volume, the main case.
- **FIT targets.** A move of a microcode, an ACM, a Key Manifest or a Boot
  Policy Manifest breaks its FIT pointer; refused.
- **Protected ranges.** A change or a move inside the Boot Guard IBB is refused.
  Inside a vendor hash range (AMI, Phoenix, Insyde FDM) it is a warning: the
  hash could one day be recomputed, and the reader may have a reason. Until the
  ranges are read (`BOOT_GUARD_PROTECTED_RANGES.md` §9) every update carries the
  caveat that they were not checked.
- A file over 16 MiB in a volume without `LARGE_FILE` support.

### 6.5. A volume nested in a section

A volume inside a section (a firmware volume image section, most often inside
the LZMA buffer) may grow when its own free space does not suffice: the new size
rounded up to the block length, `NumBlocks` and `FvLength` rewritten, the header
checksum recomputed — refused for a block map of more than one real entry. The
growth then climbs to the section (§6.1). It never shrinks: its free space grows
instead.

---

## 7. A volume in a region: growing into the padding after it

A root volume's size change is refused. Shrinking is never needed — its free
space grows. Growing into empty padding after the volume in the region is easy
to *check* (a `.padding` node with `isErased` right after it) and would be easy
to *write* (the header, the block map, the checksum). It is still refused,
because the image says where the volume ends in places the parser does not see:

- the flash map — each volume's base and size — is compiled into the PEI code
  through PCDs, and AMI keeps it in tables of its own; the firmware keeps
  looking for the volume within its old bounds;
- NVRAM and fault-tolerant-write stores sit at fixed offsets;
- an Insyde FDM names each area's base, size and hash; Boot Guard IBB segments
  and vendor hash ranges are ranges that would no longer match the volume;
- a volume with the VTF is pinned to the top of the address space: it could only
  grow downward, which moves its start.

The refusal says how much empty space follows the volume, so the reader knows
where they stand. A later, separate mode may allow it under confirmation when
the padding after the volume is erased, no FDM entry, hash range, FIT pointer or
IBB segment touches that padding, the volume has no VTF, and the block map is
simple — and it would still warn that the firmware's own flash map is not
updated.

---

## 8. Verifying a build

Before anything is applied, the new parent bytes are checked in memory:

- the changed branch parses again, from the volume (or region) down to the
  changed node;
- every checksum on the path from the node to the root verifies;
- every compressed section on the path decodes to the buffer it was built from;
- nodes outside the changed branch are byte-identical, and so are the files
  before the changed one in its volume.

A failure here is a bug in the planner, reported as such, and nothing is
applied.

---

## 9. Order of work

**Status, 2026-09-13.** Step 1 is in. `UEFIRootLayout` (image, volume, file,
sections) is read by `TreeMaterialization.roots`, `LazyUEFITree` and
`UEFIParser.parse`, falling back to an image when the bytes do not bear it out;
`UEFIRootLayout.of`, `ofBody` and `forFileRange` derive it from the parent's
tree. The app's `DocumentOrigin` holds the parent pane and document weakly, the
source range, the part's name, the layout and a SHA-256 of the source; its state
is re-checked only when the parent's `contentGeneration` moved, and the header
redraws on the parent's `contentDidChangeNotification`. Zone tabs and the UEFI
module's decompressed tabs carry one (`ToolHost.openInNewTab(_:named:linkedTo:)`,
`UEFITreeProviding.openInNewTab(_:named:linkedTo:layout:)`).

Step 2 is in. File ▸ Update in Parent and the pane header's twin, titled
"Update in “<parent>”" and enabled while the tab differs from its baseline and
the parent is open. `DocumentOrigin` carries a kind — `copy` (a zone, bytes a
tool-module took as they are, through `ToolHost.openInNewTab`) or `decompressed`
(through `UEFITreeProviding.openInNewTab`) — and a baseline hash of the tab, and
decides the update itself (`planUpdate`): a copy of the same length goes back
over the source as one undo step "Update from <tab>" in the parent; a changed
source asks first (`MainViewController.updateConfirm` in tests); another length,
a read-only parent, a closed parent and a decompressed body are refused with the
reason. Baseline and fingerprint move before the write (`adopt`) and back if it
fails (`restore`).

Step 3 is in. `CLZMAEncoder` and `CTianoEncoder` moved from `Tests/` to
`Sources/` behind the `FirmwareCompression` product, and
`FirmwareCompression.compress(_:as:dictionarySize:legacyPrefix:)` and
`compress(_:like:from:)` write every variant the decoders read, decoding each
stream back before returning it (`roundTripFailed` otherwise). LZMA is encoded
with the old UEFITool's settings (level 9, `fb` 273); the Tiano compressor runs
under a lock, since it keeps state in statics. UEFITool's legacy Tiano
compressor is not vendored — the round trip stands in for the fallback it was
for. `FirmwareCompressionTestSupport` is now a thin wrapper over the product,
and `CLAUDE.md`'s exception names encoders too.

Step 4 is in: `UEFIRebuild.plan(_:at:in:limits:)` in `UEFIImage`. It parses
the whole file, puts the part at a `Target` (a space, and a node's range or the
whole buffer), normalizes the part itself (a file's size, checksums and tail; a
section's size), and climbs: sections laid out again four-byte aligned with
their size and a valid CRC32 put right, files with theirs, volumes with the move
of §6.3, compressed sections compressed again like the original with
`UncompressedLength` updated, until the file is reached. It hands back one run
of bytes, only after the rebuilt image parses with no new damage and the part
reads back (§8). Where the code differs from §6: growth takes room from the
trailing free space, or from the empty pad file in front of the Volume Top File;
empty pad files in the middle of a volume are not reclaimed yet. Apple's CRC32
and free-space offset are not recomputed. A moved node or descendant that is
`isFixed` (the VTF, a FIT target, `FFS_ATTRIB_FIXED`) refuses, and so does a
moved SEC, PEI Core, PEIM or combined file in a volume of the file itself.

Step 5 is in, without the `ToolRebuilder` protocol of §4.2: the planner has one
implementation and the app already imports `UEFIImage`, so a seam in between
would have nothing on its other side. Instead `DocumentOrigin` carries a
`rebuildTarget` — set by the UEFI module for a decompressed tab
(`UEFITreeProviding.openInNewTab(_:named:linkedTo:layout:part:)`, the export's
space and range) and by the app for a zone that is exactly a volume, a file or a
section of the parent's tree (`UEFIRebuild.target(forFileRange:in:)`). An
update with a target runs `UEFIRebuild.plan` off the main actor, refuses if the
parent changed meanwhile, writes the one run of bytes as one undo step, moves
the link to the part's new range (`Plan.source`) and fingerprint, and says what
the plan warns about in an alert. Without a target, a copy still goes back at
its own length and a decompressed body is refused.

Step 6 is in. A volume whose direct parent is a section, and whose free space
runs to its end, grows when the change needs more room than it has: by whole
blocks of its block map's one entry, with `FvLength`, `NumBlocks` and the header
checksum rewritten and the new blocks erased; the layout is then done again in
the longer volume, and the section around it takes the new size as any other
section would. A block map of more than one entry, a volume in a region or at the
top of a space, and a volume with data after its free space still refuse.

Step 7 is in on the planner's side: `UEFIRebuild.plan(…, protected:)` takes the
file's `ProtectedRange`s (IBB or vendor hash, a file range and a name) and checks
the bytes the rebuild actually changes against them — a change inside the IBB
refuses, one inside a vendor hash range becomes a warning, and the "not
checked" caveat goes when the ranges were given. The ranges are read now
(`BOOT_GUARD_PROTECTED_RANGES.md` §9): before it plans, the app reads the
parent's through the parent's tree (`LazyUEFITree.resolveProtectedRanges`) and
hands the planner `ProtectedRanges.rebuildRanges`, so an update says what it
wrote into, or that it wrote into no protected range at all.

**Progress.** Compressing a DXE volume again takes seconds, so an update that
goes through the planner is shown where it lands: the parent's tab comes to the
front, and its status bar carries the operation (§14.4 of the requirements) —
a label naming the phase, a determinate bar and a (×) that abandons the update
before anything is written. `UEFIRebuild.plan(…, progress:)` reports
`Progress(phase:fraction:)`: "Reading the structure of the image" up to 0.2, one
"Compressing “<section>” again (<size>)" per compressed section on the way out
sharing the bar up to 0.8 — fed by the LZMA encoder's own progress callback,
which `clzma_encode` now takes — and "Checking the rebuilt image" to 1.
`BackgroundOperation.rename(_:)` relabels the strip as the phases change.

1. **The link.** An origin on a pane's document for zone tabs and decompressed
   tabs, with what the bytes are (§2.1) — read by `UEFIImage` as the root of the
   tab's tree, so UEFI Structure shows a decompressed body's sections; the `link`
   badge with the parent's name in the header, a click that reveals the source,
   the broken state on close and on a fingerprint mismatch.
2. **Update in Parent for a plain zone** of the same length: the command, the
   fingerprint check, one undo step in the parent, the baseline moving; other
   lengths refused.
3. **Encoders** in `FirmwareCompression` behind the product, with roundtrip
   tests; `CLAUDE.md` updated.
4. **The planner** in `UEFIImage`: a decompressed body back into its compressed
   section, the section into its file, the file into its volume with the move of
   §6.3 and the refusals of §6.4 (protected ranges as a caveat), and the
   verification of §8. Pure tests over `TestImage` and the encoders.
5. **The rebuilder contract** in `ToolModuleKit` and its UEFI implementation:
   decompressed tabs, node-bytes tabs, and UEFI node zones update through it.
6. **Nested volume growth** through the block map (§6.5).
7. **Protected ranges** (with the Boot Guard work): refusal in the IBB, warnings
   in vendor hash ranges.

## 10. Open questions

- Whether a parent re-read from disk after an external change should re-check
  the fingerprint and keep the link when the source bytes are unchanged, rather
  than always breaking it. Start by breaking it.
- Whether an update should be offered on closing a linked tab with changes not
  put back, next to Save. Start with the ordinary unsaved-changes question.
