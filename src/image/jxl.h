/* siv's interface to libjxl for src/image (D19): still and animated JPEG
 * XL, frame by frame as composited straight-alpha RGBA of 8 bits per
 * channel, or 16 (native endian). XYB-encoded images come out in linear
 * light with sRGB primaries, which libjxl converts to itself. */
#ifndef SIV_IMAGE_JXL_H
#define SIV_IMAGE_JXL_H

#include <stddef.h>
#include <stdint.h>

typedef struct siv_jxl siv_jxl;

/* Results are those of wuffs.h. Color, on success: *linear set for linear
 * sRGB output; else an ICC profile (valid until siv_jxl_close), or CICP
 * primaries and transfer characteristics. */
int siv_jxl_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_jxl **out, uint32_t *width,
                 uint32_t *height, int *depth16, int *linear, const uint8_t **icc, size_t *icc_len,
                 uint16_t *primaries, uint16_t *transfer, uint32_t *loops);
int siv_jxl_next(siv_jxl *s, uint8_t *rgba, uint32_t *delay_ms);
/* The number of frames, read without decoding their pixels; 0 if it
 * cannot tell. */
uint32_t siv_jxl_frames(const siv_jxl *s);

void siv_jxl_close(siv_jxl *s);

#endif
