/* See image_decode.h. This translation unit also compiles the wuffs
 * implementation, limited to the codecs siv uses. */
#include <stdlib.h>
#include <string.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE__CORE
#define WUFFS_CONFIG__MODULE__BASE__INTERFACES
#define WUFFS_CONFIG__MODULE__BASE__MAGIC
#define WUFFS_CONFIG__MODULE__BASE__PIXCONV
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__LZW
#define WUFFS_CONFIG__MODULE__GIF
#include "wuffs-v0.4.c"

#include "image_decode.h"

static wuffs_base__image_decoder *make_decoder(const uint8_t *data, size_t len) {
    int32_t fourcc = wuffs_base__magic_number_guess_fourcc(wuffs_base__make_slice_u8((uint8_t *)data, len), true);
    switch (fourcc) {
    case WUFFS_BASE__FOURCC__PNG:
        return wuffs_png__decoder__alloc_as__wuffs_base__image_decoder();
    case WUFFS_BASE__FOURCC__JPEG:
        return wuffs_jpeg__decoder__alloc_as__wuffs_base__image_decoder();
    case WUFFS_BASE__FOURCC__GIF:
        return wuffs_gif__decoder__alloc_as__wuffs_base__image_decoder();
    default:
        return NULL;
    }
}

int siv_image_decode(const uint8_t *data, size_t len, uint64_t max_pixels, siv_image *out) {
    memset(out, 0, sizeof(*out));
    wuffs_base__image_decoder *dec = make_decoder(data, len);
    if (!dec) return SIV_IMAGE_UNSUPPORTED;

    int result = SIV_IMAGE_INVALID;
    uint8_t *pixels = NULL;
    uint8_t *workbuf = NULL;
    wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)data, len, true);
    wuffs_base__image_config ic;
    if (wuffs_base__image_decoder__decode_image_config(dec, &ic, &src).repr) goto done;
    uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
    uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
    if (w == 0 || h == 0) goto done;
    if ((uint64_t)w * h > max_pixels) {
        result = SIV_IMAGE_TOO_LARGE;
        goto done;
    }
    wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
                                  WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
    size_t size = (size_t)w * h * 4;
    uint64_t work_len = wuffs_base__image_decoder__workbuf_len(dec).max_incl;
    if (work_len > SIZE_MAX) goto done;
    pixels = calloc(1, size);
    workbuf = work_len ? malloc((size_t)work_len) : NULL;
    if (!pixels || (work_len && !workbuf)) {
        result = SIV_IMAGE_NO_MEMORY;
        goto done;
    }
    wuffs_base__pixel_buffer pb;
    if (wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg, wuffs_base__make_slice_u8(pixels, size)).repr) goto done;
    if (wuffs_base__image_decoder__decode_frame(dec, &pb, &src, WUFFS_BASE__PIXEL_BLEND__SRC,
                                                wuffs_base__make_slice_u8(workbuf, (size_t)work_len), NULL).repr)
        goto done;
    out->width = w;
    out->height = h;
    out->pixels = pixels;
    pixels = NULL;
    result = SIV_IMAGE_OK;
done:
    free(pixels);
    free(workbuf);
    free(dec);
    return result;
}

void siv_image_free(siv_image *image) {
    free(image->pixels);
    image->pixels = NULL;
}
