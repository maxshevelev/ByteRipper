# The UEFI pass

Ghidra reads a PEIM or a DXE driver as anonymous code: `FUN_0000f6e0`,
`param_2`, `(**(code **)(lVar1 + 0x58))()`. `ApplyUefi.java` runs between
Ghidra's analysis and `ExportCode.java` and gives the module back what the
specifications fix, without guessing at what they do not.

## What it needs

The server's `UEFITypes` builds, once, into
`~/Library/Application Support/ByteRipper/Ghidra`:

| File | From | What |
| --- | --- | --- |
| `edk2-stable202608/` | EDK2's tarball at the pinned tag | `MdePkg/Include`, `MdePkg.dec`, `MdeModulePkg.dec` (about 10 MB) |
| `uefi_X64-<tag>-r2.gdt`, `uefi_Ia32-<tag>-r2.gdt` | `BuildUefiTypes.java`, Ghidra's C parser over MdePkg | the PI and UEFI tables, every PPI and protocol (about 23 800 types each) |
| `guids.csv` | LongSoft's `common/guids.csv`, the catalogue the app names its tree by | vendor GUIDs EDK2 does not declare |
| `guids-….tsv` | both `.dec` files, then the catalogue | `<16 bytes as hex>\t<g…Guid name>`; EDK2's name wins |

EDK2 spells a status as a `#define`, which the parser keeps as a one-value
enum `define_<NAME>` under `/<header>/defines` and ties to no type; a value
typed `EFI_STATUS` was therefore printed as `0x80000002`. After the parse,
`BuildUefiTypes.java` makes two enums of those defines and puts them in place
of the integer typedefs, so every prototype that names them carries them:

- `EFI_STATUS` — the 41 codes `Base.h` defines as `RETURN_<NAME>` and
  `UefiBaseType.h` as `EFI_<NAME>`, as wide as the archive's `UINTN` (4 bytes
  for Ia32, 8 for X64). `RETURN_STATUS` stays an integer.
- `EFI_STATUS_CODE_TYPE` — `EFI_PROGRESS_CODE`, `EFI_ERROR_CODE`,
  `EFI_DEBUG_CODE` and the four severities, without the masks: the decompiler
  writes `0x80000002` passed to `ReportStatusCode` as
  `EFI_ERROR_MAJOR|EFI_ERROR_CODE`.

`EFI_STATUS_CODE_VALUE` stays an integer: its operation codes repeat between
subclasses, so a composition of members would be a guess. `-r2` is
`TYPES_REVISION`; it is in the recipe's `types` and, past 1, in its id
(`code-v4-types2-ghidra-…`), so a module typed by the new archive is a recipe
beside the old one. A project keeps the archive it was made with.

Each step says what it is when it starts and how long it took, with a limit —
the download and the unpacking, the archives, a Ghidra analysis — so an
unreachable GitHub ends in a sentence, not a wait.

Ghidra ships `CreateUEFIGDTArchivesScript.java` but not the archives, and that
script reads a fixed path; `BuildUefiTypes.java` is the same parse with the
paths as arguments. The tag is part of the analysis recipe (`recipe.types`),
so the same module is typed by the same headers every time.

## What it does, in order

1. **GUIDs.** Every 4-aligned 16 bytes outside the instructions that the table
   names becomes an `EFI_GUID` of that name. All zeros (EDK2's
   `gEfiPartTypeUnusedGuid`) and all ones are skipped: they are every zeroed
   global and every erased byte. A GUID handed to a service that the table does
   not know is typed and called `gUnknownGuid_<Data1>`.
2. **Calling conventions.** On IA32, every `__thiscall` Ghidra guessed becomes
   `__cdecl` (EFIAPI): firmware is C, and a `this` only adds `extraout_ECX`
   noise to every caller.
3. **The entry point.** `EFI_STATUS (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE
   *SystemTable)` for DXE, `EFI_STATUS (EFI_PEI_FILE_HANDLE FileHandle, CONST
   EFI_PEI_SERVICES **PeiServices)` for PEI. `--phase` decides; by default a
   TE or 32-bit image is PEI and a 64-bit one DXE.
4. **Parameters down the calls.** A function called with `SystemTable`,
   `PeiServices`, a service table or the image's own handle gets that
   parameter's type and name, and passes it on.
5. **Globals.** A global written from those values is `gST`, `gBS`, `gRT`,
   `gImageHandle`, `gPeiServices`, `gSmst`/`gMmst` — the EDK2 libraries'
   names. A second copy is `gST_2`.
6. **Service calls.** With the tables typed, a call names its field. Then:
   `LocateProtocol`, `HandleProtocol`, `OpenProtocol`, `LocatePpi` type and name
   their result (`gPciIo`, a local `PciIo`) as a pointer to the protocol's
   struct when MdePkg declares one; `InstallProtocolInterface`,
   `InstallMultipleProtocolInterfaces` (first pair) and `InstallPpi` name what
   they install (`mDebugMask`); `CreateEventEx` names its callback after the
   event group (`OnEventReadyToBoot`); `RegisterProtocolNotify` and `NotifyPpi`
   after what they wait for (`OnShellEnvironment2Installed`).
7. **DEBUG names.** A function whose call passes a `%a` format and exactly one
   identifier-like string is named by it — EDK2's `__FUNCTION__`. An
   identifier two functions both pass names neither.

Every name is `SourceType.ANALYSIS`; its reason is kept in the program
property `ByteRipper.nameReason`, which `ExportCode.java` writes beside the
name (`name_source`, `name_reason`, and `reason` on a symbol). A name the image
or a user gave is never replaced.

## What it found on the modules at hand

| Module | Before | After |
| --- | --- | --- |
| CpuPei (TE, IA32) | `(**(code **)(*param_2 + 0x58))(param_2, 0x80000002, 0x11004, …)` | `(*(*PeiServices)->ReportStatusCode)(PeiServices, 0x80000002, 0x11004, …)`, `&gAmiStatusCodeCpuBistDataGuid`, `EFI_STATUS_CODE_DATA local_20` |
| BdsDxe (PE32+, X64) | `DAT_00031fd0 = *(longlong *)(param_2 + 0x60)` | `gBS = SystemTable->BootServices; (*gBS->LocateProtocol)(&gEfiDevicePathUtilitiesProtocolGuid, NULL, &gDevicePathUtilities)`; 142 GUIDs, 27 globals, 8 callbacks |
| AmdPspPeiV2 (PE32, IA32) | `this`, `extraout_ECX_00…12` in every call | cdecl calls, `(*(*PeiServices)->InstallPpi)(PeiServices, &EFI_PEI_PPI_DESCRIPTOR_09a7f360)` |

Most functions still have Ghidra's `FUN_` name: a release build carries no
names, and the pass names only what the module's own data says. AMD's debug
macro is not EDK2's, so its strings name nothing.

## Not done yet

- Function ID databases for EDK2's library routines (`CopyMem`, `ZeroMem`, …).
- Protocols the module calls through: a typed `gPciIo->Pci.Read` already reads
  as such; a vendor protocol MdePkg does not declare stays a pointer.
- Locals: the pass types a local a service fills only when the decompiler
  keeps it as one variable; a stack slot reused across inlined code keeps
  Ghidra's union-like type.
