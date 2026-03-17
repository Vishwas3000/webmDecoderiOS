#include <metal_stdlib>
using namespace metal;

// ──────────────────────────────────────────────────────────────
// Fullscreen quad: two triangles covering NDC [-1,1] x [-1,1]
// UV origin is top-left to match UIKit / CVPixelBuffer layout.
// ──────────────────────────────────────────────────────────────

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

constant float2 quadPositions[4] = {
    float2(-1.0, -1.0),   // bottom-left
    float2( 1.0, -1.0),   // bottom-right
    float2(-1.0,  1.0),   // top-left
    float2( 1.0,  1.0),   // top-right
};

constant float2 quadUVs[4] = {
    float2(0.0, 1.0),
    float2(1.0, 1.0),
    float2(0.0, 0.0),
    float2(1.0, 0.0),
};

vertex VertexOut compositor_vertex(uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(quadPositions[vid], 0.0, 1.0);
    out.uv       = quadUVs[vid];
    return out;
}

// ──────────────────────────────────────────────────────────────
// Fragment shader — YUV→RGB conversion on GPU
//
//   texture(0) — Y  plane (R8, full res)   color luma
//   texture(1) — U  plane (R8, half res)   color Cb
//   texture(2) — V  plane (R8, half res)   color Cr
//   texture(3) — Yα plane (R8, full res)   alpha luma
//
// BT.601 limited range YUV→RGB.
// GPU bilinear filtering on half-res U/V textures gives us
// free chroma upsampling — zero CPU work.
// ──────────────────────────────────────────────────────────────

fragment float4 compositor_fragment(
    VertexOut          in       [[stage_in]],
    texture2d<float>   yTex     [[texture(0)]],
    texture2d<float>   uTex     [[texture(1)]],
    texture2d<float>   vTex     [[texture(2)]],
    texture2d<float>   alphaYTex[[texture(3)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Sample YUV (bilinear on half-res U/V = free chroma upsampling)
    float y_raw = yTex.sample(s, in.uv).r;
    float u_raw = uTex.sample(s, in.uv).r;
    float v_raw = vTex.sample(s, in.uv).r;

    // BT.601 limited range → linear RGB
    float y = (y_raw - 16.0 / 255.0) * (255.0 / 219.0);
    float u = u_raw - 128.0 / 255.0;
    float v = v_raw - 128.0 / 255.0;

    float r = y + 1.596 * v;
    float g = y - 0.392 * u - 0.813 * v;
    float b = y + 2.017 * u;

    float3 color = saturate(float3(r, g, b));

    // Alpha from Y plane of the alpha VP9 stream (luma = alpha)
    float alpha_raw = alphaYTex.sample(s, in.uv).r;
    float alpha = saturate((alpha_raw - 16.0 / 255.0) * (255.0 / 219.0));

    // Premultiplied alpha output
    return float4(color * alpha, alpha);
}
