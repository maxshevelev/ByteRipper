# The x86 language patch and the decompiler patch

Two patches, applied together by `Scripts/make-patched-ghidra.sh` to a copy of
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
