#include "SDK/Precomp.h"

#include <stdlib.h>

#include "SDK/LzmaDec.h"
#include "SDK/Bra.h"
#include "include/CLZMA.h"

static void *clzma_alloc(ISzAllocPtr allocator, size_t size) {
    (void)allocator;
    return malloc(size);
}

static void clzma_free(ISzAllocPtr allocator, void *address) {
    (void)allocator;
    free(address);
}

static const ISzAlloc clzma_allocator = { clzma_alloc, clzma_free };

int clzma_decode(const uint8_t *source, size_t sourceLength,
                 uint8_t *destination, size_t destinationLength,
                 size_t *written, int *status) {
    *written = 0;
    *status = LZMA_STATUS_NOT_SPECIFIED;
    if (sourceLength < LZMA_PROPS_SIZE + 8) {
        return SZ_ERROR_INPUT_EOF;
    }

    SizeT outLength = destinationLength;
    SizeT inLength = sourceLength - (LZMA_PROPS_SIZE + 8);
    ELzmaStatus lzmaStatus = LZMA_STATUS_NOT_SPECIFIED;
    // To the end: the size is known, so the stream has no end mark to look for
    // and a decode that has filled the buffer is a decode that is finished.
    SRes result = LzmaDecode(destination, &outLength,
                             source + LZMA_PROPS_SIZE + 8, &inLength,
                             source, LZMA_PROPS_SIZE,
                             LZMA_FINISH_END, &lzmaStatus, &clzma_allocator);
    *written = outLength;
    *status = (int)lzmaStatus;
    return result;
}

void clzma_x86_convert(uint8_t *data, size_t length, int encoding) {
    UInt32 state = Z7_BRANCH_CONV_ST_X86_STATE_INIT_VAL;
    if (encoding) {
        z7_BranchConvSt_X86_Enc(data, length, 0, &state);
    } else {
        z7_BranchConvSt_X86_Dec(data, length, 0, &state);
    }
}
