#pragma once

#include <stdint.h>
#include <stddef.h>

// ──────────────────────────────────────────────────────────────
// VPXBridge — Minimal C bridge between libvpx and Swift.
//
// Provides an opaque handle so Swift never touches vpx structs.
// Output is BGRA pixel data suitable for CVPixelBuffer / Metal.
// ──────────────────────────────────────────────────────────────

typedef void *VPXDecoderRef;

/// Create a VP9 software decoder. Returns NULL on failure.
VPXDecoderRef vpx_bridge_create(int width, int height, int threads);

/// Destroy a decoder and free all resources.
void vpx_bridge_destroy(VPXDecoderRef decoder);

/// Feed one raw VP9 frame to the decoder. Returns 0 on success.
int vpx_bridge_decode(VPXDecoderRef decoder,
                      const uint8_t *data, size_t size);

/// Copy the most recently decoded frame as BGRA into `bgra_out`.
///   - bgra_out: caller-allocated buffer (at least bgra_stride * height bytes)
///   - bgra_stride: row stride in bytes (typically width * 4, may be larger)
///   - out_width / out_height: filled with the actual decoded dimensions
/// Returns 0 on success, -1 if no frame is available.
int vpx_bridge_get_frame_bgra(VPXDecoderRef decoder,
                              uint8_t *bgra_out,
                              int bgra_stride,
                              int *out_width,
                              int *out_height);

/// Returns the last error string, or NULL.
const char *vpx_bridge_error(VPXDecoderRef decoder);
