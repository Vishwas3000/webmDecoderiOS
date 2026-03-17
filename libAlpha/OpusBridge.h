#pragma once

#include <stdint.h>
#include <stddef.h>

// ──────────────────────────────────────────────────────────────
// OpusBridge — Minimal C bridge between libopus and Swift.
//
// Provides an opaque handle so Swift never touches OpusDecoder*.
// Decodes individual Opus packets to interleaved Float32 PCM.
// ──────────────────────────────────────────────────────────────

typedef void *OpusDecoderRef;

/// Create an Opus decoder for the given sample rate and channel count.
/// sample_rate is typically 48000. channels is 1 (mono) or 2 (stereo).
/// Returns NULL on failure.
OpusDecoderRef opus_bridge_create(int sample_rate, int channels);

/// Destroy a decoder and free all resources.
void opus_bridge_destroy(OpusDecoderRef decoder);

/// Decode one Opus packet into interleaved Float32 PCM.
/// `pcm_out` must be large enough for at least `max_frames * channels` floats.
/// `max_frames` is the max number of samples per channel (5760 for 48kHz @ 120ms).
/// Returns the number of decoded samples per channel, or a negative error code.
int opus_bridge_decode_float(OpusDecoderRef decoder,
                             const uint8_t *data, int data_size,
                             float *pcm_out, int max_frames);

/// Returns the last error string for the given error code.
const char *opus_bridge_strerror(int error);
