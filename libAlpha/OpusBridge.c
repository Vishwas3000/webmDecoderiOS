#include "OpusBridge.h"
#include <stdlib.h>
#include <opus/opus.h>

// ──────────────────────────────────────────────────────────────
// Internal context
// ──────────────────────────────────────────────────────────────

typedef struct {
    OpusDecoder *decoder;
    int          channels;
} OpusBridgeContext;

// ──────────────────────────────────────────────────────────────
// Public API
// ──────────────────────────────────────────────────────────────

OpusDecoderRef opus_bridge_create(int sample_rate, int channels) {
    if (channels < 1 || channels > 2) return NULL;

    int error = 0;
    OpusDecoder *dec = opus_decoder_create(sample_rate, channels, &error);
    if (error != OPUS_OK || !dec) return NULL;

    OpusBridgeContext *ctx = (OpusBridgeContext *)calloc(1, sizeof(OpusBridgeContext));
    if (!ctx) {
        opus_decoder_destroy(dec);
        return NULL;
    }

    ctx->decoder  = dec;
    ctx->channels = channels;
    return (OpusDecoderRef)ctx;
}

void opus_bridge_destroy(OpusDecoderRef ref) {
    if (!ref) return;
    OpusBridgeContext *ctx = (OpusBridgeContext *)ref;
    if (ctx->decoder) {
        opus_decoder_destroy(ctx->decoder);
    }
    free(ctx);
}

int opus_bridge_decode_float(OpusDecoderRef ref,
                             const uint8_t *data, int data_size,
                             float *pcm_out, int max_frames) {
    if (!ref) return -1;
    OpusBridgeContext *ctx = (OpusBridgeContext *)ref;

    // opus_decode_float returns frames (samples per channel) decoded
    return opus_decode_float(ctx->decoder, data, data_size,
                             pcm_out, max_frames, 0);
}

const char *opus_bridge_strerror(int error) {
    return opus_strerror(error);
}
