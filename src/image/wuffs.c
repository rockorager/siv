/* See wuffs.h. This translation unit compiles the wuffs implementation,
 * limited to the codecs siv decodes images with. */
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

#include "wuffs.h"

struct siv_wuffs {
    wuffs_base__image_decoder *dec;
    wuffs_base__io_buffer src;
    wuffs_base__pixel_buffer pb;
    uint8_t *canvas;
    /* The canvas before the current frame, for RESTORE_PREVIOUS. */
    uint8_t *saved;
    uint8_t *workbuf;
    size_t workbuf_len;
    uint32_t width, height;
    /* The previous frame's area and disposal, applied before the next. */
    wuffs_base__rect_ie_u32 prev_bounds;
    uint8_t prev_disposal;
    int frames;
    /* The ICC profile, decompressed. */
    uint8_t *icc;
    size_t icc_len;
    /* The file, for counting frames. */
    const uint8_t *data;
    size_t len;
};

/* Profiles larger than this are not worth reading. */
#define MAX_ICC (4u << 20)

/* Reads one reported metadata item (only ICC profiles are asked for) into
 * s->icc: raw bytes are a range of the in-memory source, or come out of
 * the decoder (compressed iCCP chunks, JPEG APP2 segments). */
static int read_metadata(siv_wuffs *s, const uint8_t *data, size_t len) {
    size_t cap = 0;
    uint8_t *buf = NULL;
    wuffs_base__io_buffer dst = wuffs_base__empty_io_buffer();
    int result = SIV_WUFFS_INVALID;
    uint32_t fourcc = 0;
    for (;;) {
        wuffs_base__more_information minfo = wuffs_base__empty_more_information();
        wuffs_base__status st = wuffs_base__image_decoder__tell_me_more(s->dec, &dst, &minfo, &s->src);
        if (minfo.flavor != 0) fourcc = wuffs_base__more_information__metadata__fourcc(&minfo);
        if (minfo.flavor == WUFFS_BASE__MORE_INFORMATION__FLAVOR__METADATA_RAW_PASSTHROUGH) {
            wuffs_base__range_ie_u64 r = wuffs_base__more_information__metadata_raw_passthrough__range(&minfo);
            if (r.min_incl > r.max_excl || r.max_excl > len || r.min_incl < s->src.meta.ri) goto done;
            size_t n = (size_t)(r.max_excl - r.min_incl);
            if (dst.meta.wi + n > MAX_ICC) goto skip;
            if (dst.meta.wi + n > cap) {
                size_t ncap = dst.meta.wi + n;
                uint8_t *nb = realloc(buf, ncap ? ncap : 1);
                if (!nb) {
                    result = SIV_WUFFS_NO_MEMORY;
                    goto done;
                }
                buf = nb;
                cap = ncap;
                dst.data = wuffs_base__make_slice_u8(buf, cap);
            }
            memcpy(buf + dst.meta.wi, data + r.min_incl, n);
            dst.meta.wi += n;
            s->src.meta.ri = (size_t)r.max_excl;
        } else if (minfo.flavor != 0 && minfo.flavor != WUFFS_BASE__MORE_INFORMATION__FLAVOR__METADATA_RAW_TRANSFORM) {
            goto done;
        }
        if (st.repr == NULL) break;
        if (st.repr == wuffs_base__suspension__even_more_information) continue;
        if (st.repr != wuffs_base__suspension__short_write) goto done;
        if (cap >= MAX_ICC) goto skip;
        size_t ncap = cap ? cap * 2 : 4096;
        if (ncap > MAX_ICC) ncap = MAX_ICC;
        uint8_t *nb = realloc(buf, ncap);
        if (!nb) {
            result = SIV_WUFFS_NO_MEMORY;
            goto done;
        }
        buf = nb;
        cap = ncap;
        dst.data = wuffs_base__make_slice_u8(buf, cap);
    }
    if (fourcc == WUFFS_BASE__FOURCC__ICCP && s->icc == NULL && dst.meta.wi > 0) {
        s->icc = buf;
        s->icc_len = dst.meta.wi;
        buf = NULL;
    }
    result = SIV_WUFFS_OK;
    goto done;
skip:
    /* Too large to keep: no profile. */
    result = SIV_WUFFS_INVALID;
done:
    free(buf);
    return result;
}

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

void siv_wuffs_close(siv_wuffs *s) {
    if (!s) return;
    free(s->dec);
    free(s->canvas);
    free(s->saved);
    free(s->workbuf);
    free(s->icc);
    free(s);
}

int siv_wuffs_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_wuffs **out,
                   uint32_t *width, uint32_t *height, const uint8_t **icc, size_t *icc_len) {
    *out = NULL;
    *icc = NULL;
    *icc_len = 0;
    siv_wuffs *s = calloc(1, sizeof(*s));
    if (!s) return SIV_WUFFS_NO_MEMORY;
    s->dec = make_decoder(data, len);
    if (!s->dec) {
        free(s);
        return SIV_WUFFS_UNSUPPORTED;
    }
    s->src = wuffs_base__ptr_u8__reader((uint8_t *)data, len, true);
    s->data = data;
    s->len = len;
    wuffs_base__image_decoder__set_report_metadata(s->dec, WUFFS_BASE__FOURCC__ICCP, true);
    wuffs_base__image_config ic;
    int result = SIV_WUFFS_INVALID;
    for (;;) {
        wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(s->dec, &ic, &s->src);
        if (st.repr == NULL) break;
        if (st.repr != wuffs_base__note__metadata_reported) goto fail;
        int r = read_metadata(s, data, len);
        if (r != SIV_WUFFS_OK) {
            result = r;
            goto fail;
        }
    }
    if (s->icc_len) {
        *icc = s->icc;
        *icc_len = s->icc_len;
    }
    uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
    uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
    if (w == 0 || h == 0) goto fail;
    if ((uint64_t)w * h > max_pixels) {
        result = SIV_WUFFS_TOO_LARGE;
        goto fail;
    }
    wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
                                  WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
    size_t size = (size_t)w * h * 4;
    s->canvas = calloc(size, 1);
    s->saved = malloc(size);
    s->workbuf_len = (size_t)wuffs_base__image_decoder__workbuf_len(s->dec).max_incl;
    if (s->workbuf_len) s->workbuf = malloc(s->workbuf_len);
    if (!s->canvas || !s->saved || (s->workbuf_len && !s->workbuf)) {
        result = SIV_WUFFS_NO_MEMORY;
        goto fail;
    }
    if (wuffs_base__pixel_buffer__set_from_slice(&s->pb, &ic.pixcfg, wuffs_base__make_slice_u8(s->canvas, size)).repr) goto fail;
    s->width = w;
    s->height = h;
    *width = w;
    *height = h;
    *out = s;
    return SIV_WUFFS_OK;
fail:
    siv_wuffs_close(s);
    *icc = NULL;
    *icc_len = 0;
    return result;
}

static void clear_rect(siv_wuffs *s, wuffs_base__rect_ie_u32 r) {
    if (r.max_excl_x > s->width) r.max_excl_x = s->width;
    if (r.max_excl_y > s->height) r.max_excl_y = s->height;
    if (r.min_incl_x >= r.max_excl_x) return;
    for (uint32_t y = r.min_incl_y; y < r.max_excl_y; y++)
        memset(s->canvas + ((size_t)y * s->width + r.min_incl_x) * 4, 0, (size_t)(r.max_excl_x - r.min_incl_x) * 4);
}

int siv_wuffs_next(siv_wuffs *s, uint8_t *rgba, uint32_t *delay_ms) {
    wuffs_base__frame_config fc;
    wuffs_base__status st = wuffs_base__image_decoder__decode_frame_config(s->dec, &fc, &s->src);
    if (st.repr == wuffs_base__note__end_of_data) return s->frames ? SIV_WUFFS_END : SIV_WUFFS_INVALID;
    if (st.repr != NULL) return s->frames ? SIV_WUFFS_END : SIV_WUFFS_INVALID;
    /* Dispose of the previous frame, then keep what RESTORE_PREVIOUS
     * needs to undo this one. */
    size_t size = (size_t)s->width * s->height * 4;
    if (s->frames) {
        if (s->prev_disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_BACKGROUND) clear_rect(s, s->prev_bounds);
        else if (s->prev_disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) memcpy(s->canvas, s->saved, size);
    }
    uint8_t disposal = wuffs_base__frame_config__disposal(&fc);
    if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) memcpy(s->saved, s->canvas, size);
    wuffs_base__pixel_blend blend = wuffs_base__frame_config__overwrite_instead_of_blend(&fc)
                                        ? WUFFS_BASE__PIXEL_BLEND__SRC
                                        : WUFFS_BASE__PIXEL_BLEND__SRC_OVER;
    st = wuffs_base__image_decoder__decode_frame(s->dec, &s->pb, &s->src, blend,
                                                 wuffs_base__make_slice_u8(s->workbuf, s->workbuf_len), NULL);
    /* A truncated last frame still shows what decoded. */
    if (st.repr != NULL && !s->frames && st.repr != wuffs_base__suspension__short_read) return SIV_WUFFS_INVALID;
    s->prev_bounds = wuffs_base__frame_config__bounds(&fc);
    s->prev_disposal = disposal;
    s->frames++;
    uint64_t ms = (uint64_t)wuffs_base__frame_config__duration(&fc) / WUFFS_BASE__FLICKS_PER_MILLISECOND;
    *delay_ms = ms > 0xffffffffu ? 0xffffffffu : (uint32_t)ms;
    memcpy(rgba, s->canvas, size);
    return SIV_WUFFS_OK;
}

uint32_t siv_wuffs_frames(const siv_wuffs *s) {
    /* JPEG has one frame; PNG and GIF frames are counted by a second
     * decoder reading only frame headers, which skips pixel data. */
    if (wuffs_base__magic_number_guess_fourcc(wuffs_base__make_slice_u8((uint8_t *)s->data, s->len), true) ==
        WUFFS_BASE__FOURCC__JPEG)
        return 1;
    wuffs_base__image_decoder *dec = make_decoder(s->data, s->len);
    if (!dec) return 0;
    wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)s->data, s->len, true);
    uint32_t n = 0;
    if (wuffs_base__image_decoder__decode_image_config(dec, NULL, &src).repr == NULL) {
        while (n < UINT32_MAX && wuffs_base__image_decoder__decode_frame_config(dec, NULL, &src).repr == NULL) n++;
    }
    free(dec);
    return n;
}

uint32_t siv_wuffs_loops(const siv_wuffs *s) {
    return wuffs_base__image_decoder__num_animation_loops(s->dec);
}
