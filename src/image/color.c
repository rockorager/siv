/* See color.h. */
#include <math.h>
#include <stdlib.h>

#include "lcms2.h"
#include "color.h"

struct siv_icc {
    cmsContext ctx;
    cmsHTRANSFORM xform;
    int srgb;
};

static double srgb_eotf(double v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

/* sRGB's colorants adapted to D50, as ICC profiles store them. */
static const cmsCIEXYZ srgb_colorants[3] = {
    {0.4360747, 0.2225045, 0.0139322},
    {0.3850649, 0.7168786, 0.0971045},
    {0.1430804, 0.0606169, 0.7141733},
};

static int profile_is_srgb(cmsHPROFILE p) {
    if (!cmsIsMatrixShaper(p)) return 0;
    const cmsTagSignature xyz[3] = {cmsSigRedColorantTag, cmsSigGreenColorantTag, cmsSigBlueColorantTag};
    const cmsTagSignature trc[3] = {cmsSigRedTRCTag, cmsSigGreenTRCTag, cmsSigBlueTRCTag};
    for (int i = 0; i < 3; i++) {
        const cmsCIEXYZ *c = cmsReadTag(p, xyz[i]);
        const cmsToneCurve *t = cmsReadTag(p, trc[i]);
        if (!c || !t) return 0;
        if (fabs(c->X - srgb_colorants[i].X) > 0.003 || fabs(c->Y - srgb_colorants[i].Y) > 0.003 ||
            fabs(c->Z - srgb_colorants[i].Z) > 0.003)
            return 0;
        for (int k = 1; k < 16; k++) {
            double v = k / 15.0;
            if (fabs(cmsEvalToneCurveFloat(t, (cmsFloat32Number)v) - srgb_eotf(v)) > 1.0 / 512) return 0;
        }
    }
    return 1;
}

siv_icc *siv_icc_new(const uint8_t *icc, size_t len, int bits) {
    if (!icc || len == 0 || len > 0x7fffffff) return NULL;
    siv_icc *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->ctx = cmsCreateContext(NULL, NULL);
    if (!t->ctx) goto fail;
    /* Profiles are untrusted input; errors stay quiet. */
    cmsSetLogErrorHandlerTHR(t->ctx, NULL);
    cmsHPROFILE in = cmsOpenProfileFromMemTHR(t->ctx, icc, (cmsUInt32Number)len);
    if (!in) goto fail;
    if (cmsGetColorSpace(in) != cmsSigRgbData) {
        cmsCloseProfile(in);
        goto fail;
    }
    t->srgb = profile_is_srgb(in);
    cmsCIExyY d65 = {0.3127, 0.3290, 1.0};
    cmsCIExyYTRIPLE primaries = {{0.64, 0.33, 1.0}, {0.30, 0.60, 1.0}, {0.15, 0.06, 1.0}};
    cmsToneCurve *linear = cmsBuildGamma(t->ctx, 1.0);
    cmsToneCurve *curves[3] = {linear, linear, linear};
    cmsHPROFILE out = linear ? cmsCreateRGBProfileTHR(t->ctx, &d65, &primaries, curves) : NULL;
    if (linear) cmsFreeToneCurve(linear);
    if (!out) {
        cmsCloseProfile(in);
        goto fail;
    }
    t->xform = cmsCreateTransformTHR(t->ctx, in, bits == 16 ? TYPE_RGBA_16 : TYPE_RGBA_8, out, TYPE_RGBA_16,
                                     INTENT_PERCEPTUAL, cmsFLAGS_COPY_ALPHA);
    cmsCloseProfile(in);
    cmsCloseProfile(out);
    if (!t->xform) goto fail;
    return t;
fail:
    siv_icc_free(t);
    return NULL;
}

int siv_icc_is_srgb(const siv_icc *t) {
    return t->srgb;
}

void siv_icc_apply(const siv_icc *t, const void *src, uint16_t *dst, size_t n) {
    cmsDoTransform(t->xform, src, dst, (cmsUInt32Number)n);
}

void siv_icc_free(siv_icc *t) {
    if (!t) return;
    if (t->xform) cmsDeleteTransform(t->xform);
    if (t->ctx) cmsDeleteContext(t->ctx);
    free(t);
}
