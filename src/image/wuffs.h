/* siv's interface to wuffs for src/image (D19): PNG (with APNG), JPEG,
 * and GIF, frame by frame, composited onto one canvas of straight-alpha
 * RGBA8. The decoder takes the whole file in memory. */
#ifndef SIV_IMAGE_WUFFS_H
#define SIV_IMAGE_WUFFS_H

#include <stddef.h>
#include <stdint.h>

typedef struct siv_wuffs siv_wuffs;

enum {
    SIV_WUFFS_OK = 0,
    SIV_WUFFS_END = 1,
    SIV_WUFFS_UNSUPPORTED = -1,
    SIV_WUFFS_INVALID = -2,
    SIV_WUFFS_TOO_LARGE = -3,
    SIV_WUFFS_NO_MEMORY = -4,
};

/* Reads the header. On success *out is the decoder, the canvas size is in
 * *width and *height, and an embedded ICC profile, if any, is a range of
 * data in *icc and *icc_len (null and 0 otherwise). */
int siv_wuffs_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_wuffs **out,
                   uint32_t *width, uint32_t *height, const uint8_t **icc, size_t *icc_len);

/* Decodes the next frame onto the canvas and copies the canvas to rgba
 * (width * height * 4 bytes). SIV_WUFFS_END after the last frame. */
int siv_wuffs_next(siv_wuffs *s, uint8_t *rgba, uint32_t *delay_ms);

/* 0 loops forever. */
uint32_t siv_wuffs_loops(const siv_wuffs *s);

void siv_wuffs_close(siv_wuffs *s);

#endif
