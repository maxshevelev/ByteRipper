# The x86 language patch

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
