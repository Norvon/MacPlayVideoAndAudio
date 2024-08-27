//
//  test.metal
//  MacPlayVideoAndAudio
//
//  Created by welink on 2024/8/27.
//

#include <metal_stdlib>
using namespace metal;


#include <metal_stdlib>
using namespace metal;
struct VertexOutput {
    float4 position [[position]];
    float2 texcoord;
};
constexpr sampler s = sampler(filter::linear);
vertex VertexOutput vertex_sampler(const uint vid [[vertex_id]]) {
    const VertexOutput vertexData[3] = {
        {{-1.0,  1.0, 0.0, 1.0}, {0.0, 0.0}},
        {{ 3.0,  1.0, 0.0, 1.0}, {2.0, 0.0}},
        {{-1.0, -3.0, 0.0, 1.0}, {0.0, 2.0}}
    };
    return vertexData[vid];
}
half3 apply_pq_eotf(half3 color) {
    const half m1 = 0.1593017578125h;
    const half m2 = 78.84375h;
    const half c1 = 0.8359375h;
    const half c2 = 18.8515625h;
    const half c3 = 18.6875h;
    
    half3 temp = pow(color, half3(1.0h / m2));
    return pow((max(temp - c1, half3(0.0h)) / (c2 - c3 * temp)), half3(1.0h / m1));
}
constant half3x3 bt2020_to_srgb = {
    {1.6605, -0.5876, -0.0728},
    {-0.1246, 1.1329, -0.0083},
    {-0.0182, -0.1006, 1.1187}
};
fragment half4 post_model_fragment(VertexOutput in [[stage_in]], texture2d<half> y_data [[texture(0)]], texture2d<half> uv_data [[texture(1)]]) {
    const half3x3 yuv_rgb = {
        half3(1.0h, 1.0h, 1.0h),
        half3(0.0h, -0.16455312684366h, 1.8814h),
        half3(1.4746h, -0.57135312684366h, 0.0h)
    };
    half4 y = y_data.sample(s, in.texcoord);
    half4 uv = uv_data.sample(s, in.texcoord) - 0.5h;
    half3 yuv(y.x, uv.xy);
    half3 rgb_bt2020 = yuv_rgb * yuv;
    // Convert from BT.2020 to sRGB
    half3 rgb_srgb = bt2020_to_srgb * rgb_bt2020;
    // Apply PQ EOTF
    rgb_srgb = apply_pq_eotf(rgb_srgb);
    uint3 rgb_10bit = uint3(clamp(rgb_srgb * 1023.0h, half3(0.0h), half3(1023.0h)));
    uint packed = (rgb_10bit.b << 20) | (rgb_10bit.g << 10) | rgb_10bit.r;
    
    return half4(as_type<float>(packed), 0.0h, 0.0h, 1.0h);
}
