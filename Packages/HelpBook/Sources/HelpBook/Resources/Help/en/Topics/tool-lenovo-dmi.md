# Lenovo DMI

> The store in which Lenovo InsydeH2O firmware keeps a machine's identity — serial number, UUID, machine type and model, the Windows key — decrypted and read.

@covers panel.lenovo-dmi
@covers panel.lenovo-dmi.copy-value
@covers panel.lenovo-dmi.select-in-dump

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

Double-clicking a row, or **Select in Dump** on its context menu, selects its bytes in the dump. **Copy Value** puts the value as the panel reads it on the clipboard.

## Which block the firmware reads

The firmware keeps two copies and reads the one with the higher **Generation**; a block with generation 0 is not used. When both generations are equal the tool takes block 1, as LenovoDMIDecryptor does. Whether the firmware passes over a block whose checksum does not match and reads the other one instead is not known; the panel states this where it applies.

The two blocks may hold different values. This is normal shortly after the firmware has written: it rewrites one copy at a time. A value to be carried to another dump is therefore taken from the live block, and the detail list of every entry states whether the other block holds the same value.

## The entries

An entry is filed under a namespace and a type. For the SMBIOS namespace the following types are known: the Windows key, the OA3 key ID, the motherboard name, the machine type and model (MTM), the baseboard serial number, the system UUID, the baseboard platform ID and the OS preload suffix. The panel names these and shows their values as text, the UUID in the byte order SMBIOS uses.

Real images carry further types whose meaning has not been documented. The panel calls them unknown, gives their type number and shows the value as text where every byte is printable and as hex otherwise. The flags of an entry, and two fields of every entry that are zero on all images examined, are shown as they are.

## The change log

The log records what the firmware wrote to the store and when: the date and time from the real-time clock, the operation, the entry and the number of bytes. It records writes, not values. A record written before the clock was set shows its bytes instead of a date. A **Set** of zero bytes is shown as **Remove**: on the images examined the entry is absent from the newer block afterwards.

## What is known and what is not

The format was reverse-engineered from `LenovoVariableDxe` by the LenovoDMIDecryptor project and has been checked against real dumps. Where its description and the dumps disagree, the tool follows the dumps: a log record is 32 bytes long, although the field offsets in that description add up to 24, and the year in a log record is a BCD century followed by a BCD year rather than 2000 plus a byte.

Not confirmed: what the write-protect bits of a block and of an entry cause the firmware to do, which of the two block keys the log is encrypted with when they differ, and what the unknown types and fields hold.

! The tool reads the store and does not change it. A store that is empty on both blocks has been wiped or was never written: the board's serial number and UUID are not in this image, and they have to be taken from an earlier dump of this board, if one was kept, or from the sticker.

See also: [[topic:recipe-board-data|Data Unique to a Board]], [[term:dmi|DMI]].
