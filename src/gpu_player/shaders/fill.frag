// A solid rectangle or rounded rectangle (filled, or stroked `stroke` pixels wide around
// its edge), under at most one rounded clip, with or without anti-aliasing. Colors are stored values premultiplied: the
// player blends in the encoded space, as Skia's legacy raster does.
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
layout(location = 0) in vec4 vertex_color;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec4 rect;
    vec4 radii0;
    vec4 radii1;
    vec4 color;
    vec4 clip_rect;
    vec4 clip_radii0;
    vec4 clip_radii1;
    float clip_mode;
    float stroke;
    float aliased;   // 1: no anti-aliasing (a pixel is in when its center is)
} params;

void main() {
    vec2 p = gl_FragCoord.xy;
    float coverage;
    if (params.stroke > 0.0) {
        float h = params.stroke * 0.5;
        vec4 outer = vec4(params.rect.xy - h, params.rect.zw + 2.0 * h);
        vec4 inner = vec4(params.rect.xy + h, params.rect.zw - 2.0 * h);
        // Square corners stay square (a mitered frame); rounded ones grow and shrink by h.
        vec4 grow0 = params.radii0 + h * step(vec4(1e-4), params.radii0);
        vec4 grow1 = params.radii1 + h * step(vec4(1e-4), params.radii1);
        float outer_coverage = rrect_coverage(p, outer, grow0, grow1);
        float inner_coverage = inner.z > 0.0 && inner.w > 0.0 ? rrect_coverage(p, inner, max(params.radii0 - h, 0.0), max(params.radii1 - h, 0.0)) : 0.0;
        coverage = clamp(outer_coverage - inner_coverage, 0.0, 1.0);
    } else {
        coverage = rrect_coverage(p, params.rect, params.radii0, params.radii1);
    }
    if (params.aliased > 0.5) {
        coverage = coverage >= 0.5 ? 1.0 : 0.0;
    }
    coverage *= clip_coverage(p, params.clip_mode, params.clip_rect, params.clip_radii0, params.clip_radii1);
    fragment_color = params.color * coverage;
}
