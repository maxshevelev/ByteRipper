# The language patches and the decompiler patch

Four patches, applied together by `Scripts/make-patched-ghidra.sh` to a copy of
a stock install. The stock install is not touched.

`descriptor-tables-1.patch` changes Ghidra 12.2's
`Ghidra/Processors/x86/data/languages/ia.sinc`. `Scripts/make-patched-ghidra.sh`
applies it to a copy of a stock install and compiles `x86.sla` and
`x86-64.sla` there. The stock install is not touched.

## What it corrects

The stock model of `SIDT` and `SGDT` is one store of the operand's size:
`m32 = InterruptDescriptorTableRegister();`. The instruction writes more: a
2-byte limit, then the base (4 bytes in 32-bit code, 8 in 64-bit). The upper
half of the base is never written in the model, so the decompiler either prints
the base in pieces or loses it. `LIDT` and `LGDT` hand over the first 4 bytes
in the same way.

| instruction | stock | patched |
|---|---|---|
| `SIDT`, `SGDT` | one store of 2, 4 or 8 bytes | limit stored at +0, base at +2, by `…TableLimit()` and `…TableBase()` |
| `LIDT`, `LGDT` | `…TableRegister(m32)` | `…TableRegister(limit, base)`, base 3 bytes with a 16-bit operand |

The 16-bit `SIDT` and `SGDT` store a 4-byte base. Intel's manual leaves the
fourth byte to the processor; this reads what QEMU records of real hardware. The
instruction text is what stock prints. Bytes, lengths and decoding do not change.

## What depends on it

- The language id and version stay as they are, so a project opens on either
  Ghidra without an upgrade, and takes the patched p-code at once.
- A stock Ghidra opens the same project and prints the old C. Three things tell
  them apart, because the folder's name and the owner's jar do not: the marker
  `byteripper-language-patch`, whose hashes the doctor checks; `language_patch`
  in the owner's `hello` and in the artifact; and `-lang-descriptor-tables-1` in
  the recipe id. A publish from a stock Ghidra over a patched recipe is refused.
- At a new Ghidra version the script stops, because `ia.sinc` is another file:
  read the patch against it, then make a new patch and a new id.

# The decompiler patch: 32-bit x86 stack parameters

`stack-params-1.patch` changes `ParamEntry` twice, in the decompiler's C++
(`Ghidra/Features/Decompiler/src/decompile/cpp/fspec.cc`, `fspec.hh`) and in
the Java that computes a signature's storage
(`ghidra/program/model/lang/ParamEntry.java`, from the install's
`SoftwareModeling-src.zip`). The script builds the decompiler from the
install's own sources into `Ghidra/Features/Decompiler/os/<os>/decompile` and
puts the compiled class into `SoftwareModeling.jar`.

## What it corrects

On 32-bit x86, cdecl and stdcall pass every parameter in 4-byte stack slots and
align none of them further: a `UINT64` takes the next two slots. Stock Ghidra
aligns a parameter on the stack to its data type's alignment, and the x86
compiler specs give an 8-byte integer an alignment of 8, as a structure member
needs. So a `UINT64` after an odd number of slots skips one, and it and every
later parameter are read 4 bytes too high.

FatPei shows it in `EFI_PEI_FILE_ACCESS_PPI.Open(This, FileName, Handle, Mode,
Attributes, …)`, `Mode` a `UINT64` in the fourth place: stock prints
`Open(FileAccess, FileName, &Handle, 0x2000000000, (UINT8)Volume, …)`, the
patched decompiler `Open(FileAccess, FileName, &Handle, 1, 0x20, …)`. Of the
module's 33 functions, the three that call `Open` are the only ones whose C
changes.

| place | stock | patched |
|---|---|---|
| `UINT32, UINT64, UINT32` | `Stack[0x4]`, `Stack[0xc]`, `Stack[0x14]` | `Stack[0x4]`, `Stack[0x8]`, `Stack[0x10]` |
| a call through a function pointer | the same holes | the same slots as the callee's code reads |

The correction applies to a stack entry with 4-byte slots in a language that
has an `ESP` register: 32-bit x86. 64-bit x86 has 8-byte slots and is not
changed. Whether ARM32 needs the same is not known yet, so it keeps stock
behavior. Registers are not changed.

## What depends on it

- It has a marker of its own, `byteripper-decompiler-patch`: the patch's id,
  then the hashes of the decompiler and of `SoftwareModeling.jar`, which the
  doctor checks. `decompiler_patch` in the owner's `hello` and in the artifact,
  and `-decomp-stack-params-1` in the recipe id, tell its C from stock's. A
  publish from a Ghidra without it over a recipe with it is refused.
- A project's environment does not name it: it changes the C printed, not the
  program kept, so a project made on either decompiler opens on the other.
- The owner moves a signature's own parameters into the right slots itself
  (`aligned` in the answer, storage written explicitly). With the patch the
  convention already puts them there, so a new signature keeps the convention's
  storage. Signatures set before keep the explicit storage they were given.
- At a new Ghidra version the script stops, because `fspec.cc` is another file:
  read the patch against it, then make a new patch and a new id.

# The decompiler patch: named constants

`equates-1.patch` changes one action of the decompiler,
`ActionConstantPtr` in `Ghidra/Features/Decompiler/src/decompile/cpp/coreaction.cc`.
It is built into the same `decompile` as `stack-params-1`.

## What it corrects

The decompiler turns a constant into a pointer when its value is the address
of a symbol and the constant is copied, compared, added or passed where a
pointer could go. In an image based at zero a small constant often equals an
address in the code: IhisiServicesSmm's status 0x802B is also a jump target
inside its SMI handler. Once that target had a label, some 40 handlers printed
`(UINTN)&CommandLookupDone` for the status, although each `MOV EAX,0x802b`
carried the equate `IHISI_STATUS_BUFFER_RANGE_ERROR` and no reference to the
address was left (issues 7d8fd720, 7a68b7e1). An equate does not stop the
rule: it is applied to the constant before type recovery, and the rule never
looks at it.

With the patch the rule leaves alone a constant the program names with an
equate. A constant without one is treated as before, so real pointers to
globals, and pointers in modules based at their link address, do not change.

| constant | stock | patched |
|---|---|---|
| `0x802B` with an equate, a label at 0x802B | `&CommandLookupDone` | `IHISI_STATUS_BUFFER_RANGE_ERROR` |
| `0x802B` with no equate, a label at 0x802B | `&CommandLookupDone` | `&CommandLookupDone` |

## What depends on it

- The marker `byteripper-decompiler-patch` names the decompiler patches on
  its first line, `stack-params-1+equates-1+enum-values-2`.
  `decompiler_patch` in the owner's `hello` and in the artifact carries the
  same text, and the recipe id reads
  `-decomp-stack-params-1-equates-1-enum-values-2`.
- Like `stack-params-1`, it changes the C printed, not the program kept.
- At a new Ghidra version the script stops, because `coreaction.cc` is another
  file: read the patch against it, then make a new patch and a new id.

# The decompiler patch: enum values that are no member (enum-values-2)

`enum-values-2.patch` changes `TypeEnum::getMatches` in
`Ghidra/Features/Decompiler/src/decompile/cpp/type.cc`. It is built into the
same `decompile` as `stack-params-1` and `equates-1`, for every processor.

## What it corrects

When a value is neither a member of its enum nor an OR of members, the
decompiler tries the value's bitwise complement and, if that is named, prints
`~Member`. That reads right for an enum of flags and wrong for one of codes:
an EC's 1-byte host-command enum printed the bound 0x85 as
`~EcCmd_Flags80302_7A`, since 0x7A is a member and `~0x7A` is 0x85
(issue 54161725).

It also printed a value that is an OR of members as that OR for any enum,
which reads as two codes at once: a power-state enum printed the bound 0x34 as
`(PwrState_S3ToS0|PwrState_Unused04)` (issue ed3655a2).

With the patch an enum is taken for flags only when every member is a single
bit (zero allowed). An enum of flags prints as before: a member, an OR of
members, or the complement of one. Any other enum is a list of values: a value
prints as a member only when a member equals it, and otherwise as a number, in
the type's display format.

| enum, value | stock | patched |
|---|---|---|
| command codes, 0x85 | `~EcCmd_Flags80302_7A` | `0x85` |
| single-bit flags 0x02..0x40, 0x85 | `~(F40\|F20\|F10\|F08\|F02)` | `~(F40\|F20\|F10\|F08\|F02)` |

## What depends on it

- The decompiler marker and the recipe id name it after `equates-1` (above).
- It changes the C printed, not the program kept.
- At a new Ghidra version the script stops, because `type.cc` is another
  file: read the patch against it, then make a new patch and a new id.

# The NDS32 language patch: standby

`nds32-standby-1.patch` changes one constructor of Ghidra 12.2's
`Ghidra/Processors/NDS32/data/languages/nds32.sinc`. The script compiles
`nds32le.sla` and `nds32be.sla` with it, beside the x86 ones.

## What it corrects

`STANDBY` stops the core until an interrupt or a wake-up event, then goes on
with the next instruction. Stock models it as `goto inst_start`, a branch to
itself, so the flow ends at it: the code after it is never disassembled, the
function around it ends there and decompiles as `do {} while (true)`, and a
caller can be cut after the call. In ItEcNmD562 the function at 0x20CD2 lost
its return at 0x20CE6 (issue a29c3b91).

| instruction | stock | patched |
|---|---|---|
| `standby n` | `goto inst_start` | `standby(n:1)`, falls through |

The instruction text, bytes and lengths do not change.

## What depends on it

- The marker `byteripper-language-patch` names both language patches with
  their processors on its first line,
  `x86:descriptor-tables-1+NDS32:nds32-standby-1`, and hashes the four
  compiled files. A module takes only its own processor's: `language_patch`
  in the owner's `hello` and in the artifact is `nds32-standby-1` for an EC
  module and `descriptor-tables-1` for a UEFI one, so an x86 recipe id stays
  `-lang-descriptor-tables-1` and an EC one reads `-lang-nds32-standby-1`.
  A patch written without a processor is NDS32's when named `nds32-…`, else
  x86's (`LanguagePatches`).
- The language id and version stay as they are. A project made before opens
  on the patched Ghidra and reads its standby sites as falling through at
  once, but the code stock never read past them and the bodies it cut stay
  as they were: `ghidra_ec_reapply` disassembles that code and gives the
  functions their bodies, only on a Ghidra with this patch.
- A project's environment names its processor's language patches; an
  install with a patch the project was made without opens it, one without a
  patch the project was made with does not.
- At a new Ghidra version the script stops, because `nds32.sinc` is another
  file: read the patch against it, then make a new patch and a new id.
