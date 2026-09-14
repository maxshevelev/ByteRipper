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

// The SDK's progress interface with the caller's function behind it. The
// interface is the first member, so the pointer the SDK hands back is this.
typedef struct {
    ICompressProgress interface;
    void *context;
    clzma_progress progress;
} progress_adapter;

static SRes adapter_progress(ICompressProgressPtr pointer, UInt64 inSize, UInt64 outSize) {
    const progress_adapter *adapter = (const progress_adapter *)pointer;
    (void)outSize;
    if (inSize != (UInt64)(Int64)-1) {
        adapter->progress(adapter->context, inSize);
    }
    return SZ_OK;
}

int clzma_encode(const uint8_t *source, size_t sourceLength,
                 uint8_t *destination, size_t *destinationLength,
                 uint32_t dictionarySize, int maximum,
                 void *context, clzma_progress progress) {
    progress_adapter adapter = { { adapter_progress }, context, progress };
    const size_t header = LZMA_PROPS_SIZE + 8;
    if (*destinationLength < header) {
        return SZ_ERROR_OUTPUT_EOF;
    }

    CLzmaEncProps properties;
    LzmaEncProps_Init(&properties);
    properties.dictSize = dictionarySize;
    if (maximum) {
        // What the old UEFITool compressed sections with: the smallest stream
        // the encoder makes, for when a normal one does not fit its room.
        properties.level = 9;
        properties.fb = 273;
    } else {
        // The SDK's normal level, and its own choices for it.
        properties.level = 5;
    }

    SizeT propertiesSize = LZMA_PROPS_SIZE;
    SizeT streamLength = *destinationLength - header;
    SRes result = LzmaEncode(destination + header, &streamLength,
                             source, sourceLength,
                             &properties, destination, &propertiesSize,
                             0, progress ? &adapter.interface : NULL,
                             &encoder_allocator, &encoder_allocator);

    uint64_t size = sourceLength;
    for (size_t index = 0; index < 8; index++) {
        destination[LZMA_PROPS_SIZE + index] = (uint8_t)(size >> (8 * index));
    }
    *destinationLength = header + streamLength;
    return result;
}
