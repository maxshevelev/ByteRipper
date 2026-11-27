---
name: ghidra-ec
description: Review an embedded-controller (EC) firmware image in Ghidra through ByteRipper's `ghidra_` tools — an ITE IT83xx/IT8227E image on the Andes NDS32 core, opened as a module of kind EC — into C that reads like source, with register names, interrupt handlers, the host interface and a module description published into the code store. Use when a person asks what an EC firmware does, which register or pin a function drives, what an EC RAM offset or host command means, or why a laptop's EC misbehaves (power, battery, fan, keyboard).
---

# An EC firmware image in Ghidra

Draft v2 (EC Manager, 2026-11-27, after the pilot). A rule marked **TBD** is settled by the first review.

An EC image is a bare microcontroller program: no PE header, no GUIDs, no
protocols, no EDK2. What it exposes and listens to are hardware registers,
interrupts and the host interface. Those take the place of UEFI interfaces.

**`ghidra-uefi` is the base. Read it first.** These parts of it apply unchanged
and are not repeated here: §2 (G1–G6), §3 rules 2–7 with S2–S6, S10, S11, S14,
V1–V15, C1–C4, K1–K8, K10, D1, D2, D3, D5, D7, §4 with X1–X7, §6, §7, and W1,
W2, W4, W5. These do **not** apply to EC: F2, F3, N1, N2, N7, N10, S1, S7–S9,
S12, S13, I1–I4, X8 in its edk2/amd/intel form, W3, W6, and every rule about
GUIDs, PPIs, protocols, depex, PCDs, POST codes and x86.

| reference | what it holds |
|---|---|
| `reference/it83xx-registers.tsv` | the register map ApplyItEc labels from: address, block, name, width |
| `reference/it83xx-irqs.tsv` | INTC interrupt number → source |

## 1. The image and its identity

- **E1.** The module is the linked image, not the region it sits in. Its extent is the end of the crt0 `.data` initializer. The SHA-256 is taken over [0, extent) with the bytes the EC rewrites set to 0 (on IT8xxx, byte +0x8D). A BIOS copy and a chip read of the same firmware are one module. Copy the module hash from a tool answer (F4).
  Why: the UEFI region is padded, and a chip read carries runtime data past the extent plus a rewritten signature byte. On IT8227E the code at 0x11F08 clears +0x8D when it is non-zero.
- **E2.** The bytes past the extent are the EC's flash data area, not the module. ApplyItEc labels each address it can show the code uses as `FlashRef_xxxxx`. Describe that area only from the code that reads or writes it, never from one dump's values.
  - ApplyItEc labels a value past the extent only when the code uses it as a flash address: dereferenced, passed to a routine that writes the SMFI ECINDAR registers (or its wrapper), or passed as separate bytes to one (`f(2, 0xA6, 0)` = 0x2A600). An address moved through a register copy before the call gets no reference; add it by hand.
  - The flash data area [extent, host_update_size) is the `eflash_data` block, with no bytes: a label there takes a type and a plate. Type it with its record format.
  Why: it differs between reads of the same chip, and a BIOS update rewrites it.
  A `FlashRef_` gets a name for its meaning only once the code proves it. That name starts with `Eflash` and keeps the address: `EflashLog_2B800`.
- **E3.** A Ghidra address is an offset in the image (flash starts at 0). The SPI address is the node start plus that offset. In a chip read, offset and address are the same. Say which one you mean.
- The host updates the EC by rewriting `host_update_size` bytes (module metadata; 0x2C000 on IT8227E). That size is not the extent.

Open the module with `ghidra_create {document, node}` on the EC image node. The answer gives its kind `EC`, family `ite-nds32` and language `NDS32:LE:32:default`.

## 2. What ApplyItEc lays out before a review

| range | block |
|---|---|
| 0x000000–extent | `flash`: vectors 0x00–0x67, `Signature` 0x80, `VersionString` 0x90, code, rodata, `DataInitSource` |
| 0x080000–0x083000 | `ram`: .data (`DataInitTarget`), .bss, the stack (SP starts at 0x83000) |
| 0xF00000–0xF10000 | `regs`: the EC registers, labelled from the map, volatile |

Named in advance:
- `ResetEntry`, `main`, `Exc_<name>` for the exception vectors.
- `Isr_Lvl<N>` for vector stubs 9–25 (N = level 0..16), plus `IsrCommonEntry`, `IsrLevelTable` and `IsrLevelHandler<N>`.
- `IsrDispatch`, which reads IVCT 0xF01110 and calls `IsrIrqTable[irq]`. Each table entry gets one `Isr_Irq<NNN>`, with the source in its plate when the IRQ map names exactly one. A handler shared by several IRQs is `Isr_IrqShared_<lowest>`, and its plate lists them.
- `PinDescTable_A` and `PinDescTable_B`, without a type.

The code that keeps running while the host reflashes the EC is mapped from flash into scratch SRAM by hardware (the SMFI SCAR registers). There is no software copy, and that code lies inside the extent.

- **E4.** A global's initial value is in `DataInitSource` at (address − `DataInitTarget`). Everything in `ram` past the initialized data starts at 0. Read the value before describing code that tests it (K2).
  Why: `ram` has no bytes in the image, so Ghidra shows `??`.

## 3. NDS32 as the decompiler sees it

- Instructions are 16 and 32 bits long and stored big-endian. Data is little-endian.
- Arguments go in $r0–$r5 and the result in $r0 ($r0:$r1 for 64 bits). $r6 and up are callee-saved through `push25`/`smw`. $gp is $r29, $lp $r30, $sp $r31. **TBD**: whether the core uses the reduced register set (push25 in this build saves only s0–s2).
- A function starts with `calling_convention: unknown`. `ghidra_signature` sets it to `default` and renames the function from the signature, so no separate `ghidra_rename` is needed.
- A 1-byte enum is written `typedef enum TAG : unsigned char { … } NAME;`. Without `: unsigned char` it is 4 bytes and breaks every byte-wide carrier.
- **E5.** A 32-bit constant is built from `sethi` + `ori`/`addi`, sometimes in a chain of three. Give `ghidra_equate` the whole value the C prints, at the last instruction of the chain. After a `slt`/`slti` bound that is the bound plus one (0x1B7741 for `< 0x1B7741`). The name lands on the C's folded constant (`in_c_only: true`). Read `in_c` in the answer. If it is refused, explain the constant in a `pre` comment at the `sethi` (N3, N5). A `movi` constant that carries meaning, such as a GPCR mode or an SMBus HOCTL value, takes an equate too. A negative `movi` followed by a byte store (`movi -0x80` + `sbi`) goes into the enum at its byte value (0x80) and the name shows at the store. ITE pin control (GPCRxn): bit 7 = input, bit 6 = output, 0x00 = alternate function (pull-up/down in bits 2 and 1); so 0x80 makes a pin an input and 0x40 an output. Check it against the code before writing a direction: an output is followed by data writes to the pin.
  Why: no single operand holds the whole value. A `sethi`/`ori` pair that builds a register address or a named RAM datum already prints by its label and needs no equate. E5 is for values.
- **E5a.** Once the first byte of `ram` (0x80000) is named as a byte array, a constant 0x80000+n can print as `Name + n` even when it is no part of that datum. UINT8 is a char type, and the decompiler lets a constant point into a char array. Read such an expression at the instructions. Where it is a value, not an access, equate it (E5) or comment it.
  Why: the DLMB value 0x80001 printed as `TaskEventPending + 1`.
- **E6.** A global reached through $gp (`lwi.gp`, `swi.gp`, `addi.gp`) is a datum at $gp + displacement. Name and type the datum. The IT8227E build reaches RAM through absolute `sethi`/`ori` instead and has no $gp access.
- **E7.** A `jral` or `jr` through a register is an indirect call. Trace the register to its `sethi`/`ori` or its table load, type the table, and name the target of every slot (K4, K7). A target inside a datum ApplyItEc defined (a string that runs too long) is code: report it, and decode it from `read` with the encoding checked against this image's own prologues (`push25` = FC 0x, `pop25` = FC 8x).
- **E7a.** A register the reset path reads but never writes (for example `ta` at ResetEntry) has an unknown value. Search the image for code that builds the entry address (`find_bytes`) before naming the branch it chooses. Without such code, write "unproven" in the plate.
  Why: the vector at 0 is a plain `j`, so nothing in the image says what such a register holds at reset.

## 4. What a review makes of the code (EC deltas to ghidra-uefi §3)

**Rule 1: names, not constants.** Most constants here are hardware registers.
- **E8.** A register gets its name only from the label ApplyItEc put at its address, which comes from the map. Never name one from memory or from another chip's datasheet. Give every register write an `eol` comment: the register, the bits set or cleared, the effect. A register with no label is `Reg_F0xxxx`, with "unmapped" in its comment. `GCTRL_WNCKR` written with 0 is a wait or sync step, not a state change. Its comment is "delay: N writes"; no time unit is claimed. Keep `Reg_F0xxxx` even when its position makes the role obvious (GPDRD between GPDRC and GPDRE). The comment says "by position, inference". List it in the report with the code that shows its role. EC Manager passes names on to the map.
  Why: IT8xxx generations move blocks around, and one wrong register name poisons every caller. Of the 215 registers this firmware touches, 60 are not in the map.
- **E8a.** When the code uses a register in a role its map label contradicts, the code wins. Leave the label. Write the real role in the `eol` comments with "map label wrong", and report the address, the label, the real role and the evidence (a table, a recurring access pattern). Never rename a register label yourself; EC Manager gets the map corrected.
  Why: the map was built for IT8320. On IT8227E, 0xF01C00–07 are SMBus channel A's HOSTA…PECERC (the older ITE layout), but they are labelled as SMBus timing registers.
- **E9.** Host command bytes (KBC 0x60/0x64, PMC1 0x62/0x66, PMC2 0x68/0x6C), EC RAM offsets, SMBus addresses and SCI query numbers are each an enum with a tag: `EC_HOST_CMD`, `EC_RAM_OFFSET`, `SMB_ADDR`, `SCI_QEVENT`. A member gets a name only from what the code does with the value (N4). An unknown one is `Cmd_0xNN_Unknown`. An `SMB_ADDR` member holds the 8-bit wire value the driver passes (bit 0 = R/W) and carries the 7-bit address in its name: `SmbAddr_Charger_09 = 0x12`.
- **E10.** A bit tested or set on a register gets its meaning in an equate or a `pre`/`eol` comment, never a bare `& 0x40`. The map has no bit names yet, so give the bit number and the effect the code shows, and mark a meaning you inferred "inference". 
- **E10a.** The NDS32 core system registers (`mtsr`/`mfsr`: INT_MASK, IVB, PSW, IPSW, ILMB, DLMB …) are not in the map. Name them as the Andes ISA does, with "Andes ISA" in the comment, and treat a field's meaning as an inference unless the code proves it.

**Rule 3: names.**
- Function names are CamelCase with a subsystem prefix. One underscore may separate a channel or instance (`SmbChB_ReadWordPec`, `PwmCh2_SetDuty`). The prefixes: `Gpio`, `Timer`, `Wdt`, `Clk`, `Eflash`, `Smb`, `Adc`, `Pwm`, `Fan`, `Kbs`, `Kbc`, `Pmc`, `Espi`, `Acpi`, `Sci`, `Batt`, `Chg`, `Pwr` (power sequencing), `Therm`, `Led`, `Kbl`, `Intc` (interrupt controller), `Dbg` (debug log), `Hook` (an empty or board-specific hook), `Task` (the cooperative event scheduler and its handlers, not RTOS tasks), `Exc` (exception bodies), `Util` (RAM-only or data helpers with no subsystem: compare, copy, clear), `Hw` (a peripheral not yet identified, renamed once it is).
- **E11.** A handler keeps the number ApplyItEc gave it: `Isr_Irq<NNN>_<Purpose>`, `Isr_Lvl<N>_<Purpose>`. Never drop or change the number.
  Why: the number is how a handler is checked against the dispatcher table.
  The body a stub calls is `IntcIrqNNN_<Effect>` (`IntcIrq058_MaskAck`), keeping the number. The IRQ list in it83xx-irqs.tsv carries a `status` like the register map: `firmware` entries come from the IT8227E firmware (`it8227e-irq-overrides.tsv`: IRQ 160 is SMBus channel E, IRQ 25 serves PM1 and PM2 together), `unverified` ones are IT8320 names nobody has checked — an Isr_Irq plate says which. On IT8227E IRQ 27 (PMC2_IN) is an empty stub. `ghidra_ec_reapply` brings an older module's register labels and ISR plates up to the current maps and lists in `kept` what a review changed. E8a applies to IRQs the same way it does to registers.
- **E12.** Names the image itself holds come first: debug strings, command tables with text.

**Rule 2: structures.** Pin descriptor tables, command tables and the EC RAM layout are structures. Prove every stride and field from the code that walks them. A layout goes into the shared Nds32 archive by proposal once a second EC build confirms it (S14).

**Rule 7: the description.** It keeps the eight fixed sections of `ghidra-uefi` reference/description.md and is written for a bench technician.

**Rule 8: records.** The six records — irq_map, host_commands, ec_ram, smbus_peers, gpio, eflash_area — are tables written with `ghidra_set_record`, never `###` subsections of the description; `Interactions` describes them in prose only (what talks to what, and what the tables leave out). Read a record's columns with `ghidra_records {record}`. Every row carries confidence: `established` when the code shows it, `inference` otherwise, with a note saying what it rests on. Code columns take an address inside a function, data columns an address in memory; computed columns (ec_ram.address, smbus_peers.address_8bit) are never written. Refs name rows by key; a ref to a row not yet written is a warning. Fill a record as you go with `upsert`; rows without a status leave it partial. Close each as `complete` (plus a note for what the rows leave out) or `none` with the reason. The review is not complete while a record is neither.
1. irq_map: IRQ → handler (and body) → source → enabled → task slot → what it does.
2. host_commands: port pair, mode, command byte (and sub-command) → handler → effect, data in and out, events raised, EC RAM rows touched.
3. ec_ram: offset → width → name → writer → meaning → values → code that reads or writes it.
4. smbus_peers: channel and 7-bit address (`mailbox` or `runtime` with a note when there is none fixed) → device → PEC → commands.
5. gpio: the pin by port and bit as its registers address it (`GPD3` = GPDRD bit 3), never read as a BGA ball; a keyboard-scan pin used as GPIO by its scan name (`KSO7`, `KSI0`). The package pin and the board's net are not columns: they belong to the board, not the firmware; give them in the row's note, from the schematic and boardview, said as the board's.
6. eflash_area: every address past the extent that the code reads, writes or erases → writers, readers → format → host commands that reach it → meaning, only from the code (E2).

## 5. Library functions

The Nds32 registry is separate from the x86 one. Its kinds:
- `toolchain`: libgcc/newlib from the Andes toolchain (memcpy, memset, division, shifts);
- `ite`: ITE EC SDK or kernel code that is the same across ITE builds. It depends on `toolchain`.

There is no source to cite. The evidence is a byte-identical body in another EC build, or the routine's standard semantics read from its instructions, and it goes in the plate. Code that touches this firmware's own state is the firmware's. The criteria and rules L1, L2, L4–L6 and L8 are as in `ghidra-uefi` §5.

## 6. Origin

The firmware belongs to the board's vendor (often the ODM), not to ITE, unless its code matches an `ite` entry. "ITE8380-EC-V0.00" names the chip family and SDK version, not the author. `vendor` comes from the image's own strings or a byte match (D6).

## 7. Work in a shared module

An EC image is one module of about 1000 functions. It is reviewed in batches, and batches may run at the same time under one lease.
- **E13.** A batch writes only in the functions its task lists: names, signatures, locals, comments, equates, labels. A callee outside the list is read, never written. A name it needs goes into the report as a proposal. A callee's `FUN_` left in a batch's C is not a gap of that batch; X1 counts only what the batch's own writes can remove. The rodata tables the listed code indexes belong to the batch only when the task lists them.
  Why: nothing on the server keeps two batches in one module apart. Batches run bottom-up so callees are mostly named before their callers are read.
- **E13a.** Every function body needs a `pre` comment, a 4-byte wrapper or empty hook included. The plate alone leaves the function at `partial` ("comments"). This was missed in 3 of 6 batches.
- **E14.** Types and enums (equate enums included), `ram` globals and the description are written only by the batch whose task says it owns them. Other batches propose in their report. Running `ghidra_xrefs` on every RAM byte a batch touches costs more than it gives. A batch names a RAM global only when its task names that address as owned; otherwise it proposes. EC Manager applies the proposals at the checkpoint. A constant that the C prints as a nearby label (`SmbChanPinsInAltFunc` in place of 15000) is a pointer-typed parameter of the callee. Report it; the callee's batch types the parameter.
- **E15.** A batch never calls `ghidra_publish`, `ghidra_done`, `ghidra_forget` or `ghidra_function_locals_reset`. The coordinator takes the lease, publishes at checkpoints and closes the module.
  Why: a publish takes in the other batch's half-done work, and `done` ends the lease for everyone.
