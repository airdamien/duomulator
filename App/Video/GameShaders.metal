#include <metal_stdlib>
using namespace metal;

// Shaders for GameRenderView. The frame is drawn as one full-viewport quad; the viewport is
// set to the letterboxed content rect on the CPU side, and the clear color provides the bars.

/// Must match `GameRenderView.Uniforms` in Swift (two float2s, 16 bytes).
struct GameUniforms {
    /// Frame size / texture size: the frame occupies the top-left of a max-size texture.
    float2 uvMax;
    /// 1 / texture size, used to keep samples half a texel inside the frame.
    float2 texel;
};

struct GameVertexOut {
    float4 position [[position]];
    float2 uv;
};

/// Triangle strip of 4 vertices, no vertex buffer: vid bit 0 = right, bit 1 = bottom.
vertex GameVertexOut game_vertex(uint vid [[vertex_id]]) {
    float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
    GameVertexOut out;
    out.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
    out.uv = corner;
    return out;
}

/// Maps the quad's 0...1 uv onto the frame's sub-rect, clamped half a texel inside it so linear
/// filtering never blends in stale pixels from beyond the frame's right/bottom edge.
static float2 frame_uv(float2 uv, constant GameUniforms &u) {
    return clamp(uv * u.uvMax, u.texel * 0.5, u.uvMax - u.texel * 0.5);
}

/// Hardware path: `b5g6r5Unorm` texture (R in the high 5 bits, as libretro's RGB565), filtered
/// by the sampler the view picks (nearest or linear).
fragment float4 game_fragment_rgb565(GameVertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler smp [[sampler(0)]],
                                     constant GameUniforms &u [[buffer(0)]]) {
    return float4(tex.sample(smp, frame_uv(in.uv, u)).rgb, 1.0);
}
