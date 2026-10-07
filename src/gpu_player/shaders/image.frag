// An image scaled onto a rectangle: nearest or bilinear (clamped to its edges, as Skia's
// kClamp image shader samples), or trilinear from its mipmaps when it is drawn smaller (the
// sampler's filtering), its premultiplied texels in the encoded space, under at most one
// rounded clip and the clip mask. `image` is width, height, filter (0 nearest, 1 bilinear,
// 2 mipmapped) and opacity.
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
layout(location = 0) in vec4 vertex_color;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec4 dst;
    vec4 image;
    vec4 clip_rect;
    vec4 clip_radii0;
    vec4 clip_radii1;
    float clip_mode;
    float mask;      // 1: multiply by the clip mask at binding 2
} params;
layout(set = 0, binding = 1) uniform sampler2D source;
layout(set = 0, binding = 2) uniform sampler2D clip_mask;

vec4 texel(ivec2 at) {
    ivec2 size = ivec2(params.image.xy);
    return texelFetch(source, clamp(at, ivec2(0), size - 1), 0);
}

void main() {
    vec2 p = gl_FragCoord.xy;
    // The pixel center in the image's texels.
    vec2 u = (p - params.dst.xy) * (params.image.xy / params.dst.zw);
    vec4 color;
    if (params.image.z > 1.5) {
        // Mipmapped: the sampler picks and blends levels by the scale (Skia's
        // bilinear_mipmap filters linearly between levels too).
        color = texture(source, u / params.image.xy);
    } else if (params.image.z < 0.5) {
        color = texel(ivec2(floor(u)));
    } else {
        vec2 v = u - 0.5;
        vec2 base = floor(v);
        vec2 f = v - base;
        ivec2 at = ivec2(base);
        vec4 top = mix(texel(at), texel(at + ivec2(1, 0)), f.x);
        vec4 bottom = mix(texel(at + ivec2(0, 1)), texel(at + ivec2(1, 1)), f.x);
        color = mix(top, bottom, f.y);
    }
    float coverage = params.image.w * clip_coverage(p, params.clip_mode, params.clip_rect, params.clip_radii0, params.clip_radii1);
    coverage *= mask_coverage(clip_mask, p, params.mask);
    fragment_color = color * coverage;
}
