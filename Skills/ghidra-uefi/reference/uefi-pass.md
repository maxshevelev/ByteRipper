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
subclasses, so a composition of members would be a guess.

Revision 3 gives every Ia32 function type EFIAPI's convention, `__cdecl`. The
parser defines neither `_MSC_EXTENSIONS` nor `__GNUC__`, so `ProcessorBind.h`
leaves `EFIAPI` empty and the types came out with none, which a 32-bit
program of the windows spec reads as `__stdcall`: an indirect call through a
PEI service or a PPI member then took its arguments off the stack, and the
caller's stack locals moved by their size after every such call (issue
4a9a4484). X64 has one convention, and its types are as they were.

Revision 4 gives an enum member initialised with an earlier member's name
that member's value, as C does: the parser numbered it as the member before
it plus one, so `EfiGcdMemoryTypePersistentMemory` (an alias of
`EfiGcdMemoryTypePersistent`, 4) came out 5 and the members after it one too
high (issue 33a286ab). `BuildUefiTypes.java` reads the headers' enums again
after the parse and puts right every one with such an alias — in MdePkg,
`EFI_GCD_MEMORY_TYPE`, `EFI_USB_BUS_SPEED`, `EFI_USBFN_ENDPOINT_DIRECTION`,
`EVENT_LOG_VARIABLE_DATA`, `MEMORY_ERROR_TYPE`,
`SUPPORTED_DATA_REMOVAL_MECHANISM` and `UDF_VOLUME_DESCRIPTOR_ID`.

Revision 5 makes `BOOLEAN` a one-byte enum of `FALSE` (0) and `TRUE` (1)
and `INT8` Ghidra's `sbyte`. `ProcessorBind.h` declares them `unsigned char`
and `signed char`, and `FALSE`/`TRUE` are `#define`s the parser ties to no
type, so the decompiler printed a char type's constants as characters: `if
(Notify != '\0')`, `CoreFindProtocolEntry(Protocol,'\0')`, a mask `'\xff'`.
`UINT8` stays `unsigned char` — the type every review typed its locals with —
and is shown in hex. Made Ghidra's `byte`, it was the type of the
decompiler's own temporaries, which then merged with a review's named byte
locals and took their names. Ghidra keeps a typedef's display format only in
a program, never in an archive, so the UEFI pass sets it and the owner sets
it again at open and after each change. The C now prints `FALSE`, `TRUE` and
numbers (`0x7f`, `0x12`; small ones too: `0x3`). `CHAR8` stays `char`: it is
text. A program and the shared review types made with an earlier archive take
`BOOLEAN` and `INT8` at the owner's open, as they take revision 4's values. A
mask a `BOOLEAN` receives prints as `TRUE` (`Flags & TRUE`), and an equate on
that constant does not win over the enum: the decompiler's enum printer never
looks at equates. A review retypes such an expression.

`-r5` is `TYPES_REVISION`; it is in the recipe's `types` and, past 1, in its id
(`code-v10-types5-ghidra-…`), so a module typed by the new archive is a recipe
beside the old one. A project made with an earlier revision moves to the
current archive when the server next starts its owner. At open the owner
gives the program's function types with no convention `__cdecl` (32-bit, also
after every change; the UEFI pass does at the end) and the program's EDK2
enums the values the archive gives their members, and the archive's
`BOOLEAN` and `INT8` — not a type the review defined itself. The server gives the shared review types of the module's size
the same once each, in a version of their own.

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
   The same for SMM: `SmmLocateProtocol` and `SmmHandleProtocol` (`Mm…` too).
7. **Typed values, in rounds.** What the steps above typed is the start of
   more, repeated while a round finds something:
   - IA32 PEI: the PEI Services pointer kept below the IDT. A variable that
     holds the IDT's base — the patched language's
     `InterruptDescriptorTableBase()`, or stock Ghidra's descriptor that `SIDT`
     writes — and that the code reads 4 bytes below is `EFI_PEI_SERVICES ***`,
     called `IdtBase` when nobody named it: the call reads
     `(*(*IdtBase[-1])->LocatePpi)(IdtBase[-1], …)`.
   - An out argument of a call whose type is known: `&Smst` handed to
     `GetSmstLocation` is `EFI_SMM_SYSTEM_TABLE2 *` (a global of Ghidra's
     name becomes `gSmst`), `&Root` handed to `OpenVolume` is
     `EFI_FILE_PROTOCOL *`.
   - A variable copied from a value of an EDK2 table or interface type, and
     a function whose every return is one, returns that type.
   After each round the service calls are followed again.
8. **DEBUG names.** A function whose call passes a `%a` format and exactly one
   identifier-like string is named by it — EDK2's `__FUNCTION__`. An
   identifier two functions both pass names neither.

The typing — steps 4 to 7 — only fills what has no type: Ghidra's
`undefined`, its own `int`, `uint`, `longlong`, `code *`, `void *` and
pointers to them. An EDK2 integer (`UINTN`, `UINT32`) or any structure
someone chose stays. A variable someone named keeps its name and gets the
type. A register local the decompiler made and nobody named is left alone:
Ghidra would give the type to every later value in that register. A variable
gets a type only when every value written into it is of that type — a
register a review named for a status also holds the table pointer for a few
instructions. A `void *` a review chose stays unless exactly one call fills
it: a slot one function hands to several lookups is `void *` on purpose.

## Run again over reviewed modules

`ApplyUefi.retype` runs steps 4 to 7 on a program a review has worked on:
the owner's `/v1/uefi/retype`, and the server's `POST /ghidra/v1/retype`
(an administrator's, no agent tool), which takes each reviewed module in
turn, types it, publishes a module that changed as a revision of its own and
gives it back. Library links are left as they are.

Typing one place can make the decompiler read a function's frame anew: a
review's name moves to the next stack slot, or a type the review set gives
way to one Ghidra guessed — most often when a global function pointer the
function calls through gets its signature. So the run first notes, for each
function, the names a review gave and their types as the C prints them, and
after typing reads every function again. A function where such a name is
gone, or holds another type (other than an untyped one that became an
interface's), is put back as the review left it — its variables, its
parameters and return, then the globals it reads, then what it calls — and
the run leaves it alone; the log says `put back <function>`. The run's table — raw
`(code **)` calls before and after, the revision, and the names the C no
longer shows because two variables a review named apart now read as one —
is `GET /ghidra/v1/retype` and `retype-<date>.json` beside the projects.

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
