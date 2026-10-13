/* See avif.h. */
#include <stdlib.h>

#include "avif/avif.h"
#include "avif.h"
#include "wuffs.h"

struct siv_avif {
    avifDecoder *dec;
    uint32_t width, height;
    int depth16;
};

void siv_avif_close(siv_avif *s) {
    if (!s) return;
    if (s->dec) avifDecoderDestroy(s->dec);
    free(s);
}

int siv_avif_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_avif **out, uint32_t *width,
                  uint32_t *height, int *depth16, const uint8_t **icc, size_t *icc_len, uint16_t *primaries,
                  uint16_t *transfer, uint32_t *loops) {
    *out = NULL;
    *icc = NULL;
    *icc_len = 0;
    siv_avif *s = calloc(1, sizeof(*s));
    if (!s) return SIV_WUFFS_NO_MEMORY;
    s->dec = avifDecoderCreate();
    if (!s->dec) {
        free(s);
        return SIV_WUFFS_NO_MEMORY;
    }
    /* The caller decodes on a worker of its own. */
    s->dec->maxThreads = 1;
    s->dec->imageSizeLimit = max_pixels > AVIF_DEFAULT_IMAGE_SIZE_LIMIT ? AVIF_DEFAULT_IMAGE_SIZE_LIMIT : (uint32_t)max_pixels;
    s->dec->ignoreExif = AVIF_TRUE;
    s->dec->ignoreXMP = AVIF_TRUE;
    int result = SIV_WUFFS_INVALID;
    if (avifDecoderSetIOMemory(s->dec, data, len) != AVIF_RESULT_OK) goto fail;
    avifResult r = avifDecoderParse(s->dec);
    if (r != AVIF_RESULT_OK) {
        if (r == AVIF_RESULT_NOT_IMPLEMENTED || r == AVIF_RESULT_NO_CODEC_AVAILABLE) result = SIV_WUFFS_UNSUPPORTED;
        goto fail;
    }
    const avifImage *img = s->dec->image;
    if (img->width == 0 || img->height == 0) goto fail;
    if ((uint64_t)img->width * img->height > max_pixels) {
        result = SIV_WUFFS_TOO_LARGE;
        goto fail;
    }
    s->width = img->width;
    s->height = img->height;
    s->depth16 = img->depth > 8;
    *width = img->width;
    *height = img->height;
    *depth16 = s->depth16;
    if (img->icc.size) {
        *icc = img->icc.data;
        *icc_len = img->icc.size;
    }
    *primaries = (uint16_t)img->colorPrimaries;
    *transfer = (uint16_t)img->transferCharacteristics;
#if AVIF_VERSION_MAJOR >= 1
    /* -1 is infinite; a still image plays once. */
    int reps = s->dec->repetitionCount;
    *loops = reps < 0 ? 0 : (uint32_t)reps + 1;
#else
    /* Before libavif 1.0 (-fsys on Debian 12) there is no count. */
    *loops = 0;
#endif
    *out = s;
    return SIV_WUFFS_OK;
fail:
    siv_avif_close(s);
    return result;
}

int siv_avif_next(siv_avif *s, uint8_t *rgba, uint32_t *delay_ms) {
    avifResult r = avifDecoderNextImage(s->dec);
    if (r == AVIF_RESULT_NO_IMAGES_REMAINING) return SIV_WUFFS_END;
    if (r != AVIF_RESULT_OK) return s->dec->imageIndex > 0 ? SIV_WUFFS_END : SIV_WUFFS_INVALID;
    const avifImage *img = s->dec->image;
    if (img->width != s->width || img->height != s->height) return SIV_WUFFS_INVALID;
    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, img);
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.depth = s->depth16 ? 16 : 8;
    rgb.pixels = rgba;
    rgb.rowBytes = s->width * (s->depth16 ? 8 : 4);
    if (avifImageYUVToRGB(img, &rgb) != AVIF_RESULT_OK) return SIV_WUFFS_INVALID;
    double ms = s->dec->imageTiming.duration * 1000.0;
    *delay_ms = ms > 0 && ms < 4e9 ? (uint32_t)(ms + 0.5) : 0;
    return SIV_WUFFS_OK;
}

uint32_t siv_avif_frames(const siv_avif *s) {
    return s->dec->imageCount < 0 ? 0 : (uint32_t)s->dec->imageCount;
}
