@term flash-descriptor
@name Flash descriptor
@short The first `0x1000` bytes of an Intel flash image: the map of the chip.

The descriptor sits at the very start of the dump and says where every [[term:region|region]] begins and ends, which masters may read or write each one, and how the chip's own straps are configured.

It is the one structure here with real vendor documentation — it is described in Intel's chipset programming guides — so what the panel says about it rests on more than reverse engineering.

On a bench it is the first thing to look at: if the descriptor is damaged, every offset that follows is unreliable, and the board usually will not start at all.

@see term:region
@see topic:tool-uefi

@term region
@name Region
@short A top-level area of the flash, defined by the descriptor.

The descriptor divides the chip into regions — descriptor, BIOS, ME, GbE, PDR, EC and others — each with a start and an end address. A region is the unit a bench usually moves between images, because each one is a self-contained format.

@see term:flash-descriptor
@see term:bios-region
@see term:me-region

@term bios-region
@name BIOS region
@short The firmware the CPU executes: volumes, files and sections.

The largest region on most images. Inside it are [[term:volume|firmware volumes]], and inside those the [[term:ffs-file|files]] and [[term:section|sections]] that make up the UEFI firmware itself — the boot code, the setup screens, the drivers.

This is the region a firmware update replaces, and the one most BIOS repairs are about.

@see term:volume
@see topic:tool-uefi

@term me-region
@name ME region
@short Intel Management Engine firmware — a separate processor's operating system, in its own region.

The ME (on newer platforms CSME) is a small independent processor inside the chipset with its own firmware, stored in its own region of the same flash chip. It runs before and alongside the main CPU and handles power management, provisioning and security functions.

It has nothing to do with the BIOS's own code and is a completely different format, which is why ByteRipper has a [[topic:tool-me|separate panel]] for it.

! The ME verifies its own firmware before running it. A hand-edited ME region does not become a patched ME — it becomes a board that hangs or reboots on a timer.

@see topic:tool-me
@see topic:recipe-me-check

@term gbe-region
@name GbE region
@short The integrated network controller's configuration — including the board's MAC address.

Small, and board-unique. Copying a donor's GbE region onto a board gives it the donor's MAC address.

@see topic:recipe-board-data

@term pdr-region
@name PDR region
@short "Platform Data Region" — an area the board vendor may use for its own data.

What is in it depends entirely on the vendor. Treat it as potentially board-specific: if a donor image has one and yours does, compare them before overwriting.

@see topic:recipe-board-data

@term ec-region
@name EC region
@short Firmware for the embedded controller — the small chip that runs the keyboard, fans, battery and power sequencing.

On laptops the EC firmware is sometimes in the same SPI chip as the BIOS, as its own region, and sometimes in a chip of its own. A board that does not power on at all, or that powers on and immediately shuts down, is often an EC problem rather than a BIOS one.

@term volume
@name Firmware volume (FV)
@short A container inside the BIOS region, holding files. Its header starts with `_FVH`.

A firmware volume is the unit the firmware's own file system is built on. A BIOS region usually holds several: a boot block volume, one or more main volumes, an NVRAM volume.

A volume's header declares its length and its own checksum, and the space after its last file is its **free space** — which tells you how much room is left in it.

@see term:ffs-file
@see term:free-space

@term ffs-file
@name FFS file
@short One file inside a firmware volume, identified by a [[term:guid|GUID]].

Files are what a volume holds. Each has a GUID for a name, a type (a driver, an application, raw data, a volume image) and a header with its own checksums. Inside a file are [[term:section|sections]].

A row with a readable name like "DxeCore" is an FFS file whose GUID the [[topic:databases|catalogue]] recognises.

@see term:section
@see term:pad-file

@term pad-file
@name Padding file
@short A file that exists only to fill space so the next real file starts where it should.

It has a GUID because every file header does — usually all ones — and that GUID names nothing. Nothing is lost by ignoring it.

@term section
@name Section
@short A part of an FFS file: its code, its name, its version, or another whole volume.

A file is made of sections, and sections can nest. The common ones are the executable image (PE32), a compressed section (which holds more sections inside it), a user-interface section (the readable name of the file) and a version section.

A **compressed section** can be opened decompressed in ByteRipper — the panel expands it and shows you what is actually inside.

@see topic:fragments

@term free-space
@name Free space
@short The unwritten room left in a volume after its last file.

Listed by the panel on purpose: it is what tells you whether a module could be added to a volume, and its size is a quick sanity check that the volume's own length field is right.

@see term:padding

@term padding
@name Padding
@short Space between structures that nobody wrote to.

Erased padding is a dump's filler — usually `FF`. The tree hides it unless you ask for it, because a large dump is full of it and a row standing for nothing is a row to scroll past.

Padding that **holds data** is always listed: something is there, whether or not the parser knows what.

@see term:free-space

@term nvram
@name NVRAM
@short Where the firmware keeps its settings between boots: setup options, boot order, Secure Boot keys.

NVRAM lives in its own area of the BIOS region, in a format that depends on the firmware vendor. ByteRipper reads the common ones — [[term:vss|VSS/VSS2]], FTW, EVSA, FDC and a few vendor-specific stores — and lists the variables in them.

On a bench NVRAM matters for two reasons: it is usually safe to take from a donor (the firmware rebuilds what it needs), and corruption there is a common cause of a board that hangs at the vendor logo or forgets its settings every boot.

@see term:vss
@see topic:recipe-board-data

@term vss
@name VSS / VSS2 store
@short The most common NVRAM format: a store of named variables.

Each entry is a variable with a name (`BootOrder`, `PK`, `Setup`), a vendor GUID and a value. ByteRipper names the entry by its variable name rather than by its GUID, because many variables share one vendor GUID.

Related stores you may see in the same area: **FTW** (a fault-tolerant write record, the journal that makes a variable update survive a power cut), **EVSA**, **FDC**, **CMDB** and vendor flash maps. They are different vendors' answers to the same problem.

@see term:nvram

@term slic
@name SLIC / MSDM
@short Windows OEM licence data stored in the firmware.

An ACPI table the firmware publishes so that a pre-installed Windows activates without a key. On older machines it is SLIC; on newer ones MSDM. It is board- and licence-specific: overwrite it with a donor's and the machine may stop activating.

@see topic:recipe-board-data

@term capsule
@name Capsule
@short An update file wrapped in a header, rather than a raw chip image.

A firmware update downloaded from a vendor is often a capsule: the image plus a header that says what it updates and how. ByteRipper reads through the wrapper and shows what is inside.

If a file opens as a capsule, remember that it is an **update**, not a dump — it may not contain every region the chip has.

@term microcode
@name Microcode update
@short A patch for the CPU itself, loaded before any firmware code runs.

Intel ships microcode updates inside the firmware image. The CPU loads the one matching its signature very early in the boot, through the [[term:fit|FIT]].

Each update carries its CPU signature, a revision number and a date in its header, which is how ByteRipper names them.

@see term:fit
@see topic:recipe-microcode

@term fit
@name FIT (Firmware Interface Table)
@short A table of things the CPU must load before executing BIOS code.

The FIT is found through a pointer at a fixed address near the top of the flash. Its entries point — by absolute address — at [[term:microcode|microcode updates]], ACMs, Boot Guard manifests and policy records.

Because the addresses are absolute, nothing a FIT points at may move. A FIT entry pointing into erased flash is a board that does not post at all.

@see topic:tool-fit
@see topic:recipe-microcode

@term boot-guard
@name Boot Guard
@short A hardware check that parts of the firmware are signed by the board vendor.

On a platform with Boot Guard fused on, the CPU verifies a signed manifest over declared ranges of the flash before running any of it. Those **protected ranges** are named in the image, and the [[topic:tool-uefi|UEFI panel]] counts them in its summary line.

! Bytes inside a protected range cannot be changed. The signature will not match, and it cannot be recomputed without the vendor's private key. No tool fixes this; it is the point of the feature.

@see topic:bench-safety

@term top-swap
@name Top Swap
@short A chipset feature that swaps in a second copy of the boot block if the first fails.

The board keeps two boot blocks and a chipset bit chooses which one the CPU sees. It is a recovery mechanism: a bad flash of one copy can be survivable.

Worth knowing on a bench because it means an image may legitimately contain two nearly identical boot blocks, and a comparison will show them both.

@see topic:tool-fit

@term vscc
@name VSCC table
@short The list of flash chips the descriptor knows how to drive.

"Vendor Specific Component Capabilities": for each supported chip, the commands and timings the chipset should use with it. If a board was repaired with a flash chip whose ID is not in this table, the on-board flashing path may not work — an external programmer still will.

@see term:flash-descriptor

@term non-uefi-data
@name Non-UEFI data
@short Bytes inside the image that the parser does not recognise as any known structure.

Not an error. Vendors put their own data in firmware images all the time, and an EC image or an option ROM inside a BIOS region is a format of its own.

It is, however, where to look when something does not add up: a region that should be volumes and reads as non-UEFI data is a corrupted region.

@see topic:tool-zones
