# Ghidra: the review tools and headless runs

Two ways to get at a module:

- **a review** — the `ghidra_` tools, served by `byteripper-server` at `/mcp`
  and relayed by ByteRipper's own MCP server: a kept project per module, held
  open by an owner (`owner/Owner.java`), every change published into the CAS;
  good for following a call graph, renaming and typing, and reading the
  decompiler as you go;
- **headless** — `analyzeHeadless` plus the shipped `ExportModule.java`, which
  writes one JSON file; good for a batch answer or a diff.

Both use the same loader and the same analysis, so a function's address and
decompiled body are the same in either.

A Ghidra window with an MCP extension of its own (GhydraMCP and the like) is
not a way in: what it changes stays in that window's program, never reaches the
CAS, and its project lock keeps the owner off the project.

## The review tools, by task

| task | tool |
|---|---|
| the modules with a project | `ghidra_modules` |
| open one, by node, image or SHA-256 | `ghidra_open` |
| all functions | `ghidra_functions` |
| C, parameters, locals and their storage | `ghidra_function` |
| instructions around an address | `ghidra_disassembly` |
| who refers to an address | `ghidra_xrefs` |
| data, strings | `ghidra_data`, `ghidra_strings` |
| rename a function, a parameter, a local | `ghidra_rename`, `ghidra_rename_variable` |
| signature, comment, datum | `ghidra_signature`, `ghidra_comment`, `ghidra_set_data` |
| define a type | `ghidra_type` |
| make the review visible, end it | `ghidra_publish`, `ghidra_done` |

A program's addresses are the ones the PE header declares (see
`uefi-images.md`, "Addresses"); every tool takes and gives them with the image
base applied.

## Importing

`analyzeHeadless <project-dir> <project-name> -import <file> -overwrite`

- **The loader is chosen by content.** A file starting `MZ` goes through the PE
  loader; a TE (`VZ`) is not recognized, which is why it is converted first.
- The PE loader picks the compiler spec from the header: an x86_64 UEFI image
  gets `x86:LE:64:default:windows`, whose Microsoft calling convention is what
  EFIAPI uses on x64. `-processor x86:LE:32:default` overrides it if a module
  needs the plain convention.
- **A rebuilt PE needs all sixteen data directories.** The loader reads entry
  14 (COM descriptor) even when `NumberOfRvaAndSizes` is 2. A short table leaves
  that entry pointing into the section table; a large value there aborts the
  import with `Invalid index: <value>`. `te_to_pe.py` therefore writes the full
  table, with only base-reloc and debug filled.
- Warnings about `Unusual file alignment: 0x20`, `Non-standard optional header
  size` and a skipped data directory are normal for UEFI images and do not
  affect the analysis.
- The image is mapped at `ImageBase`. A compressed module with base 0 maps at
  0; `te_to_pe.py --image-base 0x10000000` gives it a stand-in base if that is
  easier to read.

## Headless recipe

```bash
G=~/Projects/ghidra/ghidra_12.1.2_PUBLIC
$G/support/analyzeHeadless /tmp/proj uefi \
    -import module.pe -overwrite \
    -scriptPath Skills/ghidra-uefi/scripts \
    -postScript ExportModule.java /tmp/module.json

# later, without re-analysis
$G/support/analyzeHeadless /tmp/proj uefi \
    -process module.pe -noanalysis \
    -scriptPath Skills/ghidra-uefi/scripts \
    -postScript ExportModule.java /tmp/module.again.json
```

`ghidra_import.py` wraps the first form (and converts a TE first). Its JSON:

```json
{
  "program": "module.pe", "language": "x86:LE:64:default",
  "image_base": "0xFFA8510C", "sha256": "…",
  "blocks": [{"name": ".text", "start": "…", "end": "…", "executable": true}],
  "function_count": 15,
  "functions": [{
    "name": "FUN_ffa853ac", "entry": "0xFFA853AC", "size": 64,
    "external": false, "thunk": false,
    "signature": "void FUN_ffa853ac(void)",
    "callers": [], "callees": ["0xFFA853BC"],
    "c": "void FUN_ffa853ac(void) { … }"
  }]
}
```

`--no-decompile` omits `c` and is much faster on a large module.

## Reading a UEFI module in Ghidra

1. **Start at the entry point** (`AddressOfEntryPoint`); it is the driver's
   `_ModuleEntryPoint`. Its first call usually reaches the module's
   `Initialize…`/`DriverEntry`.
2. **DXE drivers** register protocols through
   `gBS->InstallProtocolInterface` / `InstallMultipleProtocolInterfaces`. The
   GUID is a pointer to 16 bytes in `.data`; Ghidra shows the data, not a
   protocol name. Rename the function once its protocol is known from the
   module's strings or its file GUID.
3. **PEIMs** call `PeiServices` through a pointer table; the entry signature is
   `EFI_STATUS (EFIAPI *)(EFI_PEI_FILE_HANDLE, EFI_PEI_SERVICES **)`.
   `FUN_…` taking two arguments where the second is dereferenced several times
   is usually that table.
4. **Strings** in `.data` (or `.rodata`) name the hardware: PCI vendor/device
   IDs, HII package names, `Setup` variable names. `ghidra_strings` is
   often faster than reading the decompiler.
5. **The decompiler assumes C.** UEFI uses the Microsoft ABI on x64 and cdecl
   on x86; Ghidra's PE-derived compiler spec usually gets this right. Where a
   function's parameters look swapped, check whether it is EFIAPI (MS x64) or a
   callback with a different convention.
6. **Everything is `FUN_…` until named.** Keep the names from the module's own
   debug strings where they exist; they are the best ground truth.

## A long-lived owner (`owner/Owner.java`)

What phase 0 of `Design/GHIDRA_SHARED_PLAN.md` found, for anyone writing Java
that keeps Ghidra open:

- **A script under `analyzeHeadless` cannot be a server.** It runs inside the
  launcher's transaction and cannot save (`ReadOnlyException`).
- **Run your own `main` on a plain classpath**: every `Ghidra/**/lib/*.jar`
  of the install, compiled against with `javac` and passed to `java -cp`, and
  `Application.initializeApplication(new GhidraApplicationLayout(), new
  HeadlessGhidraApplicationConfiguration())`. Through `ghidra.Ghidra` and its
  `GhidraClassLoader` a class on `-cp` is loaded by the system class loader and
  cannot see Ghidra.
- **Never `GhidraProject.openProgram` for a program you edit.** It keeps a
  standing transaction; one failed change aborts it, and the next save rolls
  back every change since the last one. Open with
  `DomainFile.getDomainObject(consumer, true, false, monitor)` and wrap each
  change in a transaction of its own.
- **A GhidraScript can run in-process** without the script manager: construct
  it, `setScriptArgs`, and `execute(new GhidraState(null, project, program,
  null, null, null), new ScriptControls(out, err, monitor))`. The owner runs
  `ExportCode` that way.
- **Analysis inside your own process** needs the script manager initialised
  (a Windows analyzer looks scripts up); keep analysis in `analyzeHeadless`.
- **`analyzeChanges(currentProgram)` at the end of a pass** that changes
  signatures settles the analysis it schedules. Without it, an export in the
  same run reads the program before stack frames and parameter ids are
  updated, and a kept project — saved after them — exports differently.
- **Ghidra's call graph is a set.** `getCalledFunctions` and
  `getCallingFunctions` iterate in no fixed order; sort them before writing, or
  the same program exports different bytes.
- **`CParserUtils.parseSignature` and a name already in the program.**
  `VOID *Name(…)` with `Name` already a symbol came back as a function named
  `*Name` returning `void` — and Ghidra accepts `*Name` as a symbol. The owner
  parses under a name nothing has and sets the real one after
  `ApplyFunctionSignatureCmd`, which renames only a function Ghidra named.
- **EDK2's `VOID`, `CONST`, `IN`, `OUT`, `OPTIONAL`, `EFIAPI` are macros**, not
  types; no archive has them. Expand them before handing EDK2-spelled C to
  Ghidra's parser.
- **A type the program does not hold yet** is not found by `DataTypeParser`
  even when the EDK2 archive has it; resolve it from the archive first.
- **An anonymous `typedef enum { … } NAME;` is named by where it starts.**
  Two such enums, each first in its own `CParser.parse`, become one type of
  the program: adding `EFI_DEBUG_LEVEL` replaced the values of
  `EFI_STATUS_VALUE`, and `0x80000003` decompiled as
  `DEBUG_ERROR|DEBUG_WARN|DEBUG_INIT`. The owner writes the tag `_NAME` into
  every anonymous struct, union and enum before parsing.
- **A decompiler temporary's `unique:` storage is not stable** between two
  decompilations until it is named (then it is `HASH:…`): name a local from
  the listing you just read.
- **The project lock is exclusive and survives nothing.** A second process
  gets `LockException` while the first runs; after `kill -9` the stale lock
  does not stop the next open, and only what was saved is there.

## Pitfalls

- **A converted TE keeps its RVAs.** The section data is at the offsets the TE
  table gives; the conversion restores the header size, not the section
  layout. Do not "fix" a section pointer because the headers grew — the delta
  is applied to every pointer by `te_to_pe.py`.
- **A module inside a compressed section has no file address.** Extract it with
  `--part body`; `uefi_node_data` reads the decompressed buffer. Do not try to
  find the same bytes in the file — they are not there.
- **Image base 0 is not an error.** It means the module is relocated at load
  time; the analysis is still correct relative to the image.
- **Large modules produce large JSON.** 100 KiB of x86 can be tens of MB of
  decompiled C. Filter with `jq` (`.functions[] | select(.size > 200)`) or run
  with `--no-decompile` and read only the functions that matter with
  `ghidra_function`.
- **Ghidra 12.1.2 has no TE loader.** Newer versions may add one; until then
  the conversion is part of the path, not a workaround for one version.
