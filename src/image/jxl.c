/* See jxl.h. */
#include <stdlib.h>
#include <string.h>

#include "jxl/decode.h"
#include "jxl.h"
#include "wuffs.h"

/* Before libjxl 0.9 the color queries took a pixel format they ignored
 * (Debian 12 has 0.7, for -fsys=libjxl). */
#if JPEGXL_NUMERIC_VERSION < JPEGXL_COMPUTE_NUMERIC_VERSION(0, 9, 0)
#define DEC(d) (d), NULL
#else
#define DEC(d) (d)
#endif

struct siv_jxl {
    JxlDecoder *dec;
    JxlPixelFormat format;
    uint32_t width, height;
    uint32_t tps_num, tps_den;
    uint8_t *icc;
    int done;
    int animated;
    /* The file, for counting frames. */
    const uint8_t *data;
    size_t len;
};

void siv_jxl_close(siv_jxl *s) {
    if (!s) return;
    if (s->dec) JxlDecoderDestroy(s->dec);
    free(s->icc);
    free(s);
}

int siv_jxl_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_jxl **out, uint32_t *width,
                 uint32_t *height, int *depth16, int *linear, const uint8_t **icc, size_t *icc_len,
                 uint16_t *primaries, uint16_t *transfer, uint32_t *loops) {
    *out = NULL;
    *icc = NULL;
    *icc_len = 0;
    *linear = 0;
    siv_jxl *s = calloc(1, sizeof(*s));
    if (!s) return SIV_WUFFS_NO_MEMORY;
    s->dec = JxlDecoderCreate(NULL);
    int result = SIV_WUFFS_INVALID;
    if (!s->dec) {
        result = SIV_WUFFS_NO_MEMORY;
        goto fail;
    }
    if (JxlDecoderSubscribeEvents(s->dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS)
        goto fail;
    if (JxlDecoderSetInput(s->dec, data, len) != JXL_DEC_SUCCESS) goto fail;
    JxlDecoderCloseInput(s->dec);
    JxlBasicInfo info;
    int have_info = 0;
    for (;;) {
        JxlDecoderStatus st = JxlDecoderProcessInput(s->dec);
        if (st == JXL_DEC_BASIC_INFO) {
            if (JxlDecoderGetBasicInfo(s->dec, &info) != JXL_DEC_SUCCESS) goto fail;
            if (info.xsize == 0 || info.ysize == 0) goto fail;
            if ((uint64_t)info.xsize * info.ysize > max_pixels) {
                result = SIV_WUFFS_TOO_LARGE;
                goto fail;
            }
            have_info = 1;
        } else if (st == JXL_DEC_COLOR_ENCODING) {
            if (!have_info) goto fail;
            break;
        } else {
            goto fail;
        }
    }
    int deep = info.bits_per_sample > 8;
    if (!info.uses_original_profile) {
        /* XYB: libjxl renders straight to linear sRGB. */
        JxlColorEncoding lin;
        memset(&lin, 0, sizeof(lin));
        lin.color_space = JXL_COLOR_SPACE_RGB;
        lin.white_point = JXL_WHITE_POINT_D65;
        lin.primaries = JXL_PRIMARIES_SRGB;
        lin.transfer_function = JXL_TRANSFER_FUNCTION_LINEAR;
        lin.rendering_intent = JXL_RENDERING_INTENT_PERCEPTUAL;
        if (JxlDecoderSetPreferredColorProfile(s->dec, &lin) != JXL_DEC_SUCCESS) goto fail;
        *linear = 1;
        deep = 1;
    } else {
        JxlColorEncoding enc;
        if (JxlDecoderGetColorAsEncodedProfile(DEC(s->dec), JXL_COLOR_PROFILE_TARGET_DATA, &enc) == JXL_DEC_SUCCESS &&
            enc.color_space == JXL_COLOR_SPACE_RGB && enc.white_point == JXL_WHITE_POINT_D65 &&
            enc.primaries != JXL_PRIMARIES_CUSTOM && enc.transfer_function != JXL_TRANSFER_FUNCTION_GAMMA) {
            /* H.273 numbers, but for P3, which is Display P3 here. */
            *primaries = enc.primaries == JXL_PRIMARIES_P3 ? 12 : (uint16_t)enc.primaries;
            *transfer = (uint16_t)enc.transfer_function;
        } else {
            size_t n = 0;
            if (JxlDecoderGetICCProfileSize(DEC(s->dec), JXL_COLOR_PROFILE_TARGET_DATA, &n) == JXL_DEC_SUCCESS && n > 0 &&
                n <= (4u << 20)) {
                s->icc = malloc(n);
                if (!s->icc) {
                    result = SIV_WUFFS_NO_MEMORY;
                    goto fail;
                }
                if (JxlDecoderGetColorAsICCProfile(DEC(s->dec), JXL_COLOR_PROFILE_TARGET_DATA, s->icc, n) != JXL_DEC_SUCCESS)
                    goto fail;
                *icc = s->icc;
                *icc_len = n;
            }
            *primaries = 1;
            *transfer = 13;
        }
    }
    s->format.num_channels = 4;
    s->format.data_type = deep ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8;
    s->format.endianness = JXL_NATIVE_ENDIAN;
    s->format.align = 0;
    s->width = info.xsize;
    s->height = info.ysize;
    s->tps_num = info.have_animation ? info.animation.tps_numerator : 0;
    s->tps_den = info.have_animation ? info.animation.tps_denominator : 0;
    s->animated = info.have_animation;
    s->data = data;
    s->len = len;
    *width = info.xsize;
    *height = info.ysize;
    *depth16 = deep;
    *loops = info.have_animation ? info.animation.num_loops : 0;
    *out = s;
    return SIV_WUFFS_OK;
fail:
    siv_jxl_close(s);
    *icc = NULL;
    *icc_len = 0;
    return result;
}

int siv_jxl_next(siv_jxl *s, uint8_t *rgba, uint32_t *delay_ms) {
    if (s->done) return SIV_WUFFS_END;
    size_t size = (size_t)s->width * s->height * (s->format.data_type == JXL_TYPE_UINT16 ? 8 : 4);
    *delay_ms = 0;
    int have_frame = 0;
    for (;;) {
        JxlDecoderStatus st = JxlDecoderProcessInput(s->dec);
        switch (st) {
        case JXL_DEC_FRAME: {
            JxlFrameHeader fh;
            if (JxlDecoderGetFrameHeader(s->dec, &fh) != JXL_DEC_SUCCESS) return SIV_WUFFS_INVALID;
            if (s->tps_num) {
                uint64_t ms = (uint64_t)fh.duration * 1000u * s->tps_den / s->tps_num;
                *delay_ms = ms > 0xffffffffu ? 0xffffffffu : (uint32_t)ms;
            }
            have_frame = 1;
            break;
        }
        case JXL_DEC_NEED_IMAGE_OUT_BUFFER: {
            size_t need = 0;
            if (JxlDecoderImageOutBufferSize(s->dec, &s->format, &need) != JXL_DEC_SUCCESS || need != size)
                return SIV_WUFFS_INVALID;
            if (JxlDecoderSetImageOutBuffer(s->dec, &s->format, rgba, size) != JXL_DEC_SUCCESS) return SIV_WUFFS_INVALID;
            break;
        }
        case JXL_DEC_FULL_IMAGE:
            if (!have_frame) return SIV_WUFFS_INVALID;
            return SIV_WUFFS_OK;
        case JXL_DEC_SUCCESS:
            s->done = 1;
            return SIV_WUFFS_END;
        default:
            return SIV_WUFFS_INVALID;
        }
    }
}

uint32_t siv_jxl_frames(const siv_jxl *s) {
    if (!s->animated) return 1;
    /* A second decoder asked only for frame headers, which skips the
     * frames' pixel data. */
    JxlDecoder *d = JxlDecoderCreate(NULL);
    if (!d) return 0;
    uint32_t n = 0;
    if (JxlDecoderSubscribeEvents(d, JXL_DEC_FRAME) == JXL_DEC_SUCCESS &&
        JxlDecoderSetInput(d, s->data, s->len) == JXL_DEC_SUCCESS) {
        JxlDecoderCloseInput(d);
        while (n < UINT32_MAX && JxlDecoderProcessInput(d) == JXL_DEC_FRAME) n++;
    }
    JxlDecoderDestroy(d);
    return n;
}
