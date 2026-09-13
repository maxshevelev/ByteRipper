# Tiano / EFI 1.1 decompressor

`Tiano/EfiTianoDecompress.c`, `Tiano/EfiTianoDecompress.h` and `basetypes.h` are
**copied unmodified** from UEFITool NE (`common/Tiano` and `common/basetypes.h`,
commit `dac91b2`). The decompressor is EDK2's, as adapted by LongSoft / Nikolaj
Schlej; all three files are under the BSD licence stated in their headers
(Intel Corporation, Apple Inc., Nikolaj Schlej, LongSoft).

`basetypes.h` is UEFITool's EDK2 porting header — the `UINT32`, `EFI_STATUS`,
`IN`/`OUT` the decompressor is written in — and sits where the decompressor's
`#include "../basetypes.h"` expects it.

`CTiano.c` and `include/CTiano.h` are this project's: two plain-C functions over
the decompressor, so none of the porting macros reach Swift.

The compressor (`EfiTianoCompress.c`, `.h`) is under `Tests/CTianoEncoder`,
copied from the same place, and is linked only by the package's tests. It keeps
its state in file-level statics, so it is not reentrant — which a test that
encodes one fixture at a time never notices.

To update: copy the same files from a newer UEFITool over these, keep them
unmodified, and change the commit above.
