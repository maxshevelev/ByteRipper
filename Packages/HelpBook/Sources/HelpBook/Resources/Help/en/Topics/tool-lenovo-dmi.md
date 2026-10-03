# Lenovo DMI

> The store in which Lenovo InsydeH2O firmware keeps a machine's identity — serial number, UUID, machine type and model, the Windows key — decoded and read.

@covers panel.lenovo-dmi
@covers panel.lenovo-dmi.copy-value
@covers panel.lenovo-dmi.select-in-dump
@covers panel.lenovo-dmi.open-decoded

**Tools ▸ Lenovo DMI** finds the identity store in a Lenovo InsydeH2O image and lists what it holds.

A search of the dump for a serial number known from the sticker finds nothing on these machines: Lenovo does not keep the [[term:dmi|DMI]] fields in plain text but in a store of its own, with every byte XORed with a key. This panel shows that store in readable form.

## Where the store is

The store is three consecutive areas: the [[term:ldbg|LDBG]] change log, 8 KiB, followed by two [[term:lenv|LENV]] blocks of 4 KiB each. Its position in the image differs from one board to another, so the tool locates it by the `LDBG` signature and accepts it only if at least one of the two blocks carries the `LENV` signature at the expected place. On the images examined, the Insyde [[term:flash-device-map|flash device map]] declares the same three areas as regions of type Unknown.

If the tool finds no store, the panel says so. Either the image belongs to another platform, or the area has been cut out of it.

## What the panel shows

- **The tree**: the change log and both blocks. Opening a block lists its entries; opening the log lists its records.
- **The line above the tree** names the block the firmware reads, its generation and its number of entries.
- **The detail list** under the tree describes the row in focus. The `?` beside its name explains the term.
- **The findings** under the detail list: an empty store, a checksum that does not match, blocks that disagree.

Only the selected row is outlined in the dump, as the active zone. For an entry of a block or a record of the log, the block or the log around it is outlined as well, as an inactive zone, so the dump shows both the bytes and what they belong to. Nothing is outlined while no row is selected.

Double-clicking a row, or **Select in Dump** on its context menu, selects its bytes in the dump. **Copy Value** puts the value as the panel reads it on the clipboard.

## Which block the firmware reads

The store is kept twice, in **LENV block 1** and **LENV block 2**, so that a write interrupted by a power loss leaves one intact copy. Each block header carries a **generation**: a counter that grows as the firmware rewrites the store. On every working dump examined the two generations differ by one — 127 and 126, say — and the block with the higher number holds the more recent state. That fits a firmware that writes each new copy over the older block and numbers it one higher; the code doing so has not been read here.

The block with the higher generation is the one the firmware reads; the panel calls it the block **in use**. This rule comes from the reverse-engineering of `LenovoVariableDxe` by LenovoDMIDecryptor, and the dumps examined agree with it: the entry that the last record of the change log removes is absent from the block with the higher generation and still present in the other. When both generations are equal, the tool takes block 1, as LenovoDMIDecryptor does.

A generation of **0** does not occur on a working board. It is what a block shows when its header has been cleared, as on a store that was wiped: the firmware does not read such a block. If both blocks show 0, there is no copy to read.

Whether the firmware passes over a block whose checksum does not match and reads the other one instead is not known; the panel states this where it applies.

The two blocks may hold different values. This is normal after a write: the older copy keeps the previous values. A value to be carried to another dump is therefore taken from the block in use, and the detail list of every entry states whether the other block holds the same value.

## Open Decoded Block

**Open Decoded Block**, on the context menu of a block or of any entry in it, opens the whole block as a [[topic:fragments|fragment panel]] with its entries decoded: the serial number and the machine type read as text in the hex view and can be edited there. The header stays as stored, so the key and the checksum are visible at their own addresses.

**Update in Parent** writes the block back encoded with the key in its header and with its checksum recomputed, as one undo step in the dump. The block keeps its length and its generation, and nothing is added to the change log. Only the block that was opened is written; to change both copies, open and update each. The fragment's header carries an **XOR** badge with the key, which says that its bytes are not the file's own.

**Tools ▸ Lenovo DMI** opened on that fragment shows the block's structure: its header and its entries, read the same way as in the dump. There is no change log and no second copy in a fragment, so the panel does not say which copy the firmware reads. The checksum in the header is the one the block carries encoded, and the panel reports it valid as such. After an edit in the fragment it no longer matches and is shown in red with the value it should have; Update in Parent writes that value.

The command is offered for a block that holds entries and whose encoding was recognised; it is not offered for an empty block or for the change log.

## The entries

An entry is filed under a namespace and a type. For the SMBIOS namespace the following types are known: the Windows key, the OA3 key ID, the motherboard name, the machine type and model (MTM), the baseboard serial number, the system UUID, the baseboard platform ID and the OS preload suffix. The panel names these and shows their values as text, the UUID in the byte order SMBIOS uses.

Real images carry further types whose meaning has not been documented. The panel calls them unknown, gives their type number and shows the value as text where every byte is printable and as hex otherwise. The flags of an entry, and two fields of every entry that are zero on all images examined, are shown as they are.

## The Windows key entry

The Windows key entry holds the product key behind a 20-byte header. The header is the licensing structure of the ACPI [[term:slic|MSDM]] table, as Microsoft's specification ([[web:https://learn.microsoft.com/en-us/previous-versions/windows/hardware/design/dn653305(v=vs.85)|Microsoft Software Licensing Tables (SLIC and MSDM)]]) defines it and the Firmware Test Suite checks it ([[web:https://lists.ubuntu.com/archives/fwts-devel/2015-July/006546.html|fwts MSDM test]]). All fields are 32-bit, little-endian:

- **Version** — 1 on every dump examined; the test suite does not check it.
- **Reserved** — zero.
- **Data type** — 1, a product key.
- **Data reserved** — zero.
- **Data length** — 29 (`1D000000`), the length of the key.
- **Data** — the key itself, `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.

The first 16 bytes are therefore always `01000000 00000000 01000000 00000000`, and the panel treats them as a signature. The value shown is the key alone; the header is described in the detail list under **Key header**. The key is separated from the header only when the signature is there and the length the header gives is the number of bytes that follow; otherwise the entry is shown as bytes and marked as a problem, and **Key header** says which of the two did not hold.

## The change log

The log records what the firmware wrote to the store and when: the date and time from the real-time clock, the operation, the entry and the number of bytes. It records writes, not values. A record written before the clock was set shows its bytes instead of a date. A **Set** of zero bytes is shown as **Remove**: on the images examined the entry is absent from the newer block afterwards.

## What is known and what is not

The format was reverse-engineered from `LenovoVariableDxe` by the [[web:https://github.com/Shmurkio/LenovoDMIDecryptor|LenovoDMIDecryptor]] project; the same author's [[web:https://github.com/Shmurkio/LenovoVar|LenovoVar]], which reads and writes the store through the firmware's own protocol, confirms the entry types and the byte order of the UUID. The tool has been checked against real dumps. Where its description and the dumps disagree, the tool follows the dumps: a log record is 32 bytes long, although the field offsets in that description add up to 24, and the year in a log record is a BCD century followed by a BCD year rather than 2000 plus a byte.

Not confirmed: what the write-protect bits of a block and of an entry cause the firmware to do, which of the two block keys the log is encoded with when they differ, and what the unknown types and fields hold.

! The tool itself changes nothing in the store: an edit is made in a fragment opened with Open Decoded Block and written back with Update in Parent, and whether the board then boots with the new values has not been confirmed. A store that is empty on both blocks has been wiped or was never written: the board's serial number and UUID are not in this image, and they have to be taken from an earlier dump of this board, if one was kept, or from the sticker.

See also: [[topic:recipe-board-data|Data Unique to a Board]], [[term:dmi|DMI]].
