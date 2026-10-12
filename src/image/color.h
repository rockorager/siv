/* ICC profiles to siv's working space (D11, D19) with Little CMS: linear
 * light, sRGB primaries, D65, 16 bits per channel, straight alpha. */
#ifndef SIV_IMAGE_COLOR_H
#define SIV_IMAGE_COLOR_H

#include <stddef.h>
#include <stdint.h>

typedef struct siv_icc siv_icc;

/* A transform from an embedded RGB profile, for RGBA input of 8 or 16 bits
 * per channel (native endian). NULL if the profile is invalid, not RGB, or
 * memory ran out: the image is then treated as sRGB. */
siv_icc *siv_icc_new(const uint8_t *icc, size_t len, int bits);

/* Whether the profile is sRGB (matrix and curves within rounding), so
 * that 8-bit pixels can stay as they are. */
int siv_icc_is_srgb(const siv_icc *t);

/* Converts n pixels (fewer than 2^31) to linear 16-bit RGBA, alpha copied. */
void siv_icc_apply(const siv_icc *t, const void *src, uint16_t *dst, size_t n);

void siv_icc_free(siv_icc *t);

#endif
