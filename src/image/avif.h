/* siv's interface to libavif and dav1d for src/image (D19): still and
 * animated AVIF, frame by frame as straight-alpha RGBA of 8 bits per
 * channel, or 16 (native endian) for higher bit depths. */
#ifndef SIV_IMAGE_AVIF_H
#define SIV_IMAGE_AVIF_H

#include <stddef.h>
#include <stdint.h>

typedef struct siv_avif siv_avif;

/* Results are those of wuffs.h. On success *depth16 says whether frames
 * are 16-bit; color is an ICC profile (valid until siv_avif_close) or,
 * without one, CICP primaries and transfer characteristics. */
int siv_avif_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_avif **out, uint32_t *width,
                  uint32_t *height, int *depth16, const uint8_t **icc, size_t *icc_len, uint16_t *primaries,
                  uint16_t *transfer, uint32_t *loops);
int siv_avif_next(siv_avif *s, uint8_t *rgba, uint32_t *delay_ms);
void siv_avif_close(siv_avif *s);

#endif
