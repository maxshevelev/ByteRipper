#ifndef CTIANO_H
#define CTIANO_H

// The whole of what EDK2's Tiano / EFI 1.1 decompressor is asked for, as plain
// C types, so its porting header — `EFI_STATUS`, `IN`, `OUT`, `VOID` as macros
// — stays out of Swift.

#include <stdint.h>

// The sizes the header of a compressed buffer declares: what it decompresses
// to, and the scratch space the decoder needs for it. 0 on success.
int ctiano_info(const uint8_t *source, uint32_t sourceLength,
                uint32_t *destinationLength, uint32_t *scratchLength);

// Decodes `source` into `destination` (`destinationLength` bytes, from
// `ctiano_info`) as Tiano when `tiano` is non-zero, as EFI 1.1 otherwise. The
// scratch space is allocated and freed here. 0 on success.
int ctiano_decode(const uint8_t *source, uint32_t sourceLength,
                  uint8_t *destination, uint32_t destinationLength, int tiano);

#endif
