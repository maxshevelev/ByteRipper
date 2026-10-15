# Reading the ME Region Report

> What the two tabs of the ME Analyzer panel report, and how the individual rows of the summary are to be read.

@covers panel.me.state-basis
@covers panel.me.manufacturing

**Tools ▸ ME Analyzer** analyses the [[term:me-region|ME region]] of the image in its pane and reports the result on two tabs, **Summary** and **Full Info**. The tool itself is described in [[topic:tool-me|ME Analyzer]]; this page covers the content of the report.

The row labels of the summary are in English in every language of the interface. They are the labels of the `MEA.py` script of the ME Analyzer project, from which this analysis is derived, and they are left unchanged so that a report can be compared with that project's output. See [[topic:provenance|Where This Knowledge Comes From]].

## When no firmware is reported

The tool reports that nothing in the file reads as Intel ME firmware in three distinct cases, which it does not distinguish between:

- the image holds no ME region — an AMD platform, a platform older than the ME, or a dump of a different chip;
- the descriptor declares an ME region whose content has been erased. The [[topic:tool-uefi|UEFI Structure]] tool reports the declared region, and the hex view shows whether it consists of `FF`;
- the region is present but its beginning is damaged to the point where the [[term:fpt|$FPT]] table is not found.

## The summary rows

- **Family**, **Version**, **SKU**, **Release**, **Date** — read from the manifest and the partition table. The version identifies the generation of the platform the firmware was built for.
- **Type** — whether the image is a complete firmware, an update, or a region extracted from a complete image.
- **Chipset**, **Chipset Stepping**, **NVM Compatibility** — the platform the firmware declares support for.
- **TCB Security Version Number**, **ARB Security Version Number**, **Version Control Number** — the counters the platform uses to refuse firmware older than the one already accepted. See [[term:svn|SVN]] and [[term:vcn|VCN]].
- **Production Ready** — whether the firmware is a production build or a pre-production one.
- **OEM Configuration** — whether the image carries a manufacturer's signing key or an unlock partition.
- **FWUpdate Support** — whether Intel's own update utility can rewrite this image in place.
- **Size** — how far the firmware reaches from its `$FPT`. This is a property of the firmware, not the length of the region or of the file.
- **Flash Image Tool** — the version of Intel's Flash Image Tool that the image was built with, where the image records it.
- **File System State** — described in the next section.
- **Manufacturing**, **Manufacturing basis**, **Boot Guard**, **OEM Public Key Hash** — described in the section after it: what a dump says about closing Manufacturing, about the Boot Guard profile the image is built for, and about the manufacturer's key.

Rows the analysis cannot answer for the family in question are left grey rather than filled with a guess.

## File System State

The row reports the state of the [[term:mfs|MFS]] file system inside the region. It is shown only for the families that have one. It takes three values, and the criteria by which the parser decides between them are the following.

**Initialized.** Either the volume holds at least one of the low-level files with the indices 0–5 or 8, or an EFS volume in it holds file content. This is the state of a region in which the engine has run and written its own files.

**Configured.** The volume holds no such file, but holds a low-level file with index 7 or 9 — the OEM configuration and the Home Directory — or the image holds a configuration written by Intel's Flash Image Tool: a populated `fitc.cfg` module, or a `FITC`, `CDMD` or `MFSB` partition. This is the state of a region that has been given a configuration but in which the engine has not yet run.

**Unconfigured.** Neither of the above applies. This is the state in which the firmware leaves the manufacturer of the platform, and the state of a region whose file system has been removed.

A transition connects the states. The first power-on of a board carrying a clean region in the **Configured** state, with a working chipset, initializes it: the engine creates the files and binds the region to that chipset, which is to say moves it to **Initialized**.

Two qualifications apply to the criteria:

- On CSME 15 and 16 the volume names its files through its own tables rather than by index, so the parser claims nothing from the file indices there. Such a volume is decided by the two remaining rules only.
- A fourth value, **Error**, exists in the upstream project for the case of the analysis failing outright. The decoders used here do not raise it.

Directly under the state, on the **Summary** tab and in the **Firmware** row of the **Full Info** tab alike, **State basis** says which of the three criteria decided it and what the others found. The value of the state is the upstream project's; the basis is this tool's own. The basis is drawn as a warning, and the state itself is then never drawn in green, when a criterion that could have raised the state could not be checked — most often an EFS partition listed in the partition table whose volume could not be read, for instance because its system page has been erased. **Configured** then means only that the configuration was found: whether the EFS holds files written by the engine, which would make the state **Initialized**, is unknown, and the EFS partition is to be examined before the state is relied upon.

## Manufacturing, Boot Guard and the OEM public key hash

Three further rows answer, from the dump alone, what is asked before an image is written to a board. None of them is the upstream project's; the labels are this tool's own and are translated.

**Manufacturing** — whether the platform closes End of Manufacturing on the first boot of a board carrying this image. Two things decide it, and the second is the one manufacturers normally rely on:

- the **access rights in the flash descriptor**. A serial image leaves the host CPU / BIOS master with the factory rights rather than the all-ones of a service image that lets the host rewrite every region, and the platform closes Manufacturing on its first boot. This is how End of Manufacturing was done before Flash Image Tool grew the setting below, and it is still how serial images that carry no setting are done;
- the **`EOM on first boot` setting** — `CsePlugin:EomNvar`, bit 0 of the MFS file `/home/mca/eom_config` — an explicit order on top of that. Manufacturers do not set it; it is set deliberately in Flash Image Tool.

A clear setting therefore does not mean Manufacturing stays open: it means the descriptor answers. The row takes these values:

- **Will close on first boot** — the setting is enabled, or it is clear and the descriptor carries the factory rights. The first power-on after this image is written closes Manufacturing, which locks the flash descriptor and, depending on the `Flexible EOM settings` beside it, the OEM configuration. What is locked cannot be unlocked in the image afterwards.
- **Will not close** — the setting is clear and the descriptor's access rights are open. This is the image a bench prepares for itself when it wants the machine to boot on and stay workable.
- **Close on first boot, with the descriptor open** — the setting is enabled while the descriptor's access rights are open. Flash Image Tool refuses to build such an image, so the two were put there by another tool or by hand.
- **Not readable from this image** — the setting is clear or absent and no flash descriptor was read with the region, which is what an ME region extracted on its own looks like. What its access rights would say is then unknown.
- **No such switch in this firmware** — a generation that does not decide this at all: before CSME 11, whose descriptors are the ones the rights are read from. The Summary tab omits the row entirely for those.

**Manufacturing basis** follows it, as **State basis** follows the file system state. It names the setting and where it was read from — the image's OEM configuration, or the file system where the image carries no such record — and what End of Manufacturing will commit. Where the setting is clear, it says which of the two mechanisms is at work instead: that the descriptor's access rights are what close Manufacturing, or that with the descriptor open nothing does.

The three rows are drawn in colour. A machine that will **not** close Manufacturing boots on and can still be worked on: green. One that **will** close, and one whose setting is enabled with the descriptor open, are drawn in the same tone the file system state is drawn in for **Initialized** — the image is committing itself, and what is written after that is final. A row that only says the image carries no record is drawn plain.

What the *board the dump was taken from* has already done is not reported. The file system of a region taken from a machine in service records that Manufacturing was closed there, but that says nothing about the machine the image is about to be written to; the row answers for the next first boot.

**Boot Guard** — the profile the image is built for, as Flash Image Tool, MEInfo and the repair tools print it: `0 - No_FVME`, `3 - VM`, `4 - FVE` or `5 - FVME`, the abbreviations standing for verified and for measured boot. The profile is the one the platform burns into the chipset's fuses when Manufacturing closes, and the fuses cannot be taken back, which is why it is worth reading before an image is written. Profile 0 is drawn in green — the machine boots unverified, and that is a state a bench works with — and a profile that names a level in the same tone the file system state is drawn in for **Initialized**. The row reports the profile the image carries; an image that carries no such record — an image whose Boot Guard was configured by another tool, or a generation that records the setting elsewhere — is reported as **No profile record in this image**, and the profile has to be taken from the board itself with MEInfo. No row reports what a board will do when the image and the fuses disagree, because nothing in the dump says what the fuses hold.

**OEM Public Key Hash** — the SHA-384 hash of the public key the manufacturer's signing key manifest is signed with, in the ME region, as 96 hexadecimal digits. It is the value Flash Image Tool's *OEM Public Key Hash* setting carries and the repair tools print in their reports; two dumps of the same board carry the same hash, and it is what a key manifest is checked against. All zeros in that setting disables signing of the manufacturer's key manifest. The row reports **No key material in this image** when the region carries no such value, which is the answer both for a region whose area was erased and for one whose setting is all zeros: a run of zeros cannot be told from an unwritten area, so the tool claims a hash only where the bytes are there.

## Moving a region to another board

A region in the **Initialized** state holds more than settings written by the engine on one particular board. The files of its [[term:mfs|MFS]] file system are protected by an [[term:integrity-table|integrity table]], and some of them are encrypted as well, integrity and confidentiality being protected by separate keys. Those keys derive from the [[term:svn|SVN]] and from a root secret held in the chipset's fuses, unique to the individual part; that secret is not in the image. The binding is established at initialization — at the first power-on of a board carrying a region in the **Configured** state.

Moving an initialized region to another board is therefore incorrect in itself. Two limits apply, and they are independent of each other:

- **The data are bound to one part.** A region transferred whole and unaltered remains another chipset's region: a different chipset derives different keys and does not accept the protected files. An identical board model and an identical chipset model make no difference — the secret is unique to the part, not to the model.
- **Editing is detected separately.** The engine verifies integrity before it starts, so a region altered in place is rejected whoever it belongs to.

The state in the row is the fact the tool reports. What a board will do with a foreign region is not: there is no single outcome, and it depends on the generation of the chipset, on the particular board and on its system configuration. The repair community reports a slow power-on, individual functions not working afterwards, a reset on a timer, and on current chipsets no power-on at all.

An **Unconfigured** region from a manufacturer's update package carries no per-board values at all, including those of the board the firmware was built on.

Intel's **Flash Image Tool**, part of the manufacturer's CSME kit, is the tool that produces a configured region from a firmware image and a configuration file. It is named here because the **Flash Image Tool** row reports its version, and because the `fitc.cfg` module it writes is one of the criteria above. It is not related to the [[term:fit|Firmware Interface Table]], which the [[topic:tool-fit|FIT Table]] panel reads, despite the shared abbreviation.

! ByteRipper does not build ME regions, does not configure them and does not write to a board. It reports what the region in the open file contains.

## The Full Info tab

The tab holds the structures the analysis decoded, as a tree in which every row corresponds to actual bytes of the file:

- **[[term:fpt|$FPT]]** — the partition table, listing the partitions the region declares, with their addresses and lengths. A partition whose bytes are not present, or whose declared length does not agree with the region, is reported as such.
- **[[term:cpd|Code partitions]]** and their modules.
- **[[term:manifest|Manifests]]** and their extensions.
- **[[term:mfs|MFS]]** — the file system and its configuration, which is where the **File System State** above is decided.
- **[[term:oem-config|OEM configuration]]** and **[[term:utok|unlock tokens]]**, where present.

Selecting a row scrolls the dump to those bytes and outlines them. The detail list under the tree holds the fields of the selected structure's header. An erased partition, or one of zero length, is shown in grey: it is a declared place in the layout that holds nothing.

## Copying the report

The two buttons in the tab bar copy the **Summary** tab either as text or as an image of the panel.

The glossary explains the terms the tool uses: select a row and press **?** beside the detail list to open the article for that row.
