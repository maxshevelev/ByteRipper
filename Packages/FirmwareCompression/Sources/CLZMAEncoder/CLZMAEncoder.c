#include "SDK/Precomp.h"

#include <stdlib.h>

#include "SDK/LzmaEnc.h"
#include "include/CLZMAEncoder.h"

static void *encoder_alloc(ISzAllocPtr allocator, size_t size) {
    (void)allocator;
    return malloc(size);
}

static void encoder_free(ISzAllocPtr allocator, void *address) {
    (void)allocator;
    free(address);
}

static const ISzAlloc encoder_allocator = { encoder_alloc, encoder_free };

int clzma_encode(const uint8_t *source, size_t sourceLength,
                 uint8_t *destination, size_t *destinationLength,
                 uint32_t dictionarySize) {
    const size_t header = LZMA_PROPS_SIZE + 8;
    if (*destinationLength < header) {
        return SZ_ERROR_OUTPUT_EOF;
    }

    CLzmaEncProps properties;
    LzmaEncProps_Init(&properties);
    properties.dictSize = dictionarySize;
    // What the old UEFITool compressed sections with: a stream put back into a
    // volume has to fit the room the old one left, so the smallest it can be.
    properties.level = 9;
    properties.fb = 273;

    SizeT propertiesSize = LZMA_PROPS_SIZE;
    SizeT streamLength = *destinationLength - header;
    SRes result = LzmaEncode(destination + header, &streamLength,
                             source, sourceLength,
                             &properties, destination, &propertiesSize,
                             0, NULL, &encoder_allocator, &encoder_allocator);

    uint64_t size = sourceLength;
    for (size_t index = 0; index < 8; index++) {
        destination[LZMA_PROPS_SIZE + index] = (uint8_t)(size >> (8 * index));
    }
    *destinationLength = header + streamLength;
    return result;
}
