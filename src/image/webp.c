/* See webp.h. Still images go through the animation decoder too: it
 * handles both, composites frames, and reports timestamps. */
#include <stdlib.h>
#include <string.h>

#include "webp/demux.h"
#include "webp.h"
#include "wuffs.h"

struct siv_webp {
    WebPData data;
    WebPAnimDecoder *dec;
    WebPDemuxer *demux;
    WebPChunkIterator icc;
    int has_icc;
    uint32_t width, height;
    int last_ts;
};

void siv_webp_close(siv_webp *s) {
    if (!s) return;
    if (s->has_icc) WebPDemuxReleaseChunkIterator(&s->icc);
    if (s->demux) WebPDemuxDelete(s->demux);
    if (s->dec) WebPAnimDecoderDelete(s->dec);
    free(s);
}

int siv_webp_open(const uint8_t *data, size_t len, uint64_t max_pixels, siv_webp **out,
                  uint32_t *width, uint32_t *height, const uint8_t **icc, size_t *icc_len, uint32_t *loops) {
    *out = NULL;
    *icc = NULL;
    *icc_len = 0;
    siv_webp *s = calloc(1, sizeof(*s));
    if (!s) return SIV_WUFFS_NO_MEMORY;
    s->data.bytes = data;
    s->data.size = len;
    s->demux = WebPDemux(&s->data);
    if (!s->demux) goto invalid;
    uint32_t w = WebPDemuxGetI(s->demux, WEBP_FF_CANVAS_WIDTH);
    uint32_t h = WebPDemuxGetI(s->demux, WEBP_FF_CANVAS_HEIGHT);
    if (w == 0 || h == 0) goto invalid;
    if ((uint64_t)w * h > max_pixels) {
        siv_webp_close(s);
        return SIV_WUFFS_TOO_LARGE;
    }
    if (WebPDemuxGetChunk(s->demux, "ICCP", 1, &s->icc)) {
        s->has_icc = 1;
        *icc = s->icc.chunk.bytes;
        *icc_len = s->icc.chunk.size;
    }
    WebPAnimDecoderOptions opts;
    if (!WebPAnimDecoderOptionsInit(&opts)) goto invalid;
    opts.color_mode = MODE_RGBA;
    opts.use_threads = 0;
    s->dec = WebPAnimDecoderNew(&s->data, &opts);
    if (!s->dec) goto invalid;
    WebPAnimInfo info;
    if (!WebPAnimDecoderGetInfo(s->dec, &info)) goto invalid;
    s->width = w;
    s->height = h;
    *width = w;
    *height = h;
    *loops = info.loop_count;
    *out = s;
    return SIV_WUFFS_OK;
invalid:
    siv_webp_close(s);
    *icc = NULL;
    *icc_len = 0;
    return SIV_WUFFS_INVALID;
}

int siv_webp_next(siv_webp *s, uint8_t *rgba, uint32_t *delay_ms) {
    if (!WebPAnimDecoderHasMoreFrames(s->dec)) return SIV_WUFFS_END;
    uint8_t *buf;
    int ts;
    if (!WebPAnimDecoderGetNext(s->dec, &buf, &ts)) return SIV_WUFFS_INVALID;
    memcpy(rgba, buf, (size_t)s->width * s->height * 4);
    *delay_ms = ts > s->last_ts ? (uint32_t)(ts - s->last_ts) : 0;
    s->last_ts = ts;
    return SIV_WUFFS_OK;
}
