---
name: ghidra-ec
description: Review an embedded-controller (EC) firmware image in Ghidra through ByteRipper's `ghidra_` tools — an ITE IT83xx/IT8227E image on the Andes NDS32 core, opened as a module of kind EC. Use when a person asks what an EC firmware does, which register or pin a function drives, or why a laptop's EC misbehaves. The review rules are being written.
---

# Reviewing EC firmware

The review rules for EC modules are being written in another session; this
file is a placeholder so the review kit, the agent package and the server
already carry the skill's place.

What exists now:

- `ghidra_create` / `ghidra_open` accept an ITE EC image (by document and
  node, or as `image_base64`): the module's kind is `EC`, its family
  `ite-nds32`, its language `NDS32:LE:32:default`.
- The server's EC pass (`ApplyItEc.java`) lays out the blocks (`flash`,
  `ram`, `regs`), names the vectors, the interrupt entry and dispatcher, one
  `Isr_IrqNNN` function per INTC interrupt, and labels the registers.
- The register map it labels from: `reference/it83xx-registers.tsv`, and the
  INTC interrupt numbers: `reference/it83xx-irqs.tsv` — our own tables, built
  by `scripts/build_register_map.py` from Chromium EC's
  `chip/it83xx/registers.h` (the revision is in each file's header).
