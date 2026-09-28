# FIT Table

> The Firmware Interface Table: what the processor is directed to load before it executes firmware code, and whether those components are present.

@covers panel.fit

**Tools ▸ FIT Table** locates the [[term:fit|Firmware Interface Table]] in the image and lists its entries.

The table is held near the top of the flash memory and is reached through a pointer at a fixed address just below `4 GB`. Every entry carries an address, a size and a type: a [[term:microcode|microcode update]], an ACM, a Boot Guard manifest, a TXT policy record.

## What the tool reports

- **The entries**, with their type, address and size, in the table's own order.
- **What each address actually holds.** The **Points at** column is not read from the entry: the tool follows the address and reports what is at it — a microcode update with a valid header, a manifest, an erased area, or nothing recognisable.
- **The rules of the table**: the header entry, the entry count, the checksum, the ordering of entries by type, the alignment of addresses, the reserved byte, and the agreement between the table and its [[term:top-swap|Top Swap]] backup where the image keeps one. The problems found are listed under the table, and double-clicking one moves the dump to the bytes it concerns.
- **The identity of each microcode**, taken from an online catalogue by processor signature, revision and date. See [[topic:databases|The Online Catalogues]]; without network access the identifiers are reported and the names are omitted.

## What the tool changes

The tool writes to the image as well as reading it. Each operation is one undo step and none of them changes the length of the file.

- **Add Microcode…** in the panel's header places a microcode component in the image and enters it in the table. The list it offers is fetched from an online catalogue, and **Choose File…** takes a microcode from a local file instead.
- **Replace Microcode** exchanges the component a row names for another.
- **Remove Microcode** takes an entry out of the table and moves the components behind it up.
- **Fix Checksum**, on the header row, writes the checksum the table should carry.
- **Copy CPUID** and **Go to Offset** are on the context menu of a row.

The conditions under which these are refused, and what each of them writes, are set out in [[topic:recipe-microcode|Microcode and the FIT]].

! Where an image keeps a Top Swap backup of the block the table is in, a change is made in both copies, and the tool refuses the change where the two copies are not identical. A change that would write inside a [[term:boot-guard|Boot Guard]] protected range is refused outright.

See also: [[topic:recipe-microcode|Microcode and the FIT]], [[term:top-swap|Top Swap]].
