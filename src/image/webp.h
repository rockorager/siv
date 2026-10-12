/* siv's interface to libwebp for src/image (D19): still and animated WebP,
 * frame by frame as full straight-alpha RGBA8 canvases. */
#ifndef SIV_IMAGE_WEBP_H
#define SIV_IMAGE_WEBP_H

#include <stddef.h>
#include <stdint.h>

typedef struct siv_webp siv_webp;

/* Results are those of wuffs.h: SIV_WUFFS_OK, END, and the errors. On
 * success the ICC profile, if any, is in *icc until siv_webp_close. */
int siv_webp_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_webp **out,
                  uint32_t *width, uint32_t *height, const uint8_t **icc, size_t *icc_len, uint32_t *loops);
int siv_webp_next(siv_webp *s, uint8_t *rgba, uint32_t *delay_ms);
void siv_webp_close(siv_webp *s);

#endif
