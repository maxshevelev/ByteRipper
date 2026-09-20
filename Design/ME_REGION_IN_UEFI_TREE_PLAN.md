# ME Region in the UEFI Structure — analysis and implementation plan

Graft the ME Region tree — the one the ME Analyzer module already builds —
inside the UEFI Structure tree, reusing the parsing and presentation code that
already exists, instead of re-parsing the ME bytes a second way.

This doc is the analysis that led to the design, and the plan that was built
from it. Sections 1–3 are the analysis and still stand as written; section 4
is how it was built, and every step of it is in the tree; section 5's
decisions are closed, with what they closed to.

**Status.** Built. The graft lives in `Modules/UEFITool`: opening the ME
region node runs the shared analysis and opens the region's row onto the
`MEANode` sub-tree, which `Packages/MEPresentation` curates for both this
panel and the ME Analyzer. The four places that cite this doc —
`Modules/UEFITool/Package.swift`, `UEFIToolModule.swift`,
`UEFIToolViewController.swift` and `ByteRipperTests/UEFIToolFlowTests.swift`
— are pointing at shipped code.

---

## 1. The two ME parsers, compared

### 1.1 Original UEFITool (`new_engine`)

**Correction to the brief.** The per-component parser files the brief assumed
(`MEFirmware.cpp`, `CPDParser.cpp`, `EFSParser.cpp`, `MFSParser.cpp`,
`HAPParser.cpp`, …) do **not exist** in any branch (`new_engine`,
`old_engine`, `legacy_builder`) or tag of LongSoft/UEFITool. UEFITool has no
nested region classes; it is a flat `TreeItem`/`TreeModel` keyed by
`type`/`subtype` byte enums. Our Swift ME parser is modeled on
**platomav/MEAnalyzer** (Python), not on UEFITool — UEFITool itself cites
`MEA.py` in `common/ffs.h:607` as the source of its BPDT entry-type table.

Where ME parsing actually lives in `new_engine`:

| File | Role |
|---|---|
| `common/meparser.cpp` | `MeParser`: `parseMeRegionBody` (entry), `parseFptRegion`, `parseIfwi16/17Region` |
| `common/ffsparser.cpp` | `parseMeRegion`, `parseBpdtRegion`, `parseCpdRegion`, `parseCpdExtensionsArea`, `parseGbeRegion`, `parsePdrRegion`, `getMeVersionFromPartition` |
| `common/me.h` / `ffs.h` / `gbe.h` | `FPT_HEADER`, `IFWI_*`, `ME_VERSION` (`$MAN`/`$MN2`), `BPDT_*`, `$CPD`, `CPD_*`, `GBE_*` |
| `common/types.h` / `types.cpp` / `ffs.cpp` | node name/type strings; `bpdtEntryTypeToUString`, `cpdExtensionTypeTostring` |
| `common/descriptor.cpp` | region detection |

**Detection.** By the flash descriptor, not by scanning: `parseIntelImage`
validates `FLASH_DESCRIPTOR_HEADER`, reads the region section, and builds the
ME region from `MeBase`/`MeLimit` with `Subtypes::MeRegion == 2` — descriptor
region type **0x02**, exactly as we assume.

**Tree it displays.**

```
ME region
├─ IFWI 1.6/1.7 header          (or straight FPT, when there is no IFWI)
│  ├─ Data partition → FPT partition table
│  │   ├─ FPT entry ×N           (4-char names: FTPR, RBEP, …)
│  │   └─ FPT partition ×N → (body starts $CPD) CPD partition table
│  │       ├─ CPD entry ×N       (12-char names)
│  │       └─ CPD partition: Manifest | Metadata | Code
│  │           ├─ Manifest → CPD extension ×N
│  │           ├─ Metadata → CPD extension ×N
│  │           └─ Code     → raw-area FFS scan
│  └─ Boot partition ×≤5 → BPDT partition table
│       ├─ BPDT entry ×N        (named by type: "Bring Up", "ROM Boot Extensions", …)
│       └─ BPDT partition ×N → (body $CPD) CPD… / (S-BPDT) recursive
└─ Padding ×N
```

`GbE` and `PDR` are **sibling** flash regions, not children of ME: GbE shows
MAC + version only; PDR is a raw-area FFS scan.

**Depth per component.**
- **FPT** — full table. Header: entry count, versions, flash cycle
  life/limit, UMA size, flags, FITC, checksum (v2.1 adds ticks/tokens/SPS
  flags/CRC32). Each entry → node named by its 4-char `Name`. The `FTPR`/`RBEP`
  partition is scanned for the `$MAN`/`$MN2` signature to fill the ME version.
- **IFWI 1.6/1.7** — full header (Data/Boot1–5 offset/size pairs +
  checksum/flags).
- **BPDT** — full table; entry/partition named by type (0–50). S-BPDT is
  parsed recursively.
- **CPD** — full table (rev1/rev2). Entry → node named by its 12-char
  `EntryName` + Huffman flag. Partitions are classified **only three ways** by
  name suffix: `.man` → Manifest (parses `CPD_MANIFEST_HEADER` + extensions
  area), `.met` → Metadata (Huffman flag + **SHA-256** + extensions area),
  anything else → Code (Huffman flag + SHA-256 + **raw-area FFS scan**).
- **CPD extensions** — node per extension named by type; **only**
  `Signed Package Info` is parsed further (package name, VCN, SVN, usage
  bitmap).
- **GbE** — MAC + version. **PDR** — FFS scan.

**What UEFITool does NOT do for ME.**
- No decryption.
- No signature verification (the CPD manifest header is parsed and shown, but
  the RSA signature is never checked; the SHA-256 hashes are fingerprints, not
  verification).
- No Huffman decompression (compressed modules stay compressed; UEFITool only
  reads the compressed size from the `.met` Module-Attributes extension and
  prints "Huffman compressed: Yes").
- No config-record display (PDR is an FFS scan, not a decode).
- **No deep component parsing.** EFS / MFS / IUP / GSC / OROM / HAP / PCHInit /
  RBEPM are **not parsed as structures**. If present, they surface only as CPD
  "Code" partitions named by their 12-char CPD name (a node literally named
  `EFS`, `MFS`, `IUP`, `HAP`, …) carrying a SHA-256 hash + Huffman flag + a
  generic FFS raw-area scan (which normally finds nothing). No EFS file list,
  no MFS file list, no IUP→GSC→OROM, no HAP policy decode, no PCHInit records,
  no RBEPM.

**Data representation.** `TreeItem` stores `header`/`body`/`tail` byte ranges;
tree columns are `Name | Action | Type | Subtype | Text`; offset/size live in
the per-node **Info** string (role `0x0100`), not columns. The hex view shows
the node's full bytes with the header span highlighted.

### 1.2 Our parser (`MEFirmwareAnalyzer` → `FirmwareAnalysis`)

**Pipeline.** Two stages: Stage 1 structural (no database), Stage 2
identity-gated (awaits the live-fetched `MEA.dat`). Reached through
`MEFirmwareAnalyzer.analyze(region:baseOffset:)`
(`Packages/MEFirmware/Sources/MEFirmware/Engine/MEFirmwareAnalyzer.swift`).

**Result.** `FirmwareAnalysis`
(`Packages/MEFirmware/Sources/MEFirmware/Models/FirmwareAnalysis.swift`) — a
`Codable`, additive-only model, `EngineModelRevision.current = 38`, ~45
top-level fields. Mostly flat lists (one recursive tree: the MFS home
directory). Most structures carry **absolute offsets** that map onto image
byte ranges.

**Presentation.** `MEACurator.present(_:)`
(`Modules/MEATool/Sources/MEATool/MEACurator.swift`) turns the analysis into a
curated tree of `MEANode` (`title`, `subtitle`, `range: Range<UInt64>?`,
`fields: [MEAField]`, `children`, `marks`).

**Depth — deeper than UEFITool.** We parse what UEFITool does not have at
all:
- **EFS** — volume + files (`EFSVolume`, `EFSFile`).
- **MFS** — volume + FAT-chained files (`MFSVolume`, `MFSFile`, `MFSBackup`).
- **IUP → GSC → OROM** (`GSCInfo`, `GSCOROMImage`).
- **HAP** policy, **PCHInit** records, **RBEPM**.
- **CSE layout** (`CSELayoutTable`/`CSELayoutPartition`).
- **BPDT**, **CPD** (modules + extensions), **OEM config**, **unlock tokens**,
  **checksums**, **issues**.

### 1.3 Side by side

| | UEFITool | Our MEFirmware |
|---|---|---|
| **Results** | FPT, IFWI, BPDT, CPD, manifest, extensions, GbE (MAC/ver), PDR | All of the above **+** EFS, MFS, IUP→GSC→OROM, HAP, PCHInit, RBEPM, CSE, OEM, unlock tokens, checksums, issues |
| **Representation** | `TreeItem` (header/body/tail bytes) + Info strings (console-style) | Typed `Codable` model + curated `MEANode` tree (UI-style) |
| **Depth** | Stops at CPD code modules (name + SHA-256 + FFS scan) | Descends into every component |
| **Signature** | Shown, not verified | Verified (`rsaSignatureValid`) |
| **Huffman** | Not decompressed | Decompressed where applicable |
| **ME detection** | Flash descriptor, type 0x02 | Same, via `LazyUEFITree.region(.me)` |

**Takeaway.** Our depth is **not** something to reconcile with UEFITool —
UEFITool simply does not have it. UEFITool is the reference for the **upper
levels** (FPT/IFWI/BPDT/CPD), where our results should agree structurally.
Anything we show below the CPD code modules is a deliberate delta, not a bug.

---

## 2. Which ME results are useful in the UEFI tree

The question is which ME structures can be grafted as **nodes with a byte
range** in the UEFI tree (so they can be revealed / zoned), versus shown as
information-only leaves.

**Mappable to an absolute image range** (usable as reveal/zone nodes):
- `FPTRegion` — offset relative to region start + `baseOffset`, plus size.
- `CSELayoutPartition`.
- `BPDTPartition`.
- `CodePartition` — absolute offset.
- `CPDModule` — offset **relative to the `$CPD` base**; absolute =
  `codePartition.offset + module.offset`.
- `CPDExtension` — absolute offset.
- `MFSVolume`, `EFSVolume` — absolute offsets.
- `OEMConfiguration` — offset + payloadOffset.
- `GSCInfo`, `GSCOROMImage`.
- `MMEModuleDirectory` / `MCPHeader`.
- `UnlockTokenFlags` — offset + size 0x20.

**Not mappable to a single image range** (information-only leaves, no zone):
- `Manifest` — has an offset but no length.
- Huffman-compressed CPD modules — compressed size known, true size lives in
  the `.met`.
- `MFSFile` — FAT-chained, no single range.
- `EFSFile` — `dataOffset` into the assembled data area, may span pages.

So the ME branch in the UEFI tree shows the mappable structures as
**expandable / revealable** nodes and the rest as **information leaves**.

---

## 3. Design

### 3.1 The core tension

- The **UEFI tree** is a structural byte tree of `UEFINode`, computed
  **synchronously** from the file (`TreeMaterialization`), in the `UEFIImage`
  package.
- The **ME tree** is a semantic analysis tree of `MEANode`, built
  **asynchronously** (awaits the live `MEA.dat`) from a `FirmwareAnalysis`, in
  the `MEFirmware` + `MEATool` packages.

Two different kinds of data, in two independent packages, presented by two
tool-modules.

### 3.2 The seam (confirmed in code)

- `TreeMaterialization.children`
  (`Packages/UEFIImage/Sources/UEFIImage/TreeMaterialization.swift:122-125`):
  `case .region:` → `parser.scanRawArea(...)`. This is where a region's
  children come from.
- But the ME region node is created with `isExpandable: false`
  (`FlashRegionType.readsAsRawArea` is false for ME), so it **never reaches**
  that switch — the `guard node.isExpandable` at line 97 returns empty first.
- The UEFI outline is driven by `UEFITreeRow` (keyed by `NodeID`) →
  `tree.node(id)` → `UEFINode`
  (`Modules/UEFITool/Sources/UEFIToolUI/UEFIToolViewController.swift:827-970`).
  Every data-source method resolves a `NodeID` back to a `UEFINode`.
- The ME outline is driven **directly** by `MEANode` values
  (`Modules/MEATool/Sources/MEAToolUI/MEAToolViewController.swift:853-865`).

### 3.3 Recommended approach: graft the ME tree as a sub-tree of `MEANode`

Reuse, without rewriting:
- **Parsing** — `MEFirmwareAnalyzer.analyze(region:baseOffset:)` →
  `FirmwareAnalysis` (already the shared `Packages/MEFirmware`).
- **Presentation** — `MEACurator.present(analysis:)` → `[MEANode]` (currently
  in `MEATool`).
- **Caching** — `PaneUEFIState.cachedAnalysis` + the `MEAToolModule.reparse`
  flow (already shared: `host.snapshot()` → `tree.region(.me)` → cache check →
  `analyze` → `setCachedMEAnalysis` → `present`).

**Mechanics.** The ME region node in the UEFI tree, on expand, triggers the ME
analysis (if not cached) and presents its `MEANode`s as its children. The
asynchrony is already solved by the cache in `PaneUEFIState` — the UEFI
Structure and the ME Analyzer **share** the same cached `FirmwareAnalysis`.

### 3.4 Why not "make the ME children `UEFINode`s"

Considered and rejected:
1. `UEFINodeKind` is a **closed** enum of UEFI concepts. ME structures (FPT /
   CPD / MFS / EFS / GSC / HAP / PCHInit / RBEPM) do not fit; a catch-all kind
   would lose the type distinction the ME tree is built on.
2. `UEFIImage` would have to depend on `MEFirmware` — polluting a general UEFI
   parser with one firmware family.
3. `TreeMaterialization.children` is **synchronous** and returns `[UEFINode]`;
   the ME analysis is **asynchronous**. Making the materialization path async
   ripples through `LazyUEFITree.expand`, `materializeAll`, `protectedRanges`.
4. **Detail panel** — `UEFINode` has no `fields` concept; the ME detail is
   `fields: [MEAField]`. The UEFI detail panel would need special-casing.

The `MEANode` graft reuses **all** the ME code, keeps `UEFIImage` clean, and
keeps the materialization synchronous. The cost is a heterogeneous outline in
the UEFI Structure.

### 3.5 Package implications

Project rule: **a tool-module never depends on another tool-module.** So
`UEFITool` cannot depend on `MEATool` to reach `MEANode`/`MEACurator`. The ME
presentation must move to a **shared package**:

- **New package** `Packages/MEPresentation` (one target/product
  `MEPresentation`): `MEANode`, `MEACurator`, `MEAZones`, and the ME detail
  model move here. It depends on `MEFirmware` (for `FirmwareAnalysis`).
- `MEATool` and `UEFITool` both depend on `MEFirmware` + `MEPresentation`.
- `MEFirmware` stays the **parsing engine only**.

This is exactly what the rule "code two tool-modules both need moves to a
shared package under `Packages/`" prescribes.

---

## 4. Implementation plan

Written before the build, and kept as it was written: the steps below are the
order the work was done in, and all six are in the tree. Read them as the
record of how it was built rather than as instructions.

### Step 1 — Extract `Packages/MEPresentation`

- Create `Packages/MEPresentation/Package.swift`
  (`swift-tools-version: 5.9`, `platforms: [.macOS(.v14)]`, header comment
  saying what it is and why it is a package of its own). Depends on
  `MEFirmware`.
- Move out of `Modules/MEATool/Sources/MEATool/` (the pure target) into
  `Packages/MEPresentation/Sources/MEPresentation/`:
  - `MEANode.swift` (`MEANode`, `MEAField`, `MEASummaryTone`).
  - `MEACurator.swift`.
  - `MEAZones.swift`.
  - The ME detail **model** (what fields to show, in what order, with what
    tone) — the pure part, not the AppKit view.
- `MEATool` (pure) drops those files and gains a dependency on
  `MEPresentation`. Its tests move with the code.
- **Resolve during this step:** which symbols are pure vs. AppKit. The ME
  detail *rendering* (`renderDetail` in `MEAToolViewController`, the UI target)
  is AppKit and stays per-tool; what the UEFI Structure needs is the `fields`
  model, which is pure. If both tools render `fields: [MEAField]` the same
  way, a small shared rendering helper can live in `MEPresentation`; otherwise
  each tool renders its own. Decide when the move is in front of us.
- `xcodegen generate`.

### Step 2 — Wire `MEPresentation` into both tools

- `Modules/MEATool/Package.swift`: `MEATool` and `MEAToolUI` depend on
  `MEPresentation` (they already depend on `MEFirmware`).
- `Modules/UEFITool/Package.swift`: `UEFIToolUI` gains a dependency on
  `MEPresentation` (and `MEFirmware`, if it needs the model types directly).
- List `MEPresentation` in `project.yml` `packages:`.
- `xcodegen generate`.

### Step 3 — Graft the ME sub-tree into the UEFI outline

- `Modules/UEFITool/Sources/UEFIToolUI/UEFIToolViewController.swift`: make the
  outline data source heterogeneous. A row stands either for a `UEFINode`
  (via `NodeID`, as today) or for an `MEANode` (via an ME path under the ME
  region node). Extend `UEFITreeRow` to carry one of the two (or introduce a
  small display-node wrapper the data source switches on).
- The ME region node (kind `.region`, subtype ME) is the graft point. When it
  is expanded, its children come from the cached `FirmwareAnalysis` via
  `MEACurator.present` instead of from `scanRawArea`.
- The expand trigger runs the shared analysis flow (the same one
  `MEAToolModule.reparse` uses), reading the ME region bytes in chunks through
  the snapshot and calling `MEFirmwareAnalyzer.analyze(region:baseOffset:)`,
  caching into `PaneUEFIState`. If the ME Analyzer already fetched it, reuse
  the cache and skip the network.
- `isExpandable` for the ME region node: it must offer the disclosure triangle
  even though `UEFIImage` marks it non-expandable. The UEFI Structure's
  `isItemExpandable` answer for the ME region node is "yes, it has ME content"
  — handled in the view controller, not by changing `UEFIImage`.

### Step 4 — Detail panel

- The UEFI Structure detail panel renders both `UEFINodeDetail` (as today) and
  the ME detail (`fields: [MEAField]`) for an `MEANode` selection, reusing the
  ME field rendering.

### Step 5 — Zones and reveal

- Mappable ME nodes: reveal / zone their `range` in the dump, using the same
  `MEAZones` / reveal path the ME Analyzer uses.
- Information-only leaves (manifest, Huffman modules, MFS/EFS files): no zone;
  show their fields in the detail panel only.

### Step 6 — Tests

- `MEPresentation` tests (moved from `MEATool`): the curator builds the same
  tree from a fixture `FirmwareAnalysis`.
- UEFI Structure: a fixture image with an ME region expands to the ME sub-tree;
  selecting a mappable node reveals the right range; selecting an info leaf
  shows its fields and no zone.
- Run the touched classes via `Scripts/run-tests.sh -o <regex>` (not the full
  sweep — the user runs the sweep).

### Verification artifact (optional, before or alongside Step 3)

Not produced. The claim it was meant to make concrete — that our upper levels
match UEFITool's layouts — rests on the research summary in section 1, not on
a byte-for-byte struct diff against `common/me.h` / `ffs.h`. Nothing that
shipped depends on the artifact, and the appendix below still lists the files
such a diff would be made against.

---

## 5. Decisions, since closed

1. **New package vs. fold into `MEFirmware`.** A separate
   `Packages/MEPresentation` was extracted, as the plan assumed: the engine
   stays in `MEFirmware`, and the tree both panels present lives one package
   along, over the `MEANode` the plan settled on rather than `UEFINode`s.
2. **Detail rendering: shared helper vs. per-tool.** Per-tool, over a shared
   model. `MEAField` is `MEPresentation`'s, and each panel renders it its own
   way — the ME Analyzer into its wrapping label rows, the UEFI Structure into
   its `UEFIDetailField` rows, which is what lets a grafted node carry its
   fields into a detail panel that was not built for it.

---

## Appendix — UEFITool reference files

For the byte-for-byte struct verification, the `new_engine` sources to diff
against:

- `common/meparser.cpp` — ME entry + FPT + IFWI 1.6/1.7 partition tables.
- `common/ffsparser.cpp` — `parseMeRegion` / `parseGbeRegion` /
  `parsePdrRegion` (region wrappers), `getMeVersionFromPartition`,
  `parseBpdtRegion`, `parseCpdRegion`, `parseCpdExtensionsArea`.
- `common/me.h` — `FPT_HEADER`, `FPT_HEADER_21`, `FPT_HEADER_ENTRY`,
  `IFWI_16/17_LAYOUT_HEADER`, `ME_VERSION`.
- `common/ffs.h` — `BPDT_HEADER`/`ENTRY`, `BPDT_ENTRY_TYPE_*` (0–50),
  `CPD_SIGNATURE` (`$CPD`), `CPD_REV1/2_HEADER`, `CPD_ENTRY`,
  `CPD_MANIFEST_HEADER`, `CPD_EXTENTION_HEADER`, `CPD_EXT_TYPE_*` (0–50).
- `common/gbe.h` — `GBE_MAC_ADDRESS`, `GBE_VERSION`.
- `common/descriptor.cpp` — ME = descriptor region type 0x02 via
  `MeBase`/`MeLimit`.
