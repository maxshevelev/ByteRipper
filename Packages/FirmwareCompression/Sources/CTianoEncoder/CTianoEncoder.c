#include "Tiano/EfiTianoCompress.h"
#include "include/CTianoEncoder.h"

int ctiano_encode(const uint8_t *source, uint32_t sourceLength,
                  uint8_t *destination, uint32_t *destinationLength, int tiano) {
    UINT32 length = *destinationLength;
    EFI_STATUS status = tiano
        ? TianoCompress(source, sourceLength, destination, &length)
        : EfiCompress(source, sourceLength, destination, &length);
    *destinationLength = length;
    return status == EFI_SUCCESS ? 0 : 1;
}
