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

fragment float4 fe_ground(Out in [[stage_in]], constant Uniforms &u [[buffer(1)]], texture2d<float> base [[texture(0)]],
                          texture2d<float> night [[texture(1)]], texture2d<float> names [[texture(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
    float3 colour = base.sample(s, u.uvBase.xy + in.uv * u.uvBase.zw).rgb;
    float3 n = normalize(in.normal);
    if (u.sun.w > 0.5) {
        float day = smoothstep(-0.10, 0.28, dot(n, u.sun.xyz));
        float3 dark = mix(colour, float3(0.039, 0.063, 0.188), 0.72);
        float3 lights = night.sample(s, u.uvNight.xy + in.uv * u.uvNight.zw).rgb;
        colour = mix(dark, colour, day) + lights * (1.0 - day) * 1.25;
        float haze = pow(in.rim, 4.0) * (0.2 + 0.8 * day);
        colour = mix(colour, float3(0.50, 0.70, 1.0), saturate(haze * 0.7));
    }
    float4 name = names.sample(s, u.uvNames.xy + in.uv * u.uvNames.zw); // premultiplied
    colour = colour * (1.0 - name.a) + name.rgb;
    return float4(colour, 1.0);
}

fragment float4 fe_model(Out in [[stage_in]], texture2d<float> picture [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
    return float4(picture.sample(s, in.uv).rgb, 1.0);
}
