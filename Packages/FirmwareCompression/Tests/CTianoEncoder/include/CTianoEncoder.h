#ifndef CTIANO_ENCODER_H
#define CTIANO_ENCODER_H

// Test support only: EDK2's Tiano / EFI 1.1 compressor. Not reentrant — it
// keeps its state in file-level statics.

#include <stdint.h>

// Compresses `sourceLength` bytes into `destination`, which holds
// `*destinationLength` bytes; on return `*destinationLength` is what was
// written, the 8-byte header included. Tiano when `tiano` is non-zero, EFI 1.1
// otherwise. 0 on success.
int ctiano_encode(const uint8_t *source, uint32_t sourceLength,
                  uint8_t *destination, uint32_t *destinationLength, int tiano);

#endif
