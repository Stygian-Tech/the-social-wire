#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 loginReflection(
    float2 position,
    half4 color,
    float2 tilt,
    float size
) {
    float2 uv = position / max(size, 1.0);
    float2 lightCenter = float2(0.34, 0.26) + tilt * float2(0.12, 0.10);
    float highlight = exp(-18.0 * distance(uv, lightCenter) * distance(uv, lightCenter));
    float rim = smoothstep(0.43, 0.50, distance(uv, float2(0.5)));
    float reflection = highlight * 0.055 + rim * 0.018;
    half3 reflectedColor = half3(0.10, 0.12, 0.16) * half(reflection * color.a);
    return half4(min(color.rgb + reflectedColor, half3(1.0)), color.a);
}
