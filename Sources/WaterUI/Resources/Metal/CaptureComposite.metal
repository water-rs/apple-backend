#include <metal_stdlib>
using namespace metal;

struct CaptureCompositeVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CaptureCompositeVertexOut capture_composite_vertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[3] = {
        {-1.0, -1.0},
        {3.0, -1.0},
        {-1.0, 3.0},
    };
    constexpr float2 coordinates[3] = {
        {0.0, 0.0},
        {2.0, 0.0},
        {0.0, 2.0},
    };
    CaptureCompositeVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = coordinates[vertexID];
    return output;
}

fragment float4 capture_composite_fragment(
    CaptureCompositeVertexOut input [[stage_in]],
    texture2d<float> overlayTexture [[texture(0)]],
    sampler overlaySampler [[sampler(0)]]) {
    return overlayTexture.sample(overlaySampler, input.uv);
}
