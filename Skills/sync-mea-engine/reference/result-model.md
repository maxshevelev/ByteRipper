# UI-facing result model — `FirmwareAnalysis`

The whole point of the Swift engine is one typed, `Codable` result tree that
ByteRipper's UI renders after it analyses an ME/engine region of a dump. It is
the "structured output for UI": no parser writes text tables (as MEA.py does
for a console); every decoder and the pipeline feed this model. The pipeline
is reached through the module's async API and awaits its (live-fetched, never
stored) databases where identification needs them — see reference/async-api.md.

File: `Packages/MEFirmware/Sources/MEFirmware/Models/FirmwareAnalysis.swift`

## Invariants (do not break these)

- **Codable and additive-only.** UI binds by field name. A sync may add fields,
  enum cases, or nested structs; it must never rename, retype, or remove an
  existing field. That is how the engine stays safe to refresh underneath a
  shipping UI.
- **`EngineModelRevision`** increments whenever the model gains fields, so the
  UI can decide deliberately whether to surface the new data.
- **Enums are `String`-raw** so serialized/archived values stay stable across
  Swift versions.
- **Never put DB-derived text in the model.** The model carries parsed facts
  (version numbers, dates, sizes, booleans). Display labels such as
  "Management Engine", "Production", or the human firmware name belong to the
  DB layer and to the UI, not here.
- **A database *flag* may still drive a byte fact.** The rule is about text.
  Where a database says something about the bytes — `FileTable.dat`'s Integrity
  flag says an MFS/EFS file ends with an `MFS_Integrity_Table`, and its EFST
  offsets say where an EFS file starts — what the engine then reads out of the
  flash is a parsed fact and belongs here (`MFSFile.contentSize`/`.integrity`,
  `EFSVolume.files`). The file's *name* and *path*, read from the same table,
  do not: those are the panel's lookup (`MFSFileNames`, `EFSFileNames`,
  `ConfigRecordPaths`).
- **Some fields are ByteRipper's own, not upstream's.** MEAnalyzer prints no
  address for a file and no digest of it, and decides the File System State
  without saying on what. `FirmwareAnalysis.mfsStateBasis`, `MFSFile.extents` /
  `.contentDigest` / `.chainIntact` and `EFSFile.extents` / `.contentDigest`
  (revision 40) are facts the engine read out of the same bytes for the app's
  own use — the file comparison and, later, outlining a file's chunks. A sync
  keeps them, fills them, and leaves them out of any comparison with upstream's
  output. Revision 41 adds three more of the same kind, all read for the repair
  bench and none of them in upstream: `manufacturingState` with
  `manufacturingBasis` (what the platform will do with End of Manufacturing on
  the first boot of this image, from the `/home/mca/eom` and
  `/home/mca/eom_config` records of both pages, plus the flash descriptor's BIOS
  master), `bootGuardProfile` (the profile the image is built for, out of the
  CDMD configuration's JSON) and `oemPublicKeyHash` (the SHA-384 the UEP area
  repeats). The addresses, the values and the ground truth behind each are in
  `Skills/me-eom-structures/reference/structures.md`; `analyze` gained
  `descriptorBytes` for the descriptor fact alone. Revision 42 adds
  `configuration`, the ME configuration file by file as Flash Image Tool's own
  settings database lays the files out; revision 43 changes its shape, so a
  `ConfigurationFile` carries **both** copies a dump has of it — `fitc`, the OEM
  Configuration partition's record, which is what the build wrote, and `mfs`,
  the file system's own file, which is what the platform holds now — because one
  column could not tell a setting the platform rewrote from one the build
  chose. `Design/ME_STRUCTURES.md` is where that database is described.
  Revision 44 adds no field and changes one field's answer: `bootGuardProfile`
  is read out of **two** keepings of the one fact — the CDMD configuration's
  JSON, which MFIT-built images carry, and the UEP area's Boot Guard bits, which
  every CSME 15 image carries instead — so images that used to answer "no
  profile record" now answer a profile. Upstream has no such row either way.
  Revision 45 changes one more answer the same way: `oemPublicKeyHash` is read
  from the record the image's **generation** keeps — the 32-byte SHA-256 of
  CSME 12 to 14 and the 48-byte SHA-384 of 15 and later. Revision 46 adds
  `platformFamily`: which half of its chipset generation the board is — the
  mobile parts or the desktop ones — told from the length of the descriptor's
  PCH strap section, the one thing a dump states about it; and the
  configuration is now read through the map of that half, because CSME 13, 14
  and 15 lay a few settings out differently between the two. A dump with no
  descriptor keeps the mobile map, which is what every map was before. Ours,
  like the rest of these.
  Revision 47 reads the tools' **conditional places**: `ConfigurationSetting
  .condition` says which branch of a setting the tool places only under
  another setting's value an image holds (the LP family's MCTP EC address is
  in one of two files, by `eSpiEnabled`), with `assumed` where the branch had
  to be told from the files present because the condition's own value was not
  in the image; `.disabled` says the tool switches the setting off under such a
  condition and the image holds it. Ours, as the rest.
  Revision 48 adds `hardwareBinding`: whether the platform binds its SPI part
  to the chipset — Flash Image Tool's "Hardware Binding Enabled", one byte of
  `/home/bup/bup_sku/hw_binding` (the file system's copy, then the OEM
  Configuration partition's record of it), `disabled`, `enabled`, an
  `other` byte the tool's class does not name, or `notInImage`. Ours; upstream
  has no such row. Its sibling settings in the tool's `RpmcConfiguration`
  section are UEP placements, read as such by revision 49.
  Revision 50 adds `manufacturingLock`: what the board the dump came from has
  done with End of Manufacturing, from the live file system's
  `/home/mca/manuf_lock` — one byte the platform writes and no build does
  (`locked`, `open`, or an `other` byte). `manufacturingState` above answers for
  the image's next boot; this answers for the machine it was taken from. Ours;
  the record is read by neither upstream nor the tools. It is nil where the
  volume's files carry no File IDs or the table that names them was not read.
  Revision 53 adds `sphyNvar`: the SPHY OEM configuration the FITC partition's
  `phy_oem_cfg` nvar holds, read through the tool's `SphyNvar` layout
  (`SphyNvarMap`, emitted by `sphy18_map.py`) as name/value readings. The
  layout's anchors are verified first: the package carries several SPHY
  variants with identical headers. Ours; upstream reads none of it. Full Info
  shows it under "SPHY OEM configuration".
  Revision 52 adds `mipStraps`: the MIP table's other strap containers — PMC
  SoC, CSME (DBC), PMC IOE, IOE, and the five-block table's PMC SOC 2 and
  CPU 2 — each a `MIPStrapContainerReadings` read through the tool's own
  layout (`MIPStrapMap`, emitted by `mip18_map.py`). A container is matched
  by its block's type and length and may start inside that block
  (`PmcAndCpu_2` carries PMC SOC 2 at 0 and CPU 2 at 0x48). A layout is
  chosen by the block's type and length: the IOE document's MTL-M and MTL-P
  variants place the same names at different offsets. Ours; upstream reads no
  strap. The Full Info tree shows each container under its own title ("CSME
  straps", "IOE straps", "PMC IOE straps").
  Revision 51 adds `cpuStraps`: the CPU strap message a CSME 18 image keeps in
  the FITC partition's MIP table (`smip` nvar) — the fields of the tool's
  `CPU_smip` document (`CPUStrapMap`, emitted by `strap18_map.py`), plus the
  message length and its CRC-16 (`CPUStrapReadings`). Ours; upstream reads no
  strap. The older generations keep the message in the descriptor's MIP area,
  which is not part of this model. The Full Info tree shows it under "CPU
  straps", with the tool's words for the enumerated values.
  Revision 49 adds `uepSettings`: the FPF/UEP settings an image's `$UEP` area
  holds, each as the tool's identifier and the value of its bits
  (`UEPReading`). The map of places is the tool's own (`UEPMap`, emitted from
  the `GetBitArrayValue` actions). The values are what the build wrote into
  the image, not the fuses the platform later burns, and most of them are
  zero. Ours; upstream reads none of the UEP bits. The Full Info tree shows
  them under "FPF Settings", in the tool's sections.
  Revision 54 changes what that field answers on CSME 18: the tool's rewritten
  database places `PLAT_ID`, `DNX`, `RPMC_RB`, `ESE_ROM_SVN_EN`, the CSE FVC
  states and the validity bits beside them in the container's **second** array,
  and the map now says which array each setting is in (`arraySize` 0x80), so
  they are read too. The 15/16 map keeps to the first array, as before.
  Revision 55 fills the field on **CSME 12** as well: Flash Image Tool 12's CNP
  `Uep` document (`UEPMap.csme12`, emitted by `uep_fit_map.py`) places 42
  settings in the container's four 0x80-byte arrays, eight of them only in the
  later arrays (the SB SVNs, the TPM seed bits, the IDLM SVN). The values are
  what the build wrote; the Boot Guard profile proper on this generation is
  still the record `bootGuardProfile` reads, and the array's individual profile
  bits appear among the readings. Ours, as the rest of the UEP field.
  Revision 57 fills the same field on **CSME 13 and 14**, from Flash Image
  Tool 13's Ice Lake and 14's Comet Lake `Uep` documents (`UEPMap.csme13`,
  `.csme14`): 43 and 44 settings in six and four arrays. The profile bits read
  what the four FIT builds of each generation set — 0, 3, 4 and 5 — and agree
  with the record. Ours, as the rest.
  Revision 56 fills another field on CSME 12: `configuration` is read through
  Flash Image Tool 12's CNP maps (`MEConfigurationMap.csme12` and
  `.csme12Desktop`, emitted by `fit_map.py --generation 12`). That generation's
  volumes carry no `FileTable.dat`, so the engine resolves the map's
  `/home/...` paths by walking the MFS home directory instead. Ours, as the
  rest of `configuration`. Revision 58 adds **CSME 11** to the same field:
  Flash Image Tool 11's SPT map (`MEConfigurationMap.csme11`), one set of
  documents for both platform halves, its paths read the same way. Ours.
- **An added field has to be optional, not defaulted.** A Swift property
  default does *not* satisfy the additive contract: the synthesized decoder
  asks for every non-optional key regardless of a default, so a nested struct
  that grows `var files: [EFSFile] = []` stops decoding every payload written
  before the field. Declare it `[EFSFile]?` and read it as `?? []`
  (`FirmwareAnalysisTests.testNestedStructsDecodeWithoutTheirNewestFields`
  covers the ones added so far).

## Shape (starting point; bootstrap materializes it)

```swift
public struct FirmwareAnalysis: Codable, Identifiable {
    public var id: String { "\(family.rawValue)-\(variant)-\(version.text)" }

    public var family: FirmwareFamily        // .csme, .cstxe, .cssps, .gsc, ...
    public var variant: String               // e.g. "CSME", "PHYPTGP", "PCHCICP"
    public var version: Version              // parsed major.minor.hotfix.build
    public var securityVersion: String?      // SVN / VCN from the manifest
    public var release: ReleaseType          // .production / .preProduction / .romBypass
    public var type: FirmwareType            // .region / .extracted / .update
    public var sku: String
    public var platform: String
    public var manufactureDate: Date?
    public var sizeBytes: Int
    public var databaseName: String?         // unique name when found in MEA.dat

    public var rsaSignatureValid: Bool?      // nil when not checkable
    public var checksums: Checksums?         // sha256/sha384/crc of the region
    public var regions: [FPTRegion]          // FPT/partition table if present
    public var manifest: ManifestSummary?    // $MN2/$MAN facts + security fields
    public var codePartition: CodePartition? // $CPD: entries, extensions, modules
    public var chipsetInit: MFSPCHInit?      // final Chipset Initialization Tables (rev 39)
    public var issues: [Issue]               // notes / warnings / errors
}

public enum FirmwareFamily: String, Codable, CaseIterable {
    case me, csme, txe, cstxe, sps, cssps, gsc, pmc, pchc, phy, orom, unknown
}

public struct Version: Codable, Equatable {
    public var major: Int; public var minor: Int
    public var hotfix: Int; public var build: Int
    public var meMajor: Int?; public var meMinor: Int?   // MEU fields, when present
    public var text: String { ... }                       // "15.40.37.3121"
}

public enum ReleaseType: String, Codable { case production, preProduction, romBypass, unknown }
public enum FirmwareType: String, Codable { case region, extracted, update, unknown }

public struct FPTRegion: Codable, Identifiable {
    public var id: Int            // partition index
    public var name: String       // e.g. "FTUE", "rbe", "FTPR"
    public var offset: Int; public var size: Int
    public var flags: UInt32
}

public struct ManifestSummary: Codable { /* family/type/date/sku fields from $MN2 */ }
public struct CodePartition: Codable { /* $CPD entries, CSE extensions, module list */ }

public struct Checksums: Codable { public var sha256: String?; public var sha384: String?; public var crc32: UInt32? }
public struct Issue: Codable, Identifiable {
    public var id: Int
    public var severity: Severity        // .note / .warning / .error   (maps to MEA colours)
    public var message: String
    public var module: String?           // the $CPD module a module check is about (ids 7, 19)
}
```

### A fact that outgrew its nesting

`chipsetInit` (revision 39) is the worked example of the additive rule doing
its job. The Chipset Initialization Tables first arrived under
`MFSVolume.pchInit`, because the only stream then read was the volume's
low-level file 6. Upstream reads a second one — the FTPR `$CPD` module
`intl.cfg`, which it *prefers* — and on a CSME 15/16 image that is the only
copy there is: the volume holds no file 6 at all.

Moving the field would have been a rename, which this contract forbids. What
went in instead is a new top-level optional, and the old field kept its
meaning rather than its contents: `mfsVolume.pchInit` is what *that volume*
held, `chipsetInit` is the image's answer. They are equal on a legacy image,
differ where the FTPR copy replaced the volume's, and only the second one
exists on an image with no MFS. Two facts, two fields, nothing removed — and
the panel shows each where it came from.

## How upstream's console tables map to it

MEA.py prints one table per parsed structure (`FPT`, `BPDT`, `$MN2`, `$CPD`,
each `CSE_Ext_*`, module list…). Each table's rows become a nested struct in
this model; each column becomes a field. The correspondence is kept in
`upstream-map.md` so a new upstream structure has a defined target before you
port it — you never invent a model field ad hoc mid-sync.

## Versioning

- Add fields in the same order MEA.py prints / Intel's format defines.
- New nested struct → append an optional property (or new array) rather than
  nesting breaking change.
- Bump `EngineModelRevision` in the same change that adds a field.
