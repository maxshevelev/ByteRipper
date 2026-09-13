#ifndef CLZMA_ENCODER_H
#define CLZMA_ENCODER_H

// The LZMA SDK's encoder, writing the layout EDK2 writes — five property bytes,
// the uncompressed size as eight little-endian bytes, the stream with no end
// mark. Called through `FirmwareCompression`, which checks what it wrote.

#include <stddef.h>
#include <stdint.h>

// Encodes `sourceLength` bytes into `destination`, which holds
// `*destinationLength` bytes; on return `*destinationLength` is what was
// written, header included. Returns the SDK's result code, 0 on success.
int clzma_encode(const uint8_t *source, size_t sourceLength,
                 uint8_t *destination, size_t *destinationLength,
                 uint32_t dictionarySize);

#endif
