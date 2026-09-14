#ifndef CLZMA_ENCODER_H
#define CLZMA_ENCODER_H

// The LZMA SDK's encoder, writing the layout EDK2 writes — five property bytes,
// the uncompressed size as eight little-endian bytes, the stream with no end
// mark. Called through `FirmwareCompression`, which checks what it wrote.

#include <stddef.h>
#include <stdint.h>

// Called now and then with how many source bytes the encoder has taken in.
typedef void (*clzma_progress)(void *context, uint64_t processed);

// Encodes `sourceLength` bytes into `destination`, which holds
// `*destinationLength` bytes; on return `*destinationLength` is what was
// written, header included. `maximum` non-zero encodes at the SDK's maximum
// level (9, 273 fast bytes), zero at its normal level (5). `progress` may be
// NULL. Returns the SDK's result code, 0 on success.
int clzma_encode(const uint8_t *source, size_t sourceLength,
                 uint8_t *destination, size_t *destinationLength,
                 uint32_t dictionarySize, int maximum,
                 void *context, clzma_progress progress);

#endif
