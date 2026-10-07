// Many rectangles and rounded rectangles with circular corners in one instanced draw,
// filled or stroked, under at most one rounded clip and the clip mask shared by the draw
// (fill.frag draws one, with elliptical corners too). Per instance (luce-gpu's locations
// 1..3): the rectangle, the radius at each corner (top left, top right, bottom right,
// bottom left), and the straight color as two 16-bit pairs (r * 256 + g, b * 256 + a)
// with the stroke width and whether it is anti-aliased.
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
layout(location = 0) in vec4 vertex_color;
layout(location = 1) flat in vec4 rect;
layout(location = 2) flat in vec4 corners;
layout(location = 3) flat in vec4 style;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec4 clip_rect;
    vec4 clip_radii0;
    vec4 clip_radii1;
    float clip_mode;
    float mask;      // 1: multiply by the clip mask at binding 2
} params;
layout(set = 0, binding = 2) uniform sampler2D clip_mask;

// The straight 8-bit channels of a pair packed as high * 256 + low.
vec2 unpacked(float pair) {
    float high = floor(pair / 256.0);
    return vec2(high, pair - high * 256.0) / 255.0;
}

void main() {
    vec2 p = gl_FragCoord.xy;
    vec4 radii0 = corners.xxyy;
    vec4 radii1 = corners.zzww;
    float stroke = style.z;
    float coverage;
    if (stroke > 0.0) {
        float h = stroke * 0.5;
        vec4 outer = vec4(rect.xy - h, rect.zw + 2.0 * h);
        vec4 inner = vec4(rect.xy + h, rect.zw - 2.0 * h);
        vec4 grow0 = radii0 + h * step(vec4(1e-4), radii0);
        vec4 grow1 = radii1 + h * step(vec4(1e-4), radii1);
        float outer_coverage = rrect_coverage(p, outer, grow0, grow1);
        float inner_coverage = inner.z > 0.0 && inner.w > 0.0 ? rrect_coverage(p, inner, max(radii0 - h, 0.0), max(radii1 - h, 0.0)) : 0.0;
        coverage = clamp(outer_coverage - inner_coverage, 0.0, 1.0);
    } else {
        coverage = rrect_coverage(p, rect, radii0, radii1);
    }
    if (style.w > 0.5) {
        coverage = coverage >= 0.5 ? 1.0 : 0.0;
    }
    coverage *= clip_coverage(p, params.clip_mode, params.clip_rect, params.clip_radii0, params.clip_radii1);
    coverage *= mask_coverage(clip_mask, p, params.mask);
    vec2 rg = unpacked(style.x);
    vec2 ba = unpacked(style.y);
    vec4 straight = vec4(rg, ba);
    fragment_color = vec4(straight.rgb * straight.a, straight.a) * coverage;
}
