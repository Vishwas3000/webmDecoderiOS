#pragma once

#include <stdint.h>
#include <stddef.h>

// ──────────────────────────────────────────────────────────────
// VPXBridge — Minimal C bridge between libvpx and Swift.
//
// Provides an opaque handle so Swift never touches vpx structs.
// Two output modes:
//   1. Raw YUV planes (preferred) — upload directly to Metal textures,
//      GPU does YUV→RGB. Fastest path, minimal CPU work.
//   2. BGRA pixels (legacy) — CPU-side conversion for CVPixelBuffer.
// ──────────────────────────────────────────────────────────────

typedef void *VPXDecoderRef;

/// Raw I420 YUV plane pointers.  Valid until the next vpx_bridge_decode() call.
typedef struct {
    const uint8_t *y;
    const uint8_t *u;
    const uint8_t *v;
    int y_stride;
    int u_stride;
    int v_stride;
    int width;
    int height;
} VPXYUVPlanes;

/// Create a VP9 software decoder. Returns NULL on failure.
VPXDecoderRef vpx_bridge_create(int width, int height, int threads);

/// Destroy a decoder and free all resources.
void vpx_bridge_destroy(VPXDecoderRef decoder);

/// Feed one raw VP9 frame to the decoder. Returns 0 on success.
int vpx_bridge_decode(VPXDecoderRef decoder,
                      const uint8_t *data, size_t size);

/// Get raw YUV plane pointers from the most recently decoded frame.
/// Pointers point into libvpx internal memory — valid until next decode() call.
/// Returns 0 on success, -1 if no frame is available.
int vpx_bridge_get_yuv_planes(VPXDecoderRef decoder, VPXYUVPlanes *out);

/// Copy the most recently decoded frame as BGRA into `bgra_out`.
/// (Legacy path — prefer vpx_bridge_get_yuv_planes + GPU conversion.)
int vpx_bridge_get_frame_bgra(VPXDecoderRef decoder,
                              uint8_t *bgra_out,
                              int bgra_stride,
                              int *out_width,
                              int *out_height);

/// Returns the last error string, or NULL.
const char *vpx_bridge_error(VPXDecoderRef decoder);
