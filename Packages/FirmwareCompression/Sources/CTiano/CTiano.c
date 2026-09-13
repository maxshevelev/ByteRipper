#include <stdlib.h>

#include "Tiano/EfiTianoDecompress.h"
#include "include/CTiano.h"

int ctiano_info(const uint8_t *source, uint32_t sourceLength,
                uint32_t *destinationLength, uint32_t *scratchLength) {
    return EfiTianoGetInfo(source, sourceLength, destinationLength, scratchLength) == EFI_SUCCESS
        ? 0 : 1;
}

int ctiano_decode(const uint8_t *source, uint32_t sourceLength,
                  uint8_t *destination, uint32_t destinationLength, int tiano) {
    UINT32 declared = 0;
    UINT32 scratchLength = 0;
    if (EfiTianoGetInfo(source, sourceLength, &declared, &scratchLength) != EFI_SUCCESS
        || declared != destinationLength) {
        return 1;
    }
    // Never a zero-sized allocation: the decoder writes its state into the
    // scratch space whatever the output size is.
    VOID *scratch = malloc(scratchLength > 0 ? scratchLength : 1);
    if (scratch == NULL) {
        return 1;
    }
    EFI_STATUS status = tiano
        ? TianoDecompress(source, sourceLength, destination, destinationLength,
                          scratch, scratchLength)
        : EfiDecompress(source, sourceLength, destination, destinationLength,
                        scratch, scratchLength);
    free(scratch);
    return status == EFI_SUCCESS ? 0 : 1;
}
