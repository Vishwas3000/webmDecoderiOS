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

// UV: flip Y so row 0 of the CVPixelBuffer appears at the top
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
// Fragment shader
//   texture(0) — BGRA from the color VP9 track
//   texture(1) — BGRA from the alpha VP9 track (grayscale: R=G=B=luminance)
//
// Result: color.rgb composited with alpha.r as the alpha channel.
// The output drawable is BGRA so Metal writes it directly.
// ──────────────────────────────────────────────────────────────

fragment float4 compositor_fragment(
    VertexOut          in          [[stage_in]],
    texture2d<float>   colorTex    [[texture(0)]],
    texture2d<float>   alphaTex    [[texture(1)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float4 colorSample = colorTex.sample(s, in.uv);
    float  alpha       = alphaTex.sample(s, in.uv).r;   // R == G == B for grayscale

    // Premultiplied alpha output (standard for transparent layers in UIKit)
    return float4(colorSample.rgb * alpha, alpha);
}
