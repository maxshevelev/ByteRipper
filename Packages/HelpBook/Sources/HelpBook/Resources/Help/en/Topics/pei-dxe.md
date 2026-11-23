# PEIMs and DXE drivers

> PEIMs, DXE drivers, the interfaces they publish and wait for, and how the dispatcher decides when a module runs.

The firmware that runs before the operating system is a chain of modules, each one a file inside a firmware volume. The first part of the chain is PEI, the second is DXE. This page explains the words the panel uses for both, and how a module comes to run.

## The phases

- SEC — Security Phase. The first instructions after reset: a temporary stack, cache-as-RAM, whatever verification the board performs, and the first firmware volume, whose PEI Core it starts.
- PEI — Pre-EFI Initialization. A small environment in which permanent memory is still being set up. Its modules are PEIMs; they publish [[term:ppi|PPIs]] for one another.
- DXE — Driver Execution Environment. The full boot environment. Its modules are DXE drivers; they publish protocols, and the boot services the operating system later uses come up here.

## The words

- PEIM — PEI Module: an [[term:ffs-file|FFS file]] of type PEIM (`0x06`), read as a [[term:peim|PEIM]].
- PPI — PEIM-to-PEIM Interface: a GUID and a table of functions, or a piece of data, that one PEIM publishes for the others.
- Protocol — the same idea in DXE: a GUID and a table of functions, published by a driver and found through the boot services.
- DEPEX — Dependency Expression: the bytecode that names the PPIs or protocols a module needs before it may run.
- TE, PE32 — the image formats a module's code is kept in. A PEIM is usually TE, a DXE driver usually PE32.

## How a module is dispatched

The PEI Core walks the files of a firmware volume in their physical order. For each PEIM it evaluates the dependency expression against the PPIs installed so far. If the expression is true, the core calls the PEIM's entry, and the PEIM may install PPIs of its own. If it is false, the core leaves the module for a later pass. When a pass runs nothing and modules remain, their dependencies cannot be met.

The DXE dispatcher does the same with protocols: it walks the DXE firmware volume, evaluates each driver's dependency expression, and calls the driver when the protocols it names exist.

An expression is postfix: `PUSH` a GUID, combine the values with `AND`, `OR` and `NOT`, finish with `END`; `TRUE` and `FALSE` are literals. A DXE expression may also begin with `BEFORE`, `AFTER` or `SOR`, which say when the driver is dispatched rather than whether.

The consequence matters: an expression names an **interface**, not a module. Any module may install a PPI or protocol, several may install the same one, and some are installed by the PEI Core itself. The image does not store "module A depends on module B".

## Where the expression is shown

Open the code of a PEIM or a DXE driver: the Interfaces tab of the [[topic:code-panel|Code panel]] shows its expression under **Dependency expression**, each GUID under the name the reviews gave it, or as the GUID where no review has named it. The image stores the sixteen bytes and nothing else.

## Finding who installs an interface

The dependency sections that name a GUID are its consumers. A module that installs the same GUID usually mentions it in its code or data. Search the image contents for the GUID's sixteen bytes — the first three fields little-endian, the last eight as stored — and the matches will include both kinds: dependency sections, and modules whose code or data holds the GUID. Decompiling a candidate tells an installer, which passes a descriptor to `InstallPpi` or installs a protocol, from a consumer, which calls `LocatePpi` or `LocateProtocol`.

The expression shows the interface a module asks for, not the module that answers. The interfaces a module installs are listed in its Code panel once its review has recorded them; for a module not yet reviewed, read its decompiled code.

## What this cannot tell you

An installer may be conditional — on the boot mode, a strap, a value from a HOB — and several modules may install the same GUID. The panel reads the image as it lies on the chip, not as the board runs: it can say what a module asks for, and which modules are candidates, but not which one answered on a particular boot.
