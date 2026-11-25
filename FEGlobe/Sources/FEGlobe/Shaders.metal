// SPDX-License-Identifier: AGPL-3.0-or-later
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    packed_float3 position; // metres from the anchor of the mesh
    packed_float2 uv;
};

struct Uniforms {
    float4x4 viewProjection; // the camera turned, not moved: positions are given from the eye
    float4 offset;           // anchor of the mesh minus the eye
    float4 centre;           // anchor of the mesh from the middle of the Earth
    float4 uvBase;           // x, y: offset, z, w: scale (when the picture of a tile above is used)
    float4 uvNight;
    float4 uvNames;
    float4 sun;              // direction to the sun; w: 1 = sunlight on
};

struct Out {
    float4 position [[position]];
    float2 uv;
    float3 normal;
    float rim;
};

vertex Out fe_vertex(const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]], uint id [[vertex_id]]) {
    Vertex v = vertices[id];
    float3 local = float3(v.position);
    float3 fromEye = local + u.offset.xyz;
    Out out;
    out.position = u.viewProjection * float4(fromEye, 1.0);
    out.uv = float2(v.uv);
    out.normal = normalize(local + u.centre.xyz);
    out.rim = 1.0 - saturate(dot(out.normal, -normalize(fromEye)));
    return out;
}

// the satellite mosaic is overexposed on bright ground (deserts, snow): the highlights are pressed down, the rest stays
static float3 soften(float3 c) {
    float brightness = dot(c, float3(0.2126, 0.7152, 0.0722));
    const float knee = 0.45;
    if (brightness <= knee) return c;
    float pressed = knee + (brightness - knee) * 0.55;
    return c * (pressed / brightness);
}

fragment float4 fe_ground(Out in [[stage_in]], constant Uniforms &u [[buffer(1)]], texture2d<float> base [[texture(0)]],
                          texture2d<float> night [[texture(1)]], texture2d<float> names [[texture(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
    float3 colour = soften(base.sample(s, u.uvBase.xy + in.uv * u.uvBase.zw).rgb);
    float3 n = normalize(in.normal);
    if (u.sun.w > 0.001) { // sun.w: how strong the sunlight is (it fades out near the ground)
        float day = smoothstep(-0.14, 0.14, dot(n, u.sun.xyz));
        float3 dark = colour * 0.13 + float3(0.008, 0.014, 0.040);
        // the night picture also shows the land by moonlight (blue and violet): only its warm, bright points are lights
        float3 seen = night.sample(s, u.uvNight.xy + in.uv * u.uvNight.zw).rgb;
        float3 lights = seen * smoothstep(0.24, 0.62, seen.r);
        float3 lit = mix(dark + lights * 1.15, colour, day);
        float haze = pow(in.rim, 4.0) * (0.15 + 0.85 * day);
        lit = mix(lit, float3(0.50, 0.70, 1.0), saturate(haze * 0.65));
        colour = mix(colour, lit, u.sun.w);
    }
    float4 name = names.sample(s, u.uvNames.xy + in.uv * u.uvNames.zw); // premultiplied
    colour = colour * (1.0 - name.a) + name.rgb;
    return float4(colour, 1.0);
}

fragment float4 fe_model(Out in [[stage_in]], texture2d<float> picture [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
    return float4(picture.sample(s, in.uv).rgb, 1.0);
}
