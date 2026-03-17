#include "VPXBridge.h"
#include <stdlib.h>
#include <string.h>

#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>

// ──────────────────────────────────────────────────────────────
// Internal context
// ──────────────────────────────────────────────────────────────

typedef struct {
    vpx_codec_ctx_t     codec;
    vpx_codec_iter_t    iter;        // frame iterator (reset per decode call)
    vpx_image_t        *last_img;    // points into codec internals, do NOT free
    int                 initialized;
} VPXContext;

// ──────────────────────────────────────────────────────────────
// YUV I420 → BGRA conversion  (BT.601 limited-range)
// ──────────────────────────────────────────────────────────────

static inline uint8_t clamp_u8(int v) {
    return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

static void i420_to_bgra(const uint8_t *y_plane, int y_stride,
                         const uint8_t *u_plane, int u_stride,
                         const uint8_t *v_plane, int v_stride,
                         uint8_t *bgra, int bgra_stride,
                         int width, int height)
{
    for (int row = 0; row < height; row++) {
        const uint8_t *y_row = y_plane + row * y_stride;
        const uint8_t *u_row = u_plane + (row >> 1) * u_stride;
        const uint8_t *v_row = v_plane + (row >> 1) * v_stride;
        uint8_t       *dst   = bgra + row * bgra_stride;

        for (int col = 0; col < width; col++) {
            int y = (int)y_row[col] - 16;
            int u = (int)u_row[col >> 1] - 128;
            int v = (int)v_row[col >> 1] - 128;

            int c = 298 * y;
            int r = (c + 409 * v + 128) >> 8;
            int g = (c - 100 * u - 208 * v + 128) >> 8;
            int b = (c + 516 * u + 128) >> 8;

            // BGRA layout
            dst[0] = clamp_u8(b);
            dst[1] = clamp_u8(g);
            dst[2] = clamp_u8(r);
            dst[3] = 255;          // opaque alpha
            dst += 4;
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Public API
// ──────────────────────────────────────────────────────────────

VPXDecoderRef vpx_bridge_create(int width, int height, int threads) {
    VPXContext *ctx = (VPXContext *)calloc(1, sizeof(VPXContext));
    if (!ctx) return NULL;

    vpx_codec_dec_cfg_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.threads = (unsigned int)(threads > 0 ? threads : 1);
    cfg.w       = (unsigned int)width;
    cfg.h       = (unsigned int)height;

    vpx_codec_err_t err = vpx_codec_dec_init(
        &ctx->codec,
        vpx_codec_vp9_dx(),
        &cfg,
        0
    );

    if (err != VPX_CODEC_OK) {
        free(ctx);
        return NULL;
    }

    ctx->initialized = 1;
    return (VPXDecoderRef)ctx;
}

void vpx_bridge_destroy(VPXDecoderRef decoder) {
    if (!decoder) return;
    VPXContext *ctx = (VPXContext *)decoder;
    if (ctx->initialized) {
        vpx_codec_destroy(&ctx->codec);
    }
    free(ctx);
}

int vpx_bridge_decode(VPXDecoderRef decoder,
                      const uint8_t *data, size_t size)
{
    if (!decoder) return -1;
    VPXContext *ctx = (VPXContext *)decoder;

    vpx_codec_err_t err = vpx_codec_decode(
        &ctx->codec,
        data,
        (unsigned int)size,
        NULL,   // user_priv
        0       // deadline (0 = no limit)
    );

    if (err != VPX_CODEC_OK) return -1;

    // Fetch the decoded frame immediately
    ctx->iter     = NULL;
    ctx->last_img = vpx_codec_get_frame(&ctx->codec, &ctx->iter);

    return ctx->last_img ? 0 : -1;
}

int vpx_bridge_get_yuv_planes(VPXDecoderRef decoder, VPXYUVPlanes *out) {
    if (!decoder || !out) return -1;
    VPXContext *ctx = (VPXContext *)decoder;
    vpx_image_t *img = ctx->last_img;
    if (!img) return -1;

    out->y        = img->planes[VPX_PLANE_Y];
    out->u        = img->planes[VPX_PLANE_U];
    out->v        = img->planes[VPX_PLANE_V];
    out->y_stride = img->stride[VPX_PLANE_Y];
    out->u_stride = img->stride[VPX_PLANE_U];
    out->v_stride = img->stride[VPX_PLANE_V];
    out->width    = (int)img->d_w;
    out->height   = (int)img->d_h;
    return 0;
}

int vpx_bridge_get_frame_bgra(VPXDecoderRef decoder,
                              uint8_t *bgra_out,
                              int bgra_stride,
                              int *out_width,
                              int *out_height)
{
    if (!decoder) return -1;
    VPXContext *ctx = (VPXContext *)decoder;
    vpx_image_t *img = ctx->last_img;
    if (!img) return -1;

    int w = (int)img->d_w;
    int h = (int)img->d_h;
    if (out_width)  *out_width  = w;
    if (out_height) *out_height = h;

    i420_to_bgra(
        img->planes[VPX_PLANE_Y], img->stride[VPX_PLANE_Y],
        img->planes[VPX_PLANE_U], img->stride[VPX_PLANE_U],
        img->planes[VPX_PLANE_V], img->stride[VPX_PLANE_V],
        bgra_out, bgra_stride,
        w, h
    );

    return 0;
}

const char *vpx_bridge_error(VPXDecoderRef decoder) {
    if (!decoder) return "null decoder";
    VPXContext *ctx = (VPXContext *)decoder;
    return vpx_codec_error(&ctx->codec);
}
