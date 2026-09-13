# LZMA SDK, encoder half

The files in this directory are the LZMA SDK by Igor Pavlov, version `26.01`,
**copied unmodified**. The SDK is placed in the public domain by its author
(see the header of each file, and <https://www.7-zip.org/sdk.html>).

They were taken from UEFITool NE (`common/LZMA/SDK/C`, commit `dac91b2`), the
same place and version as the decoder in `Sources/CLZMA/SDK`.

Only what encoding needs is here:

| File | What for |
|---|---|
| `LzmaEnc.c`, `LzmaEnc.h` | the LZMA encoder |
| `LzFind.c`, `LzFind.h`, `LzHash.h` | its match finder |
| `CpuArch.c`, `CpuArch.h`, `7zTypes.h`, `Compiler.h`, `Precomp.h` | what those include |

`CLZMAEncoder.c` and `include/CLZMAEncoder.h`, one directory up, are this
project's: one plain-C function writing EDK2's layout, with the settings the
old UEFITool compressed sections with (`level` 9, `fb` 273).

To update: copy the same files from a newer SDK over these, keep them
unmodified, and change the version above — together with the decoder's.
