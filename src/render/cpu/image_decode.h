/* Image decoding through wuffs (D14, D19): PNG, JPEG, and GIF (first frame)
 * into 8-bit sRGB RGBA with straight alpha. Used for CBDT/sbix color glyphs;
 * the image pipeline of D19 will share it. */
#ifndef SIV_IMAGE_DECODE_H
#define SIV_IMAGE_DECODE_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t width;
    uint32_t height;
    /* width * height * 4 bytes, rows packed; free with siv_image_free. */
    uint8_t *pixels;
} siv_image;

enum {
    SIV_IMAGE_OK = 0,
    SIV_IMAGE_UNSUPPORTED = 1,
    SIV_IMAGE_INVALID = 2,
    SIV_IMAGE_TOO_LARGE = 3,
    SIV_IMAGE_NO_MEMORY = 4,
};

/* Decodes `data`. Images with more than `max_pixels` pixels fail with
 * SIV_IMAGE_TOO_LARGE before any pixel memory is allocated. */
int siv_image_decode(const uint8_t *data, size_t len, uint64_t max_pixels, siv_image *out);
void siv_image_free(siv_image *image);

#endif
