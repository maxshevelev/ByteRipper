#ifndef CLZMA_H
#define CLZMA_H

// The whole of what the LZMA SDK is asked for, as plain C types, so the SDK's
// own headers — their macros, their `Byte` and `SizeT` — stay out of Swift.

#include <stddef.h>
#include <stdint.h>

// The SDK's result codes that a decode can return.
enum {
    CLZMA_OK = 0,
    CLZMA_ERROR_DATA = 1,
    CLZMA_ERROR_MEM = 2,
    CLZMA_ERROR_UNSUPPORTED = 4,
    CLZMA_ERROR_INPUT_EOF = 6
};

// Decodes an LZMA stream in the SDK's "alone" layout: five property bytes, an
// eight-byte uncompressed size the caller has already read and checked, then
// the stream. `source` points at the properties. At most `destinationLength`
// bytes are written; `written` says how many were, and `status` is the SDK's
// `ELzmaStatus`.
int clzma_decode(const uint8_t *source, size_t sourceLength,
                 uint8_t *destination, size_t destinationLength,
                 size_t *written, int *status);

// Runs the x86 branch converter over `data` in place, starting at address 0:
// backwards when `encoding` is 0, which is what undoes the filter after a
// decode, forwards otherwise.
void clzma_x86_convert(uint8_t *data, size_t length, int encoding);

#endif
