// Coverage from the player's atlas (a glyph's mask or a path's), tinted with a color, under at
// most one rounded clip. The mask sits at whole target pixels: `dst` is its rectangle, `src`
// where it is in the atlas, so each pixel reads its texel exactly.
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
layout(location = 0) in vec4 vertex_color;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec4 dst;
    vec4 src;
    vec4 color;
    vec4 clip_rect;
    vec4 clip_radii0;
    vec4 clip_radii1;
    float clip_mode;
} params;
layout(set = 0, binding = 1) uniform sampler2D atlas;

void main() {
    vec2 p = gl_FragCoord.xy;
    ivec2 at = ivec2(floor(p - params.dst.xy)) + ivec2(params.src.xy);
    float coverage = texelFetch(atlas, at, 0).r;
    coverage *= clip_coverage(p, params.clip_mode, params.clip_rect, params.clip_radii0, params.clip_radii1);
    fragment_color = params.color * coverage;
}
