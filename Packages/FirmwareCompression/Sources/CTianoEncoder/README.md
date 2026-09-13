# Tiano / EFI 1.1 compressor

`Tiano/EfiTianoCompress.c`, `Tiano/EfiTianoCompress.h` and `basetypes.h` are
**copied unmodified** from UEFITool NE (`common/Tiano` and `common/basetypes.h`,
commit `dac91b2`), the same place as the decompressor in `Sources/CTiano`. The
compressor is EDK2's; the files are under the BSD licence stated in their
headers (Intel Corporation, Nikolaj Schlej, LongSoft).

`CTianoEncoder.c` and `include/CTianoEncoder.h` are this project's: one plain-C
function over the compressor.

The compressor keeps its state in file-level statics, so it is not reentrant;
`FirmwareCompression` holds a lock around every call. The old UEFITool also
carried a legacy variant of it and tried that first; it is not vendored here,
and the round trip every encode is checked by stands in for what that choice
guarded against.

To update: copy the same files from a newer UEFITool over these, keep them
unmodified, and change the commit above — together with the decompressor's.
