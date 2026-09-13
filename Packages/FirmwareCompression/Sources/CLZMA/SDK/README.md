# LZMA SDK, decoder half

The files in this directory are the LZMA SDK by Igor Pavlov, version `26.01`,
**copied unmodified**. The SDK is placed in the public domain by its author
(see the header of each file, and <https://www.7-zip.org/sdk.html>).

They were taken from UEFITool NE (`common/LZMA/SDK/C`, commit `dac91b2`), which
vendors the same version and uses it for the same thing — the LZMA sections of
a UEFI image.

Only what decoding needs is here:

| File | What for |
|---|---|
| `LzmaDec.c`, `LzmaDec.h` | the LZMA decoder |
| `Bra86.c`, `Bra.h` | the x86 branch converter undone after an LZMA + x86 section |
| `7zTypes.h`, `Compiler.h`, `Precomp.h`, `CpuArch.h` | what those include |

The encoder (`LzmaEnc.c`, `LzFind.c`, `CpuArch.c` and their headers) is under
`Sources/CLZMAEncoder/SDK`, copied from the same place.

To update: copy the same files from a newer SDK over these, keep them
unmodified, and change the version above.
